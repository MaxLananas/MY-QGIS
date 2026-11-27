#!/usr/bin/env bash
# Run the QGIS performance benchmark suite headlessly.
#
# Requires a QGIS installation whose Python can import qgis.core
# (Linux: the bundled python3; CI: the QGIS build-deps docker image).
#
# Usage:
#   scripts/perf/run-perf-bench.sh [output-dir]
#
# Outputs in the given directory (default ./perf-results):
#   bench.json    machine-readable results
#   bench.md      markdown report (paste-ready)
#
# Notes on honesty:
# - timings are real QGIS operations (rendering jobs, provider requests,
#   expressions, transforms) on deterministic synthetic data generated
#   on the local machine;
# - "app_init" measures in-process headless init, NOT full UI startup
#   time (UI startup requires a desktop session; measure it interactively).
set -euo pipefail

OUT_DIR="${1:-perf-results}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT_DIR"

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export QT_LOGGING_RULES="${QT_LOGGING_RULES:-debug=false}"

echo "==> environment"
python3 - <<'EOF'
try:
    import qgis.core
    from qgis.core import Qgis
    print("QGIS:", Qgis.QGIS_VERSION, "| Qt:", Qgis.QT_VERSION_STR)
except Exception as e:
    raise SystemExit("qgis python module not importable: %s\nRun inside a QGIS environment (e.g. the QGIS docker images)." % e)
EOF

echo "==> benchmark run"
python3 "$HERE/qgis-perf-bench.py" \
  --data-dir "$OUT_DIR/data" \
  --json "$OUT_DIR/bench.json" \
  --markdown "$OUT_DIR/bench.md" \
  --label "${PERF_LABEL:-}" \
  --repeats "${PERF_REPEATS:-3}"

echo "==> results: $OUT_DIR/bench.md (json: $OUT_DIR/bench.json)"
