#!/usr/bin/env python3
"""Ninja build-log analyzer for the QGIS build-performance work.

Two modes:
- --mode parallel (default): parse a .ninja_log file (tab-separated
  start_ms end_ms mtime restat cmdhash). Reports busy core-ms vs wall-ms
  (real parallelism efficiency), edge duration distribution, top-N edges
  (unnamed: .ninja_log only stores hashes).
- --mode serial-v: parse a timestamped `ninja -v` output captured during a
  serial (-j1) build. With one job in flight, the delay between the command
  line and the next line IS the duration of that command — exact attribution
  with full command names. This is how the top-N slowest compilation units
  are identified.

Reports are written as JSON and markdown; a --selftest mode validates the
parsers against synthetic data (run in CI and locally before every use).
"""

import argparse
import json
import re
import statistics
import sys
from pathlib import Path


def parse_ninja_log(path: Path):
    """Return list of (start_ms, end_ms) from a .ninja_log file."""
    edges = []
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        try:
            start, end = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if end >= start:
            edges.append((start, end))
    return edges


def parse_serial_v(path: Path):
    """Parse a timestamped `ninja -v` capture from a serial build.

    Lines are "<epoch_ms> <text>". Command lines (starting with a tool path
    after the timestamp) accumulate durations until the next command line;
    ninja bookkeeping lines (like [k/n]) don't reset anything.
    Returns list of (duration_ms, command).
    """
    durations = []
    cur_cmd, cur_start = None, None
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"^(\d{10,})\s(.*)$", line)
        if not m:
            continue
        ts, text = int(m.group(1)), m.group(2)
        is_cmd = bool(
            re.match(r'^("[^"]+"|[A-Za-z0-9_/.+-]+)\s', text)
        ) and not re.match(r"^\[\d+/\d+\]", text)
        if is_cmd:
            if cur_cmd is not None and cur_start is not None:
                durations.append((ts - cur_start, cur_cmd))
            cur_cmd, cur_start = text, ts
        # non-command lines: keep accumulating (serial build)
    if cur_cmd is not None and cur_start is not None:
        durations.append((0, cur_cmd))  # last command: duration unknown (0)
    return durations


def categorize(cmd: str) -> str:
    if "sip" in cmd or "_sip" in cmd:
        return "sip-bindings"
    if re.search(r"\bld\b|LINK_FILE|link.txt", cmd):
        return "link"
    if (
        "clang++" in cmd
        or "g++" in cmd
        or "cxx" in cmd.lower()
        or ".cc.o" in cmd
        or ".cpp.o" in cmd
    ):
        return "compile"
    if "rcc" in cmd or "uic" in cmd or "qmlcache" in cmd or "qmlcachegen" in cmd:
        return "qt-resource-generation"
    if "lrelease" in cmd or ".qm" in cmd:
        return "i18n"
    if "cmake" in cmd or "configure" in cmd:
        return "cmake"
    return "other"


def summarize(durations, wall_ms=None, top_n=20):
    if not durations:
        return {}
    ends = None
    durations_sorted = sorted(durations, key=lambda d: d[0], reverse=True)
    values = [d[0] for d in durations]
    total_busy = sum(values)
    max_edge = max(values)
    q = statistics.quantiles(values, n=100) if len(values) >= 2 else [max_edge]
    res = {
        "edges": len(values),
        "busy_ms": total_busy,
        "wall_ms": wall_ms,
        "efficiency": round(total_busy / wall_ms, 2) if wall_ms else None,
        "min_cores_needed": round(total_busy / max(wall_ms, 1), 2) if wall_ms else None,
        "p50_ms": q[49] if len(values) >= 2 else max_edge,
        "p90_ms": q[89] if len(values) >= 2 else max_edge,
        "p99_ms": q[98] if len(values) >= 2 else max_edge,
        "max_ms": max_edge,
        "top": [
            {"ms": d, "phase": categorize(c), "cmd": c[:160]}
            for d, c in durations_sorted[:top_n]
        ],
        "phases": {},
    }
    for _, c in durations_sorted:
        p = categorize(c)
        res["phases"].setdefault(p, {"count": 0, "busy_ms": 0})
        res["phases"][p]["count"] += 1
    # busy per phase over ALL edges
    for d, c in durations:
        p = categorize(c)
        res["phases"][p]["busy_ms"] += d
    return res


def selftest() -> int:
    tmp = Path("/tmp/ninja-selftest")
    tmp.mkdir(exist_ok=True)
    # parallel log: 4 edges on 2 lanes overlapping: busy 100+200+300+400=1000, wall 500
    log = tmp / ".ninja_log"
    log.write_text(
        "# ninja log v5\n"
        "0\t100\t0\tdead\tbeef\n"
        "0\t200\t0\tdead\tbeef\n"
        "100\t400\t0\tdead\tbeef\n"
        "200\t500\t0\tdead\tbeef\n"
    )
    edges = parse_ninja_log(log)
    assert len(edges) == 4, len(edges)
    s = summarize([(e - st, "g++ x.cpp.o") for st, e in edges], wall_ms=500)
    assert s["busy_ms"] == 900, s["busy_ms"]  # 100+200+300+300
    assert s["wall_ms"] == 500
    assert abs(s["efficiency"] - 1.8) < 1e-9, s["efficiency"]
    assert abs(s["min_cores_needed"] - 1.8) < 1e-9
    assert s["max_ms"] == 300
    # serial log: cmd1 10->150 (140ms), cmd2 150->400 (250ms), trailing cmd
    sv = tmp / "serial.log"
    sv.write_text(
        "1700000000000 g++ -c a.cpp -o a.o\n"
        "1700000000010 [1/3] not a command line pattern\n"
        "1700000000150 g++ -c b.cpp -o b.o\n"
        "1700000000400 cc -c c.cpp -o c.o\n"
    )
    durs = parse_serial_v(sv)
    assert len(durs) == 3, durs
    assert durs[0][0] == 150, durs[0]  # ninja status line does not reset the command
    assert durs[1][0] == 250, durs[1]
    durs = durs[:2]
    s2 = summarize(durs, wall_ms=400)
    assert s2["busy_ms"] == 400
    assert s2["top"][0]["cmd"].startswith("g++ -c b.cpp")
    print("selftest OK: parallel+serial parsers verified")
    return 0


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["parallel", "serial-v"], default="parallel")
    ap.add_argument(
        "--log", help=".ninja_log (parallel) or timestamped -v capture (serial-v)"
    )
    ap.add_argument(
        "--wall-ms", type=int, default=None, help="measured wall time of the build"
    )
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--markdown", dest="md_out")
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if not args.log:
        print("error: --log required (or --selftest)", file=sys.stderr)
        return 2

    if args.mode == "parallel":
        edges = parse_ninja_log(Path(args.log))
        durations = [(e - st, "") for st, e in edges]
    else:
        durations = parse_serial_v(Path(args.log))

    s = summarize(durations, wall_ms=args.wall_ms, top_n=args.top)
    payload = {"mode": args.mode, **s}
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(payload, indent=2))
    if args.md_out:
        with open(args.md_out, "w") as f:
            f.write(f"### Ninja profile ({args.mode})\n\n")
            f.write(f"| Metric | Value |\n|---|---|\n")
            f.write(f"| Edges | {s.get('edges', 0)} |\n")
            f.write(f"| Busy (core-ms) | {s.get('busy_ms', 0):,} |\n")
            if s.get("wall_ms"):
                f.write(f"| Wall (ms) | {s['wall_ms']:,} |\n")
                f.write(f"| Parallel efficiency (busy/wall) | {s['efficiency']} |\n")
                f.write(f"| Cores actually exploitable | {s['min_cores_needed']} |\n")
                f.write(
                    f"| Wall floor at 4 vCPU (s) | {s['busy_ms'] / 4 / 1000:.0f} |\n"
                )
                f.write(
                    f"| Wall floor at 16 vCPU (s) | {s['busy_ms'] / 16 / 1000:.0f} |\n"
                )
            f.write(f"| Edge p50 (ms) | {s.get('p50_ms', 0)} |\n")
            f.write(f"| Edge p90 (ms) | {s.get('p90_ms', 0)} |\n")
            f.write(f"| Slowest edge (ms) | {s.get('max_ms', 0)} |\n")
            f.write("\nPhases:\n\n| Phase | Count | Busy (s) |\n|---|---|---|\n")
            for p, v in sorted(
                s.get("phases", {}).items(), key=lambda kv: -kv[1]["busy_ms"]
            ):
                f.write(f"| {p} | {v['count']} | {v['busy_ms'] / 1000:.1f} |\n")
            f.write("\nTop slowest edges:\n\n")
            for i, t in enumerate(s.get("top", []), 1):
                name = t["cmd"] if t["cmd"] else "(hash-only)"
                f.write(f"{i}. {t['ms']} ms [{t['phase']}] `{name}`\n")
    print(json.dumps({k: v for k, v in payload.items() if k != "top"}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
