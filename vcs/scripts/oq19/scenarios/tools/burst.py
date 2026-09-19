#!/usr/bin/env python3
"""A bursty job (scenario 12): burn CPU for `--burn` seconds every `--period` seconds, for `--seconds`."""

import argparse
import time

ap = argparse.ArgumentParser()
ap.add_argument("--seconds", type=float, required=True)
ap.add_argument("--burn", type=float, default=5)
ap.add_argument("--period", type=float, default=60)
a = ap.parse_args()
end = time.monotonic() + a.seconds
while time.monotonic() < end:
    stop = min(time.monotonic() + a.burn, end)
    while time.monotonic() < stop:
        pass
    time.sleep(max(0.0, min(a.period - a.burn, end - time.monotonic())))
