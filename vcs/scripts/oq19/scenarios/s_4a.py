"""4a: an agent turn with a visible spinner (10 Hz redraws) while it waits on the peer, then streaming."""
from scenarios import lib

def SETUP(ctx):
    lib.start_agent(ctx)

ACTIONS = {"turn": lambda ctx, seconds: lib.agent_turn(ctx, "a", seconds)}
