#!/usr/bin/env bash
# ============================================================================
# scripts/bench-build.sh — build-system benchmark harness (QGIS-scale, synthetic)
#
# Measures, on a synthetic corpus that mimics QGIS compilation characteristics
# (600 translation units, Qt-like heavy headers, 3 libraries, unity batches,
# PCH), the exact levers used by scripts/qgis-fastbuild.sh:
#
#   A   cold, unity OFF, PCH OFF                      (baseline)
#   A2  cold, unity OFF, PCH OFF, full -g             (debug-info cost)
#   B   cold, unity ON                                (unity gain)
#   C   cold, unity ON, PCH ON                        (fast-preset analog)
#   D1  full rebuild in a DIFFERENT dir from ccache   (portability: hash_dir=false)
#   D2  same, but hash_dir=true (the default)         (shows the difference)
#   D3  same-dir object wipe + full rebuild           (the CI path: fixed dir)
#   G   ninja no-op on an unchanged tree
#   E   incremental: 1 TU edited, unity OFF
#   F   incremental: 1 TU edited, unity ON            (unity edit-time penalty)
#   H   link cost: 3 shared libs relinked (GNU ld)
#
# Usage:
#   scripts/bench-build.sh              # 600 TUs (a few minutes on 2-4 cores)
#   NTU=900 scripts/bench-build.sh      # bigger corpus
#
# Results land in build-bench/results.tsv and are printed as a table.
# This is a REAL benchmark: it compiles, caches, wipes, edits and relinks.
# ============================================================================
set -u

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${SOURCE_DIR}/build-bench"
ROOT="${WORK}/corpus"
NTU="${NTU:-600}"
command -v cmake >/dev/null 2>&1 || { echo "cmake not found" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "ninja not found (pip install ninja)" >&2; exit 1; }

# ccache is optional but strongly recommended for the D scenarios
if command -v ccache >/dev/null 2>&1; then
  ccache -M 2G >/dev/null
  ccache --set-config sloppiness=pch_defines,time_macros,include_file_mtime,include_file_ctime
  ccache --set-config compiler_check=content
  ccache --set-config inode_cache=true 2>/dev/null || true
fi

mkdir -p "$WORK"
OUT="$WORK/results.tsv"
: > "$OUT"

timed() { # timed <label> <cmd...>
  local label="$1"; shift
  local s e d
  s=$(date +%s.%N)
  if "$@" > /dev/null 2>&1; then
    e=$(date +%s.%N)
    d=$(python3 -c "print(f'{$e-$s:.1f}')" 2>/dev/null || echo "?")
  else
    d="FAIL"
  fi
  echo -e "$label\t$d" >> "$OUT"
  echo "### $label = ${d}s"
}

# ----------------------------------------------------------- corpus ---------
echo "==> Generating synthetic QGIS-scale corpus (${NTU} TUs) in $ROOT..."
mkdir -p "$ROOT"
python3 - "$ROOT" "$NTU" <<'PYEOF'
import os, random, sys
root, NTU = sys.argv[1], int(sys.argv[2])
random.seed(42)

def gen_header(path, tag, nclass):
    with open(path, "w") as f:
        f.write("#pragma once\n#include <string>\n#include <vector>\n#include <map>\n")
        f.write("namespace %s {\n" % tag)
        for c in range(nclass):
            f.write("class %s%d {\npublic:\n" % (tag.capitalize(), c))
            f.write("  std::string name_;\n  std::vector<int> data_;\n  std::map<std::string, std::vector<int>> idx_;\n")
            for m in range(12):
                f.write("  int method%d(int a, double b) const { return a + static_cast<int>(b) + %d + static_cast<int>(name_.size()); }\n" % (m, m + c))
            f.write("  double area() const { return 0.0; }\n  void scale(double f) { (void)f; }\n};\n")
        f.write("template <typename T> struct Box { T v; T get() const { return v; } void set(T x) { v = x; } };\n")
        for t in range(8):
            f.write("template <typename It> It algo%d(It first, It last) { It r = first; while (first != last) { r = first; ++first; } return r; }\n" % t)
        f.write("}\n")

for tag in ["geo", "render", "dat"]:
    gen_header(os.path.join(root, "heavy_%s.hpp" % tag), tag, 36)

TEMPLATE = '''#include "heavy_@H1@.hpp"
#include "heavy_@H2@.hpp"
#include <numeric>
namespace @LIB@ {
class Unit@CLS@ {
public:
  int compute(int seed) {
    int acc = seed;
@CALLS@
    return acc;
  }
  const char* name() const { return "@NAME@"; }
};
int entry_@PRE@@IDX@_fn(int seed) { Unit@CLS@ u; return u.compute(seed); }
}
'''
for lib, prefix in (("liba", "ga"), ("libb", "gb"), ("libc", "gc")):
    os.makedirs(os.path.join(root, lib), exist_ok=True)
    for i in range(NTU // 3):
        h1, h2 = random.sample(["geo", "render", "dat"], 2)
        cls = {"geo": "Geo", "render": "Render", "dat": "Dat"}[h1]
        calls = "\n".join(
            "    acc += %s::%s%d{}.method%d(acc, %d * 1.5);" % (h1, cls, random.randrange(36), random.randrange(12), i % 7)
            for _ in range(14))
        tu = (TEMPLATE.replace("@H1@", h1).replace("@H2@", h2).replace("@LIB@", lib)
              .replace("@NAME@", "%s%d" % (prefix, i))
              .replace("@CLS@", prefix.capitalize() + str(i))
              .replace("@CALLS@", calls)
              .replace("@PRE@", prefix).replace("@IDX@", str(i)))
        with open(os.path.join(root, lib, "unit_%s%d.cpp" % (prefix, i)), "w") as f:
            f.write(tu)

with open(os.path.join(root, "app.cpp"), "w") as f:
    f.write('#include "heavy_geo.hpp"\n#include "heavy_render.hpp"\n')
    f.write("namespace liba { int entry_ga0_fn(int); }\n")
    f.write("namespace libb { int entry_gb0_fn(int); }\n")
    f.write("namespace libc { int entry_gc0_fn(int); }\n")
    f.write("int main() { return liba::entry_ga0_fn(1) + libb::entry_gb0_fn(2) + libc::entry_gc0_fn(3) + render::Render0{}.method0(1, 2.0); }\n")

with open(os.path.join(root, "CMakeLists.txt"), "w") as f:
    f.write('''cmake_minimum_required(VERSION 3.21)
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
  set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE_PROGRAM})
endif()
project(benchqgis CXX)
set(CMAKE_CXX_STANDARD 17)
option(B_UNITY "unity builds" OFF)
option(B_PCH "precompiled headers" OFF)
option(B_SHARED "shared libs" OFF)
if(B_UNITY)
  set(CMAKE_UNITY_BUILD ON)
  set(CMAKE_UNITY_BUILD_BATCH_SIZE 8)
endif()
set(CMAKE_CXX_FLAGS_DEBUG "-g1" CACHE STRING "" FORCE)
set(LIBTYPE STATIC)
if(B_SHARED)
  set(LIBTYPE SHARED)
endif()
foreach(lib liba libb libc)
  file(GLOB SRCS ${lib}/*.cpp)
  add_library(${lib} ${LIBTYPE} ${SRCS})
  target_include_directories(${lib} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  if(B_PCH)
    target_precompile_headers(${lib} PRIVATE
      $<$<COMPILE_LANGUAGE:CXX>:${CMAKE_CURRENT_SOURCE_DIR}/heavy_geo.hpp>)
  endif()
endforeach()
add_executable(benchapp app.cpp)
target_include_directories(benchapp PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(benchapp PRIVATE liba libb libc)
''')
print("corpus ready:", NTU, "TUs")
PYEOF

ccache -C >/dev/null 2>&1 || true   # honest cold numbers
ccache -z >/dev/null 2>&1 || true

echo "==> A: cold, unity OFF, PCH OFF, -g1"
cmake -S "$ROOT" -B "$WORK/bA" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DB_UNITY=OFF -DB_PCH=OFF >/dev/null
timed "A_cold_unity_off_pch_off_g1" cmake --build "$WORK/bA" -j

echo "==> A2: cold, same but full -g (debug info cost)"
sed 's/"-g1"/"-g"/' "$ROOT/CMakeLists.txt" > "$ROOT/CMakeLists.txt.bak"
cp "$ROOT/CMakeLists.txt.bak" "$ROOT/CMakeLists.txt" 2>/dev/null || true
sed -i 's/"-g1"/"-g"/' "$ROOT/CMakeLists.txt"
cmake -S "$ROOT" -B "$WORK/bA2" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DB_UNITY=OFF -DB_PCH=OFF >/dev/null
timed "A2_cold_unity_off_full_g" cmake --build "$WORK/bA2" -j
sed -i 's/"-g"/"-g1"/' "$ROOT/CMakeLists.txt"

echo "==> B: cold, unity ON, PCH OFF"
cmake -S "$ROOT" -B "$WORK/bB" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DB_UNITY=ON -DB_PCH=OFF >/dev/null
timed "B_cold_unity_on_g1" cmake --build "$WORK/bB" -j

echo "==> C: cold, unity ON, PCH ON (fast-preset analog)"
cmake -S "$ROOT" -B "$WORK/bC" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DB_UNITY=ON -DB_PCH=ON >/dev/null
timed "C_cold_unity_pch_g1" cmake --build "$WORK/bC" -j

echo "==> D1: full rebuild in a DIFFERENT dir from ccache (hash_dir=false)"
ccache --set-config hash_dir=false
cmake -S "$ROOT" -B "$WORK/bD" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DB_UNITY=ON -DB_PCH=ON >/dev/null
ccache -z >/dev/null
timed "D1_warm_full_diffdir_ccache" cmake --build "$WORK/bD" -j
ccache -s 2>/dev/null | grep -A3 "Cacheable calls" | grep "Hits:" | head -1 | sed 's/^/    /' | tee -a "$OUT.d1rate" || true

echo "==> D2: same but hash_dir=true (default)"
ccache --set-config hash_dir=true
cmake -S "$ROOT" -B "$WORK/bD2" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DB_UNITY=ON -DB_PCH=ON >/dev/null
ccache -z >/dev/null
timed "D2_warm_full_diffdir_hashdir_true" cmake --build "$WORK/bD2" -j
ccache -s 2>/dev/null | grep -A3 "Cacheable calls" | grep "Hits:" | head -1 | sed 's/^/    /' | tee -a "$OUT.d2rate" || true
ccache --set-config hash_dir=false

echo "==> D3: same-dir object wipe + full rebuild from ccache (CI path, fixed build dir)"
find "$WORK/bC" -name '*.o' -delete 2>/dev/null
ccache -z >/dev/null
timed "D3_warm_full_samedir_ccache" cmake --build "$WORK/bC" -j
ccache -s 2>/dev/null | grep -A3 "Cacheable calls" | grep "Hits:" | head -1 | sed 's/^/    /' | tee -a "$OUT.d3rate" || true

echo "==> G: ninja no-op"
timed "G_ninja_noop" cmake --build "$WORK/bC" -j

echo "==> E: incremental, 1 TU edited, unity OFF"
RUN_ID="r$$"
echo "namespace liba { int extra_fn_${RUN_ID}(int x) { return x * 3 + 1; } }" >> "$ROOT/liba/unit_ga5.cpp"
timed "E_incr_1file_no_unity" cmake --build "$WORK/bC" -j

echo "==> F: incremental, 1 TU edited, unity ON"
echo "namespace liba { int extra_fn_${RUN_ID}b(int x) { return x * 5 + 2; } }" >> "$ROOT/liba/unit_ga7.cpp"
timed "F_incr_1file_unity" cmake --build "$WORK/bB" -j

echo "==> H: link cost, 3 shared libs + exe (GNU ld)"
cmake -S "$ROOT" -B "$WORK/bH" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DB_UNITY=ON -DB_PCH=ON -DB_SHARED=ON >/dev/null
timed "H_build_sharedlibs" cmake --build "$WORK/bH" -j
touch "$ROOT/app.cpp"
timed "H_relink_3_sharedlibs_gnuld" cmake --build "$WORK/bH" -j --target benchapp

# ----------------------------------------------------------- report ---------
{
  echo
  echo "=========================== BENCHMARK RESULTS ==========================="
  column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
  for r in d1rate d2rate d3rate; do
    [[ -s "$OUT.$r" ]] && { echo; echo "ccache $r:"; cat "$OUT.$r"; }
  done
  echo
  echo "Scaling note: QGIS has ~2600 much heavier TUs; use these numbers as"
  echo "lever RATIOS (unity, PCH, ccache, incremental), not absolute QGIS times."
} | tee "$WORK/REPORT.txt"
echo
echo "Full report: $WORK/REPORT.txt"
