#!/bin/sh
# The lifecycle shim, shaped like the Phase 0 item-5 loop: poll the classifier's verdict, and while it is BUSY
# assert "awake" (here: touch a file; on a real box, the provider call). It runs as `wr-wakeshim` (a symlink to
# sh), the name boundary.md puts on the exclusion list, so its own forks (`cat`, `sleep`, `touch`) are attributed
# to the classifier and never to the workroom. Its CPU is measured: it is part of the 0.5% budget.
#
# The staleness rule (D10) lives HERE, on the consumer side: a verdict file older than 2 sampling intervals
# means BUSY until a fresh one arrives. A stopped or starved classifier cannot say anything, so the reader
# has to assume work. Scenario 18's hold-out runs showed the classifier alone cannot implement it.
#
#   wr-wakeshim wakeshim.sh <interval-seconds> <verdict-file> [awake-file]
interval="${1:-1}"
verdict="${2:-/out/verdict}"
awake="${3:-/run/oq19/awake}"
mkdir -p "$(dirname "$awake")"
while :; do
  mtime=$(stat -c %Y "$verdict" 2>/dev/null || stat -f %m "$verdict" 2>/dev/null || echo 0)
  if [ "$(cat "$verdict" 2>/dev/null)" = BUSY ] || awk -v now="$(date +%s)" -v m="$mtime" -v i="$interval" \
      'BEGIN { exit !(now - m >= 2 * i) }'; then
    touch "$awake"
  fi
  sleep "$interval"
done
