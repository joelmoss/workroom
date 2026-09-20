#!/bin/sh
# Item-5-style tick log, on the VM: wall clock, /proc/uptime and CLOCK_MONOTONIC every 10 s. A hibernate shows
# as a wall-clock gap; whether uptime and monotonic jump with it is a finding (the fork question).
#   ticks.sh <log>
log="$1"
while :; do
  echo "$(date +%s) $(cut -d' ' -f1 /proc/uptime) $(python3 -c 'import time; print(round(time.monotonic(), 3))')" >> "$log"
  sleep 10
done
