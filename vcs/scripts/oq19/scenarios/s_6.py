"""6: a background I/O-bound job: synchronous writes, low CPU."""
from scenarios import lib

def job(ctx, seconds):
    end = int(seconds - lib.END_SLACK_S)
    lib.background(ctx, "(e=$((SECONDS+%d)); while [ $SECONDS -lt $e ]; do "
                        "dd if=/dev/zero of=/tmp/io.bin bs=1M count=64 oflag=dsync status=none; done)" % end)

ACTIONS = {"job": job}
