#!/bin/sh
# On the FORK: does CLOCK_MONOTONIC advance at wall-clock rate on a derived machine? 60 s of paired readings.
#   clockcheck.sh <log>
log="$1"
i=0
while [ $i -lt 7 ]; do
  echo "$(date +%s.%N) $(cut -d' ' -f1 /proc/uptime) $(python3 -c 'import time; print(round(time.monotonic(), 3))')" >> "$log"
  i=$((i + 1))
  [ $i -lt 7 ] && sleep 10
done
