#!/usr/bin/env python3
"""Builds the golden traces (plan decision D2): a few hold-out runs, copied with their inputs (trace, pty,
lifecycle, truth) and the EXPECTED verdict change-points from `analyze.verdict_series` at the frozen
configuration, which `analyze.py holdout` showed equal to the live classifier's on every run. The Rust
wakefulness service replays these and must produce the same change-points (`tests/test_golden.py` is the
Python side of that contract).

  golden/build.py [--root traces/holdout] [--frozen results/frozen.json] <run-key>...
"""
import argparse
import gzip
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import analyze  # noqa: E402
import gates  # noqa: E402


def expected(run, frozen):
    c = analyze.Config(**frozen["config"])
    return analyze.verdict_series(analyze.effective(c, run), run.feats(c.interval, c.exclusions),
                                  analyze.window_for(c, run))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("keys", nargs="+")
    ap.add_argument("--root", default=os.path.join(HERE, "..", "traces", "holdout"))
    ap.add_argument("--frozen", default=os.path.join(HERE, "..", "results", "frozen.json"))
    args = ap.parse_args()
    with open(args.frozen) as f:
        frozen = json.load(f)
    for key in args.keys:
        src = os.path.join(args.root, "runs", key)
        dst = os.path.join(HERE, key)
        os.makedirs(dst, exist_ok=True)
        with open(os.path.join(src, "trace.jsonl"), "rb") as fi, \
                gzip.open(os.path.join(dst, "trace.jsonl.gz"), "wb") as fo:
            shutil.copyfileobj(fi, fo)
        for name in ("pty.jsonl", "lifecycle.jsonl", "truth.jsonl", "meta.json"):
            shutil.copy(os.path.join(src, name), os.path.join(dst, name))
        run = analyze.Run.load(src, key)
        v = expected(run, frozen)
        c = analyze.Config(**frozen["config"])
        res = gates.evaluate(v, run.intervals(), c.interval, analyze.window_for(c, run),
                             d3_fallback=frozen.get("d3_fallback", False) and run.scenario == "3b")
        with open(os.path.join(dst, "expected.jsonl"), "w") as f:
            f.write("".join(json.dumps({"t": t, "verdict": x}) + "\n" for t, x in v))
        with open(os.path.join(dst, "gates.json"), "w") as f:
            json.dump({g: s for g, (s, _) in res.items()}, f, indent=1)
        print(key, len(v), "change-points;", {g: s for g, (s, _) in res.items()})


if __name__ == "__main__":
    main()
