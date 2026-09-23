"""3b: as 3a, plus an idle keepalive TCP connection to the peer (adversarial for the network signals). IDLE
(exempt from no-busy-forever only if the D3 fallback fires)."""
from scenarios import lib

def SETUP(ctx):
    lib.start_agent(ctx, keepalive=True)

ACTIONS = {}
