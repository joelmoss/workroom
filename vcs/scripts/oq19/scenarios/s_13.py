"""13: `watch -n1 date`: a human is looking. REPORTED, not gated."""
def SETUP(ctx):
    ctx.shell("watch -n1 date")
    ctx.sleep(1.5)

ACTIONS = {}
