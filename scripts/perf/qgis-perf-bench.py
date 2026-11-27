#!/usr/bin/env python3
"""
QGIS performance benchmark suite (PyQGIS).

Measures REAL QGIS operations against REAL (locally generated, deterministic)
geospatial data. Run it with the Python interpreter shipped with QGIS, e.g.:

    qgis_process --python?  # no — use the bundled interpreter, e.g.
    python3 scripts/perf/qgis-perf-bench.py --data-dir /tmp/qgis-bench-data

or under the QGIS docker images:

    python3 scripts/perf/qgis-perf-bench.py --data-dir /tmp/bench-data --markdown bench.md

IMPORTANT HONESTY NOTE
----------------------
Numbers produced here are real QGIS timings, but on SYNTHETIC data generated
deterministically on your machine. They are excellent for regression tracking
(before/after a change, machine-vs-machine with same seed) and are NOT a
substitute for benchmarks on your own production projects.

Covered metrics
---------------
  app_init            QgsApplication create + initQgis (in-process, headless)
  data_generation     deterministic GeoPackage generation (excluded from score)
  project_write       build a project referencing the layers and save it
  project_read        reopen the saved project
  render_first        first full render (all layers, parallel job)
  render_warm         immediate second render (renderer cache path)
  pan_x10             10 consecutive shifted renders (pan-like cache invalidation)
  zoom_x5             5 progressive zoom-ins
  feature_scan        full attribute+geometry iteration over the point layer
  expression_filter   provider-request with expression filter over same layer
  expression_eval     prepared expression evaluated per feature (100k)
  coord_transform     100k point reprojections (4326 -> 3857)
  unique_values       layer.uniqueValues() on a text field
  processing_alg      (optional) native buffer via processing plugin
  memory              ru_maxrss delta across the suite

Every metric reports median and best of N repetitions.
"""
import argparse
import json
import os
import platform
import random
import statistics
import sys
import time

# --------------------------------------------------------------------------- #
# QGIS bootstrap (headless)
# --------------------------------------------------------------------------- #
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_LOGGING_RULES", "debug=false")

from qgis.core import (  # noqa: E402
    Qgis,
    QgsApplication,
    QgsCoordinateReferenceSystem,
    QgsCoordinateTransform,
    QgsExpression,
    QgsExpressionContext,
    QgsFeature,
    QgsFeatureRequest,
    QgsField,
    QgsFillSymbol,
    QgsGeometry,
    QgsMapRendererParallelJob,
    QgsMapSettings,
    QgsPointXY,
    QgsProject,
    QgsRasterLayer,
    QgsRectangle,
    QgsVectorFileWriter,
    QgsVectorLayer,
    QgsCoordinateTransformContext,
)

from qgis.PyQt.QtCore import Qgis as _UnusedQt  # noqa: F401  (ensures PyQt import path works)
from qgis.PyQt.QtGui import QColor, QImage, QPainter  # noqa: E402

FIELDS = [
    ("name", "string", 24),
    ("category", "string", 12),
    ("value", "double"),
    ("count", "integer"),
    ("code", "integer"),
    ("label", "string", 16),
]
CATEGORIES = ["alpha", "beta", "gamma", "delta"]


def generate_sample_data(data_dir: str, n_points: int, n_polys: int) -> dict:
    """Deterministically generate sample GeoPackages. Returns dataset info."""
    os.makedirs(data_dir, exist_ok=True)
    info = {}
    rng = random.Random(20261126)

    # ---------------- points -------------------------------------------------
    pts_path = os.path.join(data_dir, "bench_points.gpkg")
    if not os.path.exists(pts_path):
        layer = QgsVectorLayer(
            "Point?crs=EPSG:4326", "bench_points_src", "memory"
        )
        pr = layer.dataProvider()
        pr.addAttributes([QgsField(f, t) for f, t, *_ in FIELDS])
        layer.updateFields()
        feats = []
        for i in range(n_points):
            g = QgsGeometry.fromPointXY(
                QgsPointXY(-179.0 + rng.random() * 358.0, -79.0 + rng.random() * 158.0)
            )
            f = QgsFeature(layer.fields())
            f.setGeometry(g)
            f.setAttributes(
                [
                    "pt-%06d" % i,
                    CATEGORIES[i % len(CATEGORIES)],
                    rng.random() * 1000.0,
                    rng.randrange(1000),
                    rng.randrange(65536),
                    "lab-%05d" % (i % 9973),
                ]
            )
            feats.append(f)
        pr.addFeatures(feats)
        res = QgsVectorFileWriter.writeAsVectorFormatV3(
            layer, pts_path, QgsCoordinateTransformContext(),
            QgsVectorFileWriter.SaveVectorOptions(),
        )
        err = res[0] if isinstance(res, tuple) else res
        if err != QgsVectorFileWriter.NoError:
            raise RuntimeError("point export failed: %s" % err)
    info["points"] = {"path": pts_path, "count": n_points}

    # ---------------- polygons -----------------------------------------------
    poly_path = os.path.join(data_dir, "bench_polys.gpkg")
    if not os.path.exists(poly_path):
        layer = QgsVectorLayer(
            "Polygon?crs=EPSG:4326", "bench_polys_src", "memory"
        )
        pr = layer.dataProvider()
        pr.addAttributes([QgsField(f, t) for f, t, *_ in FIELDS[:4]])
        layer.updateFields()
        feats = []
        for i in range(n_polys):
            x0 = -179.0 + rng.random() * 350.0
            y0 = -79.0 + rng.random() * 150.0
            dx, dy = 0.5 + rng.random() * 4.0, 0.5 + rng.random() * 3.0
            g = QgsGeometry.fromRectXY(QgsRectangle(x0, y0, x0 + dx, y0 + dy))
            f = QgsFeature(layer.fields())
            f.setGeometry(g)
            f.setAttributes(
                [
                    "poly-%05d" % i,
                    CATEGORIES[i % len(CATEGORIES)],
                    rng.random() * 5000.0,
                    rng.randrange(500),
                ]
            )
            feats.append(f)
        pr.addFeatures(feats)
        res = QgsVectorFileWriter.writeAsVectorFormatV3(
            layer, poly_path, QgsCoordinateTransformContext(),
            QgsVectorFileWriter.SaveVectorOptions()
        )
        err = res[0] if isinstance(res, tuple) else res
        if err != QgsVectorFileWriter.NoError:
            raise RuntimeError("polygon export failed: %s" % err)
    info["polys"] = {"path": poly_path, "count": n_polys}

    # ---------------- raster (2000x2000 float32 GeoTIFF) ---------------------
    # Written with the GDAL python bindings (always present in a QGIS env).
    raster_path = os.path.join(data_dir, "bench_raster.tif")
    if not os.path.exists(raster_path):
        try:
            import numpy as np
            from osgeo import gdal, osr
        except ImportError:
            print("  raster generation skipped: osgeo/numpy not importable")
            info["raster"] = None
            return info
        gdal.UseExceptions()
        rng2 = np.random.default_rng(20261126)
        arr = rng2.random((2000, 2000)).astype(np.float32) * 4000.0
        drv = gdal.GetDriverByName("GTiff")
        ds = drv.Create(raster_path, 2000, 2000, 1, gdal.GDT_Float32,
                        options=["COMPRESS=DEFLATE", "TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256"])
        ds.SetGeoTransform((-180.0, 360.0 / 2000.0, 0.0, 80.0, 0.0, -160.0 / 2000.0))
        srs = osr.SpatialReference()
        srs.ImportFromEPSG(4326)
        ds.SetProjection(srs.ExportToWkt())
        ds.GetRasterBand(1).WriteArray(arr)
        ds.GetRasterBand(1).SetNoDataValue(-9999.0)
        ds = None  # flush
    info["raster"] = {"path": raster_path, "size": "2000x2000 float32 tiled"}
    return info


class Bench:
    """Collects named benchmarks: each run returns seconds (float)."""

    def __init__(self, repeats: int):
        self.repeats = repeats
        self.results = {}   # name -> list of seconds
        self.notes = {}     # name -> extra info

    def run(self, name, fn, note=None, repeatable=True):
        times = []
        for i in range(self.repeats if repeatable else 1):
            t0 = time.perf_counter()
            fn()
            times.append(time.perf_counter() - t0)
        self.results[name] = times
        if note:
            self.notes[name] = note
        print("  %-22s median %8.3f s  (best %8.3f s, n=%d)"
              % (name, statistics.median(times), min(times), len(times)))
        return statistics.median(times)

    def table(self):
        rows = []
        for name, times in self.results.items():
            row = {
                "name": name,
                "median_s": round(statistics.median(times), 4),
                "best_s": round(min(times), 4),
                "n": len(times),
                "note": self.notes.get(name, ""),
            }
            if len(times) >= 2:
                q = statistics.quantiles(times, n=10)
                row["p10_s"] = round(q[0], 4)
                row["p90_s"] = round(q[8], 4)
            rows.append(row)
        return rows


def make_map_settings(project, extent):
    settings = QgsMapSettings()
    settings.setLayers([l for l in project.mapLayers().values() if isinstance(l, QgsVectorLayer)])
    settings.setExtent(extent)
    settings.setOutputSize(QImage(1600, 1200, QImage.Format_RGB32).size())
    settings.setDestinationCrs(QgsCoordinateReferenceSystem("EPSG:4326"))
    settings.setBackgroundColor(QColor(255, 255, 255))
    settings.setFlag(Qgis.MapSettingsFlag.DrawLabeling, True)
    settings.setFlag(Qgis.MapSettingsFlag.Antialiasing, True)
    return settings


def do_render(settings):
    """Blocking full render using the parallel job (real canvas code path)."""
    job = QgsMapRendererParallelJob(settings)
    job.start()
    job.waitForFinished()  # blocking; void return (qgsmaprendererjob.h)
    return job


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", default="/tmp/qgis-perf-bench-data")
    ap.add_argument("--features", type=int, default=100000, help="number of synthetic points")
    ap.add_argument("--polys", type=int, default=3000, help="number of synthetic polygons")
    ap.add_argument("--repeats", type=int, default=3, help="repetitions per benchmark (median reported)")
    ap.add_argument("--json", default=None, help="write full results as JSON")
    ap.add_argument("--markdown", default=None, help="write a markdown summary")
    ap.add_argument("--label", default="", help="label (e.g. before/after) for the report header")
    args = ap.parse_args()

    print("== QGIS performance benchmark ==")
    t0 = time.perf_counter()
    qgs = QgsApplication([], False)
    qgs.initQgis()
    app_init = time.perf_counter() - t0
    print("  app_init               %8.3f s" % app_init)

    bench = Bench(args.repeats)
    bench.results["app_init"] = [app_init]
    bench.notes["app_init"] = "in-process headless init (not full UI startup)"

    # ---- data ---------------------------------------------------------------
    have = (os.path.exists(os.path.join(args.data_dir, "bench_points.gpkg"))
            and os.path.exists(os.path.join(args.data_dir, "bench_polys.gpkg")))
    if not have:
        t = time.perf_counter()
        info = generate_sample_data(args.data_dir, args.features, args.polys)
        gen_s = time.perf_counter() - t
        print("  data_generation        %8.3f s  (%d pts / %d polys)"
              % (gen_s, args.features, args.polys))
        bench.results["data_generation"] = [gen_s]
        bench.notes["data_generation"] = "deterministic seed; excluded from comparisons"
    else:
        print("  data_generation        reused existing files")
        bench.results["data_generation"] = [0.0]
        bench.notes["data_generation"] = "reused existing files"

    # ---- layers & project ---------------------------------------------------
    pts = QgsVectorLayer(os.path.join(args.data_dir, "bench_points.gpkg") + "|layername=bench_points", "points", "ogr")
    polys = QgsVectorLayer(os.path.join(args.data_dir, "bench_polys.gpkg") + "|layername=bench_polys", "polys", "ogr")
    if not pts.isValid() or not polys.isValid():
        print("FATAL: generated layers invalid", file=sys.stderr)
        return 2
    # simple but non-trivial rendering: categorized fill + labeled points
    from qgis.core import QgsCategorizedSymbolRenderer, QgsRendererCategory, QgsPalLayerSettings, QgsTextFormat, QgsVectorLayerSimpleLabeling
    sym_a = QgsFillSymbol.createSimple({"color": "220,235,255", "outline_color": "60,90,140"})
    sym_b = QgsFillSymbol.createSimple({"color": "255,230,200", "outline_color": "160,110,60"})
    polys.setRenderer(QgsCategorizedSymbolRenderer(
        "category", [QgsRendererCategory("alpha", sym_a, "alpha"), QgsRendererCategory("beta", sym_b, "beta")]))
    lbl = QgsPalLayerSettings()
    lbl.fieldName = "name"
    fmt = QgsTextFormat()
    fmt.setSize(6)
    lbl.setFormat(fmt)
    pts.setLabeling(QgsVectorLayerSimpleLabeling(lbl))
    pts.setLabelsEnabled(True)
    for l in (pts, polys):
        l.updateExtents()

    project = QgsProject.instance()
    project.clear()
    t = time.perf_counter()
    project.addMapLayer(polys, False)
    project.addMapLayer(pts, True)
    proj_path = os.path.join(args.data_dir, "bench.qgs")
    project.write(proj_path)
    bench.run("project_write", lambda: project.write(proj_path))
    bench.notes["project_write"] = "%d layers" % len(project.mapLayers())

    def reopen():
        p2 = QgsProject.instance()
        p2.clear()
        p2.read(proj_path)
    bench.run("project_read", reopen)
    bench.notes["project_read"] = proj_path

    # ---- rendering ----------------------------------------------------------
    full_extent = QgsRectangle(-180, -80, 180, 80)

    def render_first():
        s = make_map_settings(project, full_extent)
        do_render(s)
    bench.run("render_first", render_first, repeatable=False)

    def render_warm():
        s = make_map_settings(project, full_extent)
        do_render(s)
    bench.run("render_warm", render_warm)
    bench.notes["render_warm"] = "second identical render (renderer cache)"

    # pan: 10 successive small shifts (like user panning)
    def pans():
        x = -180.0
        for _ in range(10):
            x += 8.0
            s = make_map_settings(project, QgsRectangle(x, -80, x + 360, 80))
            do_render(s)
    bench.run("pan_x10", pans)
    bench.notes["pan_x10"] = "10 successive 8-degree shifts, full re-render each"

    # zoom: 5 zoom-ins on a region
    def zooms():
        ext = full_extent
        for _ in range(5):
            ext = QgsRectangle(ext.xMinimum() + 40, ext.yMinimum() + 30,
                               ext.xMaximum() - 40, ext.yMaximum() - 30)
            s = make_map_settings(project, ext)
            do_render(s)
    bench.run("zoom_x5", zooms)
    bench.notes["zoom_x5"] = "5 successive 2x zoom-ins"

    # ---- data & expression engines -----------------------------------------
    bench.run("feature_scan", lambda: sum(1 for _ in pts.getFeatures()), note="%d features" % args.features)

    def expr_filter():
        req = QgsFeatureRequest(QgsExpression("\"count\" > 500"))
        return sum(1 for _ in pts.getFeatures(req))
    bench.run("expression_filter", expr_filter)

    expr = QgsExpression("\"value\" * 2 + length(\"name\")")
    ctx = QgsExpressionContext()
    expr.prepare(ctx)

    def expr_eval():
        it = pts.getFeatures()
        f = QgsFeature()
        n = 0
        while it.nextFeature(f):
            ctx.setFeature(f)
            expr.evaluate(ctx)
            n += 1
        return n
    bench.run("expression_eval", expr_eval)

    def transforms():
        xform = QgsCoordinateTransform(
            QgsCoordinateReferenceSystem("EPSG:4326"),
            QgsCoordinateReferenceSystem("EPSG:3857"),
            project.transformContext(),
        )
        n = 0
        for _ in range(1000):
            for _ in range(100):
                p = xform.transform(QgsPointXY(-179.0 + random.random() * 358.0, -79.0 + random.random() * 158.0))
                n += 1
        return n
    bench.run("coord_transform_100k", transforms)

    bench.run("unique_values", lambda: len(pts.uniqueValues(pts.fields().lookupField("category"))))

    # ---- raster engine -------------------------------------------------------
    raster_path = os.path.join(args.data_dir, "bench_raster.tif")
    if os.path.exists(raster_path) and os.path.getsize(raster_path) > 0:
        rlayer = QgsRasterLayer(raster_path, "bench_raster")
        if rlayer.isValid():
            rfull = QgsRectangle(-180, -80, 180, 80)

            def raster_blocks():
                dp = rlayer.dataProvider()
                total = 0
                for by in range(0, 2000, 256):
                    for bx in range(0, 2000, 256):
                        w = min(256, 2000 - bx)
                        h = min(256, 2000 - by)
                        x0 = -180.0 + (bx / 2000.0) * 360.0
                        x1 = -180.0 + ((bx + w) / 2000.0) * 360.0
                        y1 = 80.0 - (by / 2000.0) * 160.0
                        y0 = 80.0 - ((by + h) / 2000.0) * 160.0
                        blk = dp.block(1, QgsRectangle(x0, y0, x1, y1), w, h)
                        total += 1 if blk else 0
                return total
            bench.run("raster_blocks_64", raster_blocks,
                      note="64 blocks of 256x256 from 2000x2000 GeoTIFF")

            def raster_render():
                s = QgsMapSettings()
                s.setLayers([rlayer])
                s.setExtent(rfull)
                s.setOutputSize(QImage(1600, 1200, QImage.Format_RGB32).size())
                s.setDestinationCrs(QgsCoordinateReferenceSystem("EPSG:4326"))
                do_render(s)
            bench.run("raster_render_full", raster_render,
                      note="full render of the 2000x2000 GeoTIFF")
        else:
            print("  raster benchmarks skipped: invalid raster layer")

    # ---- optional: processing ----------------------------------------------
    try:
        import processing  # noqa
        alg_ready = True
    except Exception:
        alg_ready = False
    if alg_ready:
        try:
            def run_alg():
                processing.run("native:buffer",
                              {"INPUT": polys, "DISTANCE": 0.5, "OUTPUT": "memory:"},
                              feedback=None)
            bench.run("processing_buffer", run_alg, note="native:buffer on %d polys" % args.polys)
        except Exception as e:  # alg missing in minimal builds
            print("  processing_buffer skipped: %s" % e)
    else:
        print("  processing_buffer skipped: processing plugin not importable")

    # ---- memory -------------------------------------------------------------
    import resource
    maxrss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0
    bench.results["memory_peak_rss_mb"] = [maxrss_mb]
    bench.notes["memory_peak_rss_mb"] = "peak RSS (linux: KB units converted)"

    # ---- report -------------------------------------------------------------
    rows = bench.table()
    version = "%s %s" % (Qgis.QGIS_VERSION, Qgis.QGIS_VERSION_CODE)
    env = {
        "qgis": version,
        "qt": Qgis.QT_VERSION_STR if hasattr(Qgis, "QT_VERSION_STR") else "",
        "python": platform.python_version(),
        "cores": os.cpu_count(),
        "label": args.label,
        "features": args.features,
        "polys": args.polys,
    }
    result = {"env": env, "rows": rows}
    if args.json:
        with open(args.json, "w") as f:
            json.dump(result, f, indent=2)

    if args.markdown:
        with open(args.markdown, "w") as f:
            f.write("# QGIS performance benchmark%s\n\n" % (" — " + args.label if args.label else ""))
            f.write("| Metric | Median (s) | p10 (s) | p90 (s) | Best (s) | n | Note |\n|---|---|---|---|---|---|---|\n")
            for r in rows:
                f.write("| %s | %s | %s | %s | %s | %d | %s |\n" % (
                    r["name"], r["median_s"], r.get("p10_s", "-"), r.get("p90_s", "-"),
                    r["best_s"], r["n"], r["note"]))
            f.write("\nEnvironment: QGIS %s, Qt %s, Python %s, cores %s, %d pts / %d polys\n"
                    % (env["qgis"], env["qt"], env["python"], env["cores"], env["features"], env["polys"]))
            f.write("\n> Synthetic deterministic data (seed 20261126). Real QGIS timings,\n"
                    "> regression-tracking purposes — not comparable across datasets.\n")

    qgs.exitQgis()
    return 0


if __name__ == "__main__":
    sys.exit(main())
