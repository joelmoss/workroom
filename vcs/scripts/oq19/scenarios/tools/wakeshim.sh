#!/bin/sh
# The lifecycle shim, shaped like the Phase 0 item-5 loop: poll the classifier's verdict, and while it is BUSY
# assert "awake" (here: touch a file; on a real box, the provider call). It runs as `wr-wakeshim` (a symlink to
# sh), the name boundary.md puts on the exclusion list, so its own forks (`cat`, `sleep`, `touch`) are attributed
# to the classifier and never to the workroom. Its CPU is measured: it is part of the 0.5% budget.
#
#   wr-wakeshim wakeshim.sh <interval-seconds> <verdict-file>
interval="${1:-1}"
verdict="${2:-/out/verdict}"
mkdir -p /run/oq19
while :; do
  [ "$(cat "$verdict" 2>/dev/null)" = BUSY ] && touch /run/oq19/awake
  sleep "$interval"
done
