"""2a: vim open and untouched. IDLE."""
def SETUP(ctx):
    ctx.shell("vim /tmp/notes.txt")
    ctx.sleep(1.5)

ACTIONS = {}
