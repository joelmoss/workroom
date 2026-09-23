"""3a: the synthetic agent at its prompt: alt screen, self-renamed process, blocked on the tty. IDLE."""
from scenarios import lib

def SETUP(ctx):
    lib.start_agent(ctx)

ACTIONS = {}
