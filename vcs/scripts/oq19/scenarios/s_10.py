"""10: a setsid'd CPU job that outlives its shell: the shell exits right after starting it, so the job is in
no session or process-group tree the agent created."""
from scenarios import lib

def job(ctx, seconds):
    ctx.shell("setsid python3 %s/burn.py --procs 1 --seconds %.2f </dev/null >/dev/null 2>&1 & exit"
              % (ctx.tools, seconds - lib.END_SLACK_S))

ACTIONS = {"job": job}
