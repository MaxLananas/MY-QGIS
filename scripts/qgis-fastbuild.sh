#!/usr/bin/env bash
#
# QGIS "fast build" driver — squeeze rebuilds into seconds-to-minutes.
#
# Speed levers (all engaged at once):
#   - Ninja: full parallelism, near-zero-cost no-op rebuilds
#   - ccache: unchanged translation units are never recompiled
#       * sloppiness=pch_defines,time_macros,include_file_mtime,include_file_ctime
#         (required for precompiled-header hits, per ccache(1) PRECOMPILED HEADERS)
#       * hash_dir=false: cache stays valid when the build directory moves
#         (local clone, container /root/QGIS, another checkout path)
#       * inode_cache=true (ccache >= 4.10, silently skipped otherwise)
#   - Unity builds (CMake merges 8 sources per batch by default) + PCH
#   - mold (or lld) linker: the final link drops from minutes to seconds
#   - Minimal feature set via CMakeUserPresets.json + single-target builds
#   - -g1 debug info (line tables only) on GCC/Clang: much smaller objects,
#     faster compiles, faster links, faster ccache (not applied on Windows)
#
# Honest expectations:
#   - FIRST run (or after --clean): a full one-time build (tens of minutes,
#     machine-dependent). ccache fills up; it only happens once.
#   - Every later run: a few files touched => usually well under two minutes;
#     a single .cpp touched => seconds + the link.
#   - A very central header change invalidates a large share of the cache.
#
# Usage:
#   scripts/qgis-fastbuild.sh                     # build the 'qgis' app target
#   scripts/qgis-fastbuild.sh qgis_core           # positional target
#   scripts/qgis-fastbuild.sh --preset fast-python
#   scripts/qgis-fastbuild.sh --target qgis_gui
#   scripts/qgis-fastbuild.sh --doctor            # environment health check
#   scripts/qgis-fastbuild.sh --clean             # wipe build dir, start over
#   scripts/qgis-fastbuild.sh --profile           # ninja -d stats + timing per-target
#   scripts/qgis-fastbuild.sh --trace             # clang -ftime-trace per-TU profiles
#                                                 # (+ ClangBuildAnalyzer if installed)
#   scripts/qgis-fastbuild.sh --graph             # dump the ninja dependency graph
#   QGIS_FAST_PRESET=fast-release  scripts/qgis-fastbuild.sh   # env-var style

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${QGIS_FAST_PRESET:-fast}"
BUILD_DIR="${SOURCE_DIR}/build-fast"
TARGET="qgis"

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)  PRESET="$2"; shift 2 ;;
    --target)  TARGET="$2"; shift 2 ;;
    --doctor)  DOCTOR=1; shift ;;
    --clean)   CLEAN=1; shift ;;
    --profile) PROFILE=1; shift ;;
    --trace)   TRACE=1; shift ;;
    --graph)   GRAPH=1; shift ;;
    --help|-h) usage ;;
    -*)        echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    *)         TARGET="$1"; shift ;;   # positional target
  esac
done

command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake not found in PATH" >&2; exit 1; }

# ---------------------------------------------------------------- doctor ----
if [[ "${DOCTOR:-0}" == "1" ]]; then
  echo "== QGIS fast-build doctor =="
  echo "cores available : $(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo '?')"
  echo "cmake           : $(cmake --version | head -1)"
  if command -v ninja >/dev/null 2>&1; then echo "ninja           : $(ninja --version)"; else echo "ninja           : MISSING (required!)"; fi
  if command -v ccache >/dev/null 2>&1; then
    echo "ccache          : $(ccache --version | head -1)"
    echo "ccache max size : $(ccache --get-config max-size 2>/dev/null || echo '?')"
    echo "ccache dir      : $(ccache --get-config cache_dir 2>/dev/null || echo default) [$(du -sh "$(ccache --get-config cache_dir 2>/dev/null || echo "${HOME}/.ccache")" 2>/dev/null | cut -f1)]"
    echo "ccache sloppin. : $(ccache --get-config sloppiness 2>/dev/null || echo '?')"
    echo "ccache hash_dir : $(ccache --get-config hash_dir 2>/dev/null || echo '?')"
  else
    echo "ccache          : MISSING (builds will be much slower)"
  fi
  for l in mold lld; do
    command -v "$l" >/dev/null 2>&1 && echo "linker          : $l available"
  done
  echo "presets         :"
  cmake --list-presets -S "${SOURCE_DIR}" 2>&1 | sed 's/^/    /'
  if [[ -d "${BUILD_DIR}" ]]; then
    echo "build dir       : ${BUILD_DIR} [$(du -sh "${BUILD_DIR}" 2>/dev/null | cut -f1)]"
  else
    echo "build dir       : (not configured yet)"
  fi
  exit 0
fi

[[ "${CLEAN:-0}" == "1" ]] && { rm -rf "${BUILD_DIR}"; echo "==> Removed ${BUILD_DIR}"; }

command -v ninja >/dev/null 2>&1 || echo "WARNING: ninja not found — install it for full speed" >&2

# ------------------------------------------------------- ccache tuning ------
# Values straight from ccache(1): the sloppiness set is the documented
# requirement for precompiled headers; hash_dir=false keeps the cache valid
# across build directories; inode_cache accelerates cache lookups when
# supported. depend_mode is deliberately NOT enabled: the manual documents a
# lower hit rate as its trade-off, which would hurt more than the saved
# preprocessing helps.
if command -v ccache >/dev/null 2>&1; then
  ccache --set-config sloppiness=pch_defines,time_macros,include_file_mtime,include_file_ctime
  ccache --set-config hash_dir=false
  ccache --set-config compiler_check=content
  ccache --set-config max-size=2G
  ccache --set-config inode_cache=true 2>/dev/null || true
fi

# ------------------------------------------------------------ configure -----
# Configure on first use only: re-running cmake would churn Ninja files for
# nothing on a day-to-day basis (touch a file, rebuild, nothing else).
if [[ ! -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
  echo "==> First run with preset '${PRESET}': one-time full build incoming..."
  echo "==> Grab a coffee; every rebuild after this one will be fast."
  EXTRA_FLAGS=()

  # Fast linker when available (Linux toolchains; mold > lld).
  for l in mold lld; do
    if command -v "$l" >/dev/null 2>&1 || command -v "ld.$l" >/dev/null 2>&1; then
      EXTRA_FLAGS+=(-DUSE_ALTERNATE_LINKER="$l")
      echo "==> Using the '$l' linker for fast linking"
      break
    fi
  done

  # Slim debug info (line tables only) on GCC/Clang platforms: noticeably
  # faster compiles, links and ccache hashing than full -g. Skipped on
  # Windows where the preset may end up feeding MSVC.
  case "$(uname -s)" in
    MINGW*|CYGWIN*|Windows*) : ;;
    *)
      EXTRA_FLAGS+=(-DCMAKE_C_FLAGS_DEBUG=-g1 -DCMAKE_CXX_FLAGS_DEBUG=-g1)
      echo "==> Debug info slimmed to -g1 (line tables)"
      ;;
  esac

  cmake --preset "${PRESET}" "${EXTRA_FLAGS[@]}"
fi

# --------------------------------------------------------------- build ------
# --graph: dump the ninja dependency graph (dot format) and edge counts, then exit.
if [[ "${GRAPH:-0}" == "1" ]]; then
  [[ -f "${BUILD_DIR}/build.ninja" ]] || { echo "No configured build at ${BUILD_DIR} yet." >&2; exit 1; }
  OUT="${SOURCE_DIR}/build-graph"
  mkdir -p "$OUT"
  ninja -C "${BUILD_DIR}" -t graph > "${OUT}/graph.dot"
  ninja -C "${BUILD_DIR}" -t inputs "${TARGET}" 2>/dev/null | sort -u > "${OUT}/${TARGET}.inputs.txt" || true
  echo "==> Ninja graph : ${OUT}/graph.dot (render with: dot -Tsvg ${OUT}/graph.dot -o graph.svg)"
  echo "==> '${TARGET}' inputs: ${OUT}/${TARGET}.inputs.txt ($(wc -l < "${OUT}/${TARGET}.inputs.txt" 2>/dev/null) files)"
  echo "==> Inspect one file's edges with: ninja -C ${BUILD_DIR} -t query <file>"
  exit 0
fi

# --trace: configure with clang -ftime-trace so every TU emits a chrome-trace
# profile (build/*.json), then build and optionally run ClangBuildAnalyzer.
# Answers: which headers/TUs dominate compile time? (works with clang only)
if [[ "${TRACE:-0}" == "1" ]]; then
  rm -rf "${BUILD_DIR}-trace"
  cmake --preset "${PRESET}" -B "${BUILD_DIR}-trace" \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_CXX_FLAGS_DEBUG="-g1 -ftime-trace" \
    -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-g1 -O2 -ftime-trace" \
    -DCMAKE_C_FLAGS_DEBUG="-g1 -ftime-trace"
  cmake --build "${BUILD_DIR}-trace" --target "${TARGET}"
  echo "==> Per-TU chrome traces written under ${BUILD_DIR}-trace (**.json)."
  echo "==> Open one in chrome://tracing or https://ui.perfetto.dev"
  if command -v ClangBuildAnalyzer >/dev/null 2>&1; then
    echo "==> Running ClangBuildAnalyzer over the trace build..."
    ClangBuildAnalyzer --all "${BUILD_DIR}-trace" "${OUT:-/tmp}/cba.bin" >/dev/null 2>&1 || ClangBuildAnalyzer --all "${BUILD_DIR}-trace" /tmp/cba.bin
    ClangBuildAnalyzer --analyze /tmp/cba.bin | sed -n '1,80p'
  else
    echo "==> Install ClangBuildAnalyzer for an aggregate header/time report:"
    echo "    git clone --depth 1 https://github.com/aras-p/ClangBuildAnalyzer && cd ClangBuildAnalyzer && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build && cp build/ClangBuildAnalyzer /usr/local/bin"
  fi
  exit 0
fi

export NINJA_STATUS="[%f/%t %es] "
echo "==> Building target '${TARGET}' (preset '${PRESET}')..."
START=$SECONDS
if [[ "${PROFILE:-0}" == "1" ]]; then
  # ninja -d stats prints per-stage timing (scheduling, execution, edges).
  cmake --build "${BUILD_DIR}" --target "${TARGET}" -- -d stats 2>&1 | tee "${SOURCE_DIR}/build-ninja-stats.txt"
  echo "==> Ninja stats saved to build-ninja-stats.txt"
  echo "==> Slowest edges: ninja -C ${BUILD_DIR} -d \"speed\" | head"
else
  cmake --build "${BUILD_DIR}" --target "${TARGET}"
fi
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

echo "==> Tip: re-run './scripts/qgis-fastbuild.sh' after editing sources — most rebuilds take under two minutes."
echo "==> Tip: 'scripts/qgis-fastbuild.sh --doctor' audits your environment."
