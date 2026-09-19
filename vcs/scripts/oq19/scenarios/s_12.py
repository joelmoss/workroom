"""12: a bursty job, 5 s of CPU every 60 s. REPORTED as a trade-off curve, not gated."""
from scenarios import lib

def bursts(ctx, seconds):
    lib.background(ctx, "python3 %s/burst.py --seconds %.2f --burn 5 --period 60" % (ctx.tools, seconds))

ACTIONS = {"bursts": bursts}
