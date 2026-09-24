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
selfcall="$(dirname "$awake")/selfcall"   # touched around each hook: live.py masks the net signal meanwhile (F7)
asserted=0
# Terminated (the driver ends every run with SIGTERM) while asserting: release before exiting. The next shim
# starts at asserted=0 and never releases what it did not assert, so exiting while BUSY left boxd's idle timers
# at 0 with nothing left to restore them. The trap only RECORDS the signal and the loop acts on it between
# transitions, so no signal can land between a hook and the flag that says what the hook did. sh runs the trap
# once the current `sleep` or hook returns: at most one interval late, and driver.py waits (`os.wait4`).
stop=0
trap 'stop=1' TERM INT
while [ "$stop" = 0 ]; do
  mtime=$(stat -c %Y "$verdict" 2>/dev/null || stat -f %m "$verdict" 2>/dev/null || echo 0)
  if [ "$(cat "$verdict" 2>/dev/null)" = BUSY ] || awk -v now="$(date +%s)" -v m="$mtime" -v i="$interval" \
      'BEGIN { exit !(now - m > 2 * i) }'; then
    if [ "$asserted" = 0 ]; then
      touch "$selfcall"
      # A hook that fails part-way (boxd's sets two timers) may have changed one: undo it; the next tick retries.
      if sh -c "$assert"; then asserted=1; else sh -c "$release"; fi
      touch "$selfcall"
    fi
  elif [ "$asserted" = 1 ]; then
    touch "$selfcall"; sh -c "$release" && asserted=0; touch "$selfcall"  # a failed release retries next tick
  fi
  [ "$stop" = 0 ] && sleep "$interval"
done
if [ "$asserted" = 1 ]; then
  # The last chance: nothing runs after this shim to restore the provider's timers, so retry a failed release.
  touch "$selfcall"
  tries=1
  until sh -c "$release"; do
    [ "$tries" -ge 3 ] && { echo "wr-wakeshim: release failed $tries times; provider idle timers may be held" >&2; break; }
    tries=$((tries + 1))
    sleep 1
  done
  touch "$selfcall"
fi
exit 0
