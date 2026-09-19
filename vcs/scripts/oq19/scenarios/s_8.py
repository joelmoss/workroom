"""8: a detached server, listening, no CPU, no traffic. IDLE by the owner's decision."""
from scenarios import lib

def SETUP(ctx):
    lib.background(ctx, "python3 -m http.server 8000 >/dev/null 2>&1")
    ctx.sleep(1.0)

ACTIONS = {}
