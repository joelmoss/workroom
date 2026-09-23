"""2c: tmux with its default status clock (status-interval 15 s: it writes to the pty while idle). IDLE."""
def SETUP(ctx):
    ctx.shell("tmux new-session -s oq")
    ctx.sleep(1.5)

ACTIONS = {}
