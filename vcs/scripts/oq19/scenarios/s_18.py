"""18: work that starts while the sampler is blind. The sampler is SIGSTOPped 5 s before the work starts and
resumed 10 s into it (a 15 s gap); the driver emits a STALE truth interval for the gap (D10). Times shrink
with --scale for pipeline checks; a scored run (scale 1.0) uses 5 s and 15 s."""
import signal
import time

from scenarios import lib

_gap = {}

def _factor(ctx):
    return min(1.0, ctx.scale * 10)

def quiet(ctx, seconds):
    lead = 5.0 * _factor(ctx)
    ctx.sleep(seconds - lead)
    _gap["start"] = time.monotonic()
    ctx.sampler.send_signal(signal.SIGSTOP)

def work(ctx, seconds):
    lib.burn(ctx, seconds, procs=1, duty=1.0)
    ctx.sleep(10.0 * _factor(ctx))
    ctx.sampler.send_signal(signal.SIGCONT)
    ctx.extra_truth.append({"scenario": "18", "phase": "gap", "label": "STALE",
                            "start": _gap["start"], "end": time.monotonic()})

ACTIONS = {"quiet": quiet, "work": work}
