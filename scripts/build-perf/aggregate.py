#!/usr/bin/env python3
"""Assemble the final build-performance verdict from the per-scenario artifacts.

Usage: aggregate.py <artifacts-root> [--markdown OUT]
Expected layout (actions/download-artifact with pattern results-*):
  <root>/results-s1-cold/...          results-s2-warm/...  results-s3-incremental/...
  results-s4-dependency/...           results-linker-ab/...  results-s0-serial/...

Reads timings.txt (+ ninja_analysis.json) from each scenario, computes the
busy-core wall floors at 4/8/16/32 vCPU and emits explicit verdicts against
the 5-minute (full build) and 2-minute (incremental) targets.

--selftest builds a synthetic artifact tree with known numbers and asserts
the verdict logic end-to-end.
"""

import argparse
import json
import sys
from pathlib import Path


def read_timings(scen_dir: Path) -> dict:
    out = {}
    p = scen_dir / "timings.txt"
    if not p.exists():
        return out
    for line in p.read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                out[parts[0]] = parts[1]
    return out


def fmt_ms(v) -> str:
    if isinstance(v, int):
        return f"{v / 1000:.0f} s" if v >= 90_000 else f"{v / 1000:.1f} s"
    return str(v)


def build_verdict(art_root: Path) -> str:
    cold = read_timings(art_root / "results-s1-cold")
    warm = read_timings(art_root / "results-s2-warm")
    incr = read_timings(art_root / "results-s3-incremental")
    dep = read_timings(art_root / "results-s4-dependency")
    links = read_timings(art_root / "results-linker-ab")

    lines = ["## 🏗 Build performance — verdict", "", "| Scenario | Time |", "|---|---|"]
    cb = cold.get("build_ms")
    if cb:
        lines.append(f"| S1 cold full build (4 vCPU) | {fmt_ms(cb)} |")
    wb = warm.get("warm_build_ms_1")
    wb2 = warm.get("warm_build_ms_2")
    if wb:
        lo, hi = sorted(x for x in (wb, wb2) if isinstance(x, int))
        lines.append(
            f"| S2 warm full build, fresh runner | {fmt_ms(lo)} … {fmt_ms(hi)} |"
        )
    for k in sorted(incr):
        if k.startswith("incr_"):
            lines.append(f"| S3 {k[:-3]} | {fmt_ms(incr[k])} |")
    if dep.get("dep_total_ms"):
        lines.append(
            f"| S4 dependency-style (core header) | {fmt_ms(dep['dep_total_ms'])} |"
        )
    if links.get("link_bfd_ms"):
        lines.append(
            f"| Linker A/B: bfd full relink | {fmt_ms(links['link_bfd_ms'])} |"
        )
    if links.get("link_mold_ms"):
        lines.append(
            f"| Linker A/B: mold same objects | {fmt_ms(links['link_mold_ms'])} |"
        )
    lines.append("")

    try:
        na = json.loads(
            (art_root / "results-s1-cold" / "ninja_analysis.json").read_text()
        )
        busy = na.get("busy_ms", 0)
        lines.append(
            f"**Cold build busy core-seconds: {busy / 1000:.0f}** (sum over all ninja edges)."
        )
        lines.append("Wall-time floor = busy / cores, ignoring serial gaps:")
        for c in (4, 8, 16, 32):
            lines.append(f"- {c} vCPU → ≥ {busy / 1000 / c / 60:.1f} min")
        if cb:
            lines.append(
                f"- Measured cold wall on 4 vCPU: {cb / 1000 / 60:.1f} min "
                f"(efficiency busy/wall = {na.get('efficiency')})"
            )
        lines.append(
            f"- Slowest single edge: {na.get('max_ms', 0)} ms; edges: {na.get('edges', 0)}"
        )
        lines.append("")
    except (OSError, ValueError):
        lines.append("(cold ninja analysis unavailable)")
        lines.append("")
        busy = None

    s0_dir = art_root / "results-s0-serial"
    if (s0_dir / "ninja_analysis.json").exists():
        try:
            s0 = json.loads((s0_dir / "ninja_analysis.json").read_text())
            lines.append(
                f"**S0 serial qgis_core profile** (busy {s0.get('busy_ms', 0) / 1000:.0f} s):"
            )
            for i, t in enumerate(s0.get("top", [])[:10], 1):
                cmd = t["cmd"][:110] if t["cmd"] else "(n/a)"
                lines.append(f"{i}. {t['ms']} ms `{cmd}`")
            lines.append("")
        except ValueError:
            pass

    five_ok = isinstance(cb, int) and cb < 300_000
    lines.append(
        f"**Verdict (full build ≤ 5 min): {'MEETS' if five_ok else 'CANNOT MEET'} on 4 vCPU**"
        + (
            ""
            if five_ok
            else " — the busy-core floor proves the hardware bound; see the vCPU table above."
        )
    )
    incr_vals = [
        v for k, v in incr.items() if k.startswith("incr_") and isinstance(v, int)
    ]
    if incr_vals:
        best = min(incr_vals)
        lines.append(
            f"**Verdict (incremental ≤ 2 min): {'MEETS' if best < 120_000 else 'CANNOT MEET'}** "
            f"(best {fmt_ms(best)})."
        )
    return "\n".join(lines)


def selftest(tmp: Path) -> None:
    def mk(scen, pairs):
        d = tmp / f"results-{scen}"
        d.mkdir(parents=True)
        d.joinpath("timings.txt").write_text("".join(f"{k} {v}\n" for k, v in pairs))

    mk("s1-cold", [("configure_ms", 30000), ("build_ms", 2_400_000)])
    mk("s2-warm", [("warm_build_ms_1", 260_000), ("warm_build_ms_2", 250_000)])
    mk(
        "s3-incremental",
        [("incr_qgisapp_cpp_ms", 95_000), ("incr_qgswelcomescreen_cpp_ms", 88_000)],
    )
    mk("s4-dependency", [("dep_total_ms", 2_100_000)])
    mk("linker-ab", [("link_bfd_ms", 600_000), ("link_mold_ms", 240_000)])
    d = tmp / "results-s1-cold"
    d.joinpath("ninja_analysis.json").write_text(
        json.dumps(
            {"busy_ms": 1_800_000, "edges": 1685, "efficiency": 3.4, "max_ms": 42_000}
        )
    )
    s0 = tmp / "results-s0-serial"
    s0.mkdir()
    s0.joinpath("ninja_analysis.json").write_text(
        json.dumps(
            {
                "busy_ms": 900_000,
                "top": [
                    {"ms": 42_000, "phase": "compile", "cmd": "g++ -c unity_5.cpp"}
                ],
            }
        )
    )
    v = build_verdict(tmp)
    assert "S1 cold full build (4 vCPU) | 2400 s" in v
    assert "CANNOT MEET" in v  # 2400 s > 300 s
    assert "MEETS** (best 88.0 s)" in v
    assert "unity_5.cpp" in v
    assert "32 vCPU → ≥ 0.9 min" in v  # 1_800_000 ms / 32 cores = 56 s


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("artifacts", nargs="?", help="artifacts root dir")
    ap.add_argument("--markdown", dest="md_out")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            selftest(Path(td))
        print("selftest OK")
        return 0
    if not args.artifacts:
        print("error: artifacts root required (or --selftest)", file=sys.stderr)
        return 2
    verdict = build_verdict(Path(args.artifacts))
    print(verdict)
    if args.md_out:
        Path(args.md_out).write_text(verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
