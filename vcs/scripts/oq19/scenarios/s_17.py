"""17: legitimate work that outlasts any proposed awake ceiling (OQ22): a low-duty CPU job for the whole
phase. REPORTED: what each ceiling semantics would do to it."""
from scenarios import lib

def work(ctx, seconds):
    lib.burn(ctx, seconds, procs=1, duty=0.3)

ACTIONS = {"work": work}
