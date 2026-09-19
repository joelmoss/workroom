#!/usr/bin/env python3
"""Sampler cost (gate: <= 0.5% of one core, `ss` children included) at each sampling interval, on an idle box
and under process load. Run by `run.sh cost`, inside the image. Load is N sleeping processes (the 500-process
case is the scenario-5 build's process count)."""

import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
DURATION = 20


def measure(interval, load, signals):
    sleepers = [subprocess.Popen(["sleep", "3600"]) for _ in range(load)]
    trace = os.path.join(OUT, "cost_%s_%s_%s.jsonl" % (interval, load, signals.replace(",", "+")))
    subprocess.run([sys.executable, os.path.join(HERE, "sampler.py"), "--out", trace, "--interval", str(interval),
                    "--duration", str(DURATION), "--signals", signals], check=True)
    for s in sleepers:
        s.kill()
        s.wait()
    with open(trace) as f:
        footer = [json.loads(line) for line in f if '"type": "footer"' in line][0]
    return footer


SETS = ("box", "box,procs", "box,sockets", "box,procs,sockets")
print("Steady-state sampler cost (interpreter startup and the first tick excluded; `ss` children included).")
print("%-18s %8s %5s  %12s  %7s  %7s  %10s" % ("signals", "interval", "load", "cpu%% of 1core", "samples", "overran", "max_late_s"))
for signals in SETS:
    for load in (0, 500):
        for interval in (1, 5):
            f = measure(interval, load, signals)
            print("%-18s %8s %5d  %12.3f  %7d  %7d  %10.3f" % (
                signals, interval, load, 100 * f["cpu_fraction_steady"], f["samples"], f["overran_ticks"],
                f["max_late_s"]))
            sys.stdout.flush()
