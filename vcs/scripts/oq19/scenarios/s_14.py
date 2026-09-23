"""14: explicit activity: keystrokes every 2 s into an idle TUI (vim)."""
def SETUP(ctx):
    ctx.shell("vim /tmp/notes.txt")
    ctx.sleep(1.5)

def typing(ctx, seconds):
    ctx.keys("i")  # insert mode
    end = seconds - 2.0
    elapsed = 0.0
    while elapsed < end:
        ctx.keys("x")
        ctx.sleep(2.0)
        elapsed += 2.0

ACTIONS = {"typing": typing}
