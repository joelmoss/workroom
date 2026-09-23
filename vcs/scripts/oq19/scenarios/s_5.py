"""5: a background CPU build with the shell back at its prompt. The 500-process variant (OQ19_VARIANT=500proc,
for the sampler-cost check) uses 500 low-duty processes."""
from scenarios import lib

def build(ctx, seconds):
    if ctx.variant == "500proc":
        lib.burn(ctx, seconds, procs=500, duty=0.01)
    else:
        lib.burn(ctx, seconds, procs=8, duty=1.0)

ACTIONS = {"build": build}
