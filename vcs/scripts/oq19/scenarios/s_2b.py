"""2b: less open and untouched. IDLE."""
def SETUP(ctx):
    ctx.shell("seq 1 100000 > /tmp/big.txt; less /tmp/big.txt")
    ctx.sleep(1.5)

ACTIONS = {}
