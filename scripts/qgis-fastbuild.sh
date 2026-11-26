#!/usr/bin/env bash
#
# QGIS "fast build" driver — squeeze rebuilds into seconds-to-minutes.
#
# How the speed is achieved (all levers at once):
#   - Ninja (automatic full parallelism, tiny no-op rebuilds)
#   - ccache compiler cache: unchanged translation units are not recompiled
#   - Unity builds: many .cpp files merged per compilation unit
#   - Precompiled headers (default ON on non-MSVC)
#   - mold/lld linker when available (the final link is often the bottleneck)
#   - Minimal feature set via the CMake presets (no Python, no server, no
#     GRASS/Oracle/HANA/PDAL/EPT/3D/QtWebEngine...) and only building the
#     requested target instead of everything.
#
# Honest expectations:
#   - FIRST run (or after `rm -rf build-fast`): a full one-time build, tens of
#     minutes depending on your CPU. ccache fills up: this is the only slow one.
#   - Every later run: touching a few files => usually well under two minutes;
#     touching a single .cpp => a few seconds + the link.
#   - Touching a very central header (qgsvectorsimplify.h-level) invalidates a
#     large share of the cache; those rebuilds can exceed two minutes on
#     low-core machines. Physics.
#
# Usage:
#   scripts/qgis-fastbuild.sh                 # build the 'qgis' app target
#   scripts/qgis-fastbuild.sh qgis_core       # build a specific target only
#   QGIS_FAST_PRESET=fast-python scripts/qgis-fastbuild.sh
#   QGIS_FAST_PRESET=fast-release  scripts/qgis-fastbuild.sh
#
# The binary lands in build-fast/output/bin/qgis.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${QGIS_FAST_PRESET:-fast}"
BUILD_DIR="${SOURCE_DIR}/build-fast"
TARGET="${1:-qgis}"

command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake not found in PATH" >&2; exit 1; }

# ccache: allow cache hits on precompiled-header based compilations.
if command -v ccache >/dev/null 2>&1; then
  ccache --set-config sloppiness=pch_defines,time_macros,include_file_mtime,include_file_ctime
  ccache -z >/dev/null 2>&1 || true
fi

# Configure on first use, through the preset (Ninja + minimal feature set +
# unity builds). Add mold/lld when available: it cuts the final link time hard.
if [[ ! -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
  echo "==> First run with preset '${PRESET}': one-time full build incoming..."
  echo "==> Grab a coffee; every rebuild after this one will be fast."
  LINKER_FLAG=()
  for l in mold lld; do
    if command -v "$l" >/dev/null 2>&1 || command -v "ld.$l" >/dev/null 2>&1; then
      LINKER_FLAG=(-DUSE_ALTERNATE_LINKER="$l")
      echo "==> Using the '$l' linker for fast linking"
      break
    fi
  done
  cmake --preset "${PRESET}" "${LINKER_FLAG[@]}"
fi

echo "==> Building target '${TARGET}' (preset '${PRESET}')..."
START=$SECONDS
cmake --build "${BUILD_DIR}" --target "${TARGET}"
ELAPSED=$(( SECONDS - START ))
echo "==> Build finished in ${ELAPSED}s"

if command -v ccache >/dev/null 2>&1; then
  echo "==> ccache statistics (hit rate on recent builds):"
  ccache -s | sed -n '1,12p'
fi

BIN="${BUILD_DIR}/output/bin/qgis"
if [[ "${TARGET}" == "qgis" && -x "${BIN}" ]]; then
  echo "==> Ready: ${BIN}"
  echo "==> Launch it with: ${BIN}"
fi

echo "==> Tip: run './scripts/qgis-fastbuild.sh' again after editing sources — most rebuilds take under two minutes."
