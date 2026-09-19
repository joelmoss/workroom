"""11: an agent-owned command with no pty (git fetch-shaped: alive, mostly waiting). Its start and end are
logged as lifecycle events (S9): scored through the exec lifecycle, not by kernel heuristics."""
import subprocess

from scenarios import lib

def run_exec(ctx, seconds):
    with ctx.lifecycle_span("exec"):
        p = subprocess.Popen(["sleep", "%.2f" % (seconds - lib.END_SLACK_S)])
        ctx.spawned.append(p)
        p.wait()

ACTIONS = {"exec": run_exec}
