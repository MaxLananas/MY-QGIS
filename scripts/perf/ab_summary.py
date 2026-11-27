#!/usr/bin/env python3
"""Build the A/B delta markdown table for the perf-bench workflow summary.

Usage: ab_summary.py <fork.json> <reference.json>
Reads the JSON outputs of qgis-perf-bench.py and prints a markdown table of
fork-vs-reference deltas (medians). Never raises on missing files: the CI
summary step runs under `if: always()` and must stay informative.
"""

import json
import os
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: ab_summary.py <fork.json> <reference.json>", file=sys.stderr)
        return 2
    fork_path, ref_path = argv[1], argv[2]

    if not os.path.exists(fork_path):
        print("Fork benchmark did not complete — check the build+run logs.")
        return 0
    if not os.path.exists(ref_path):
        print("(Upstream reference run missing — no comparison available.)")
        return 0

    with open(fork_path) as fh:
        fork_rows = {row["name"]: row for row in json.load(fh)["rows"]}
    with open(ref_path) as fh:
        ref_rows = {row["name"]: row for row in json.load(fh)["rows"]}

    print("| Metric | Reference (s) | Fork (s) | Delta (median) |")
    print("|---|---|---|---|")
    for name in ref_rows:
        ref = ref_rows[name]
        fork = fork_rows.get(name)
        if not fork or not ref.get("median_s") or not fork.get("median_s"):
            print(f"| {name} | {ref.get('median_s', '—')} | — | — |")
            continue
        delta = (fork["median_s"] - ref["median_s"]) / ref["median_s"] * 100.0
        print(
            f"| {name} | {ref['median_s']:.4f} | {fork['median_s']:.4f} | {delta:+.1f}% |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
