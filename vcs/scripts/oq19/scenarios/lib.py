"""Helpers shared by the scenario modules. A module defines `ACTIONS = {phase: fn(ctx, seconds)}` for the
phases that need work, and optionally `SETUP(ctx)` (run once, after the sampler starts, before the first phase).
Work must END with its phase: the label is only true for as long as the thing is running, so every job here
takes its duration from `seconds`, never a constant."""

END_SLACK_S = 0.2  # a job ends this long before its phase does (typing a command takes a moment)


def start_agent(ctx, keepalive=False):
    ctx.shell("python3 %s/agent.py%s%s" % (ctx.tools, " --peer %s" % ctx.peer if ctx.peer else "",
                                         " --keepalive" if keepalive else ""))
    ctx.sleep(2.0)  # let curses take the screen


def agent_turn(ctx, mode, seconds):
    """Start a turn that lasts `seconds`: silent (b) or with a spinner (a), waiting on the peer then streaming."""
    stream = min(30.0, 0.15 * seconds)
    wait = max(0.0, seconds - stream - END_SLACK_S)
    ctx.keys("go %s %.2f %.2f\n" % (mode, wait, stream))


def background(ctx, command):
    """Run `command` in the background of the pty shell, as `make -j &` would be."""
    ctx.shell("%s &" % command)


def burn(ctx, seconds, procs=8, duty=1.0):
    background(ctx, "python3 %s/burn.py --procs %d --seconds %.2f --duty %.3f" %
               (ctx.tools, procs, seconds - END_SLACK_S, duty))
