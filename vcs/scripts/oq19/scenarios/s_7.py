"""7: a sleepy job: alive for the whole phase, no CPU, no I/O, nanosleep."""
from scenarios import lib

def sleep_job(ctx, seconds):
    lib.background(ctx, "(sleep %.2f; echo done)" % (seconds - lib.END_SLACK_S))

ACTIONS = {"sleep": sleep_job}
