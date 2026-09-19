"""9: the same server, hit every 2 s from OUTSIDE (the peer container), so the requests cross eth0."""
from scenarios import lib

def SETUP(ctx):
    lib.background(ctx, "python3 -m http.server 8000 >/dev/null 2>&1")
    ctx.sleep(1.0)

def traffic(ctx, seconds):
    ctx.peer_send("HIT box 8000 2 %.1f" % (seconds - lib.END_SLACK_S))

ACTIONS = {"traffic": traffic}
