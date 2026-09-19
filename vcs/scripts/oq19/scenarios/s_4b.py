"""4b: an agent turn with NO pty output while it waits on the peer: blocked in the kernel, no CPU, nothing on
the screen. The hardest case: on CPU and output alone it is an idle agent."""
from scenarios import lib

def SETUP(ctx):
    lib.start_agent(ctx)

ACTIONS = {"turn": lambda ctx, seconds: lib.agent_turn(ctx, "b", seconds)}
