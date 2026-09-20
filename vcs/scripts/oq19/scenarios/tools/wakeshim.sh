#!/bin/sh
# The lifecycle shim, shaped like the Phase 0 item-5 loop: poll the classifier's verdict, and while it is BUSY
# assert "awake". It runs as `wr-wakeshim` (a symlink to sh), the name boundary.md puts on the exclusion list,
# so its own forks (`cat`, `sleep`, `stat`, `awk`) are attributed to the classifier and never to the workroom.
# Its CPU is measured: it is part of the 0.5% budget.
#
# The staleness rule (D10) lives HERE, on the consumer side: a verdict file older than 2 sampling intervals
# means BUSY until a fresh one arrives (mtime is read at 1 s resolution, so the comparison is strict: a file
# 2.x s old reads as 2 and is not yet stale, one 3.x s old is; never a false alarm on a fresh file). A stopped
# or starved classifier cannot say anything, so the reader has to assume work. Scenario 18's hold-out runs
# showed the classifier alone cannot implement it.
#
# What "assert" does is the provider's business: by default it touches a file (the container harness measures
# the verdicts, not the provider). On boxd, OQ19_ASSERT and OQ19_RELEASE are the in-VM CLI calls that set the
# machine's idle timers to 0 and back (item 5's lever); each runs ONCE per transition, not once per tick.
#
#   wr-wakeshim wakeshim.sh <interval-seconds> <verdict-file> [awake-file]
interval="${1:-1}"
verdict="${2:-/out/verdict}"
awake="${3:-/run/oq19/awake}"
assert="${OQ19_ASSERT:-touch \"$awake\"}"
release="${OQ19_RELEASE:-rm -f \"$awake\"}"
mkdir -p "$(dirname "$awake")"
asserted=0
while :; do
  mtime=$(stat -c %Y "$verdict" 2>/dev/null || stat -f %m "$verdict" 2>/dev/null || echo 0)
  if [ "$(cat "$verdict" 2>/dev/null)" = BUSY ] || awk -v now="$(date +%s)" -v m="$mtime" -v i="$interval" \
      'BEGIN { exit !(now - m > 2 * i) }'; then
    if [ "$asserted" = 0 ]; then sh -c "$assert" && asserted=1; fi
  elif [ "$asserted" = 1 ]; then
    sh -c "$release" && asserted=0
  fi
  sleep "$interval"
done
