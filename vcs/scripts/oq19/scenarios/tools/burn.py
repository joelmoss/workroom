#!/usr/bin/env python3
"""CPU load with a duty cycle. `--procs N --seconds S --duty D`: N child processes, each burning D of every
100 ms and sleeping the rest, for S seconds, then exiting (a build that ends). duty 1.0 is a saturating build;
500 procs at duty 0.01 is the 500-process build shape for the sampler-cost check, bounded CPU."""

import argparse
import os
import time

ap = argparse.ArgumentParser()
ap.add_argument("--procs", type=int, default=1)
ap.add_argument("--seconds", type=float, required=True)
ap.add_argument("--duty", type=float, default=1.0)
a = ap.parse_args()


def child():
    end = time.monotonic() + a.seconds
    while time.monotonic() < end:
        burn_until = time.monotonic() + 0.1 * a.duty
        while time.monotonic() < burn_until:
            pass
        rest = 0.1 * (1 - a.duty)
        if rest > 0:
            time.sleep(rest)


pids = []
for _ in range(a.procs):
    pid = os.fork()
    if pid == 0:
        child()
        os._exit(0)
    pids.append(pid)
for pid in pids:
    os.waitpid(pid, 0)
