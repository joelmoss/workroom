#!/bin/bash
#
# Two behaviour checks for a workroomd change, to run beside daemon-idle-bench.sh:
#   1. a shell that types `exit` ends its session at once (a reader that sleeps between reads can
#      miss the hang-up), on the NEW binary;
#   2. a hand-off from the OLD binary to the NEW one keeps every session on the same pid, and the
#      daemon's context switches per 10 s are printed before and after, so the saving is seen on a
#      daemon that was started by the old build.
# macOS only (`top -d`).
#
#   daemon-handoff-check.sh <old workroomd binary> <new workroomd binary>
set -u

old="${1:?usage: daemon-handoff-check.sh <old workroomd binary> <new workroomd binary>}"
new="${2:?usage: daemon-handoff-check.sh <old workroomd binary> <new workroomd binary>}"
new="$(cd "$(dirname "$new")" && pwd)/$(basename "$new")"  # hand-off wants an absolute path

work="$(mktemp -d /tmp/wrcheck.XXXXXX)"
pids=()
daemon=
cleanup() {
  disown -a 2>/dev/null  # no "Terminated" line per job we kill
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  [ -n "$daemon" ] && kill "$daemon" 2>/dev/null
  sleep 1
  rm -rf "$work"
}
trap cleanup EXIT

switches() {  # context switches in one 10 s interval
  top -d -l 2 -s 10 -pid "$1" -stats pid,csw 2>/dev/null | awk -v pid="$1" '$1 == pid { last = $2 } END { print last }'
}

echo "=== 1. exit ends the session (new binary) ==="
sock="$work/a.sock"
"$new" serve --socket "$sock" --idle-timeout never >"$work/a.log" 2>&1 &
daemon=$!
sleep 1
( (sleep 2; printf 'exit\n'; sleep 3) | "$new" attach --socket "$sock" --session "$(uuidgen)" >/dev/null 2>&1 ) &
pids+=($!)
sleep 1
echo "before exit:"; "$new" list --socket "$sock"
sleep 5
echo "after exit:"; "$new" list --socket "$sock"
grep -E "ended|started" "$work/a.log"
disown -a 2>/dev/null
kill "$daemon"; daemon=; sleep 1

echo
echo "=== 2. hand-off old -> new keeps the sessions ==="
sock="$work/b.sock"
"$old" serve --socket "$sock" --idle-timeout never >"$work/b.log" 2>&1 &
daemon=$!
sleep 1
for _ in 1 2; do
  (tail -f /dev/null | "$old" attach --socket "$sock" --session "$(uuidgen)" >/dev/null 2>&1) &
  pids+=($!)
done
sleep 5
echo "old daemon pid $daemon, sessions:"; "$old" list --socket "$sock"
echo "old: $(switches "$daemon") context switches per 10 s"
echo "hand-off:"; "$new" hand-off --socket "$sock" --binary "$new"; echo "(exit $?)"
sleep 3
echo "pid still $daemon? $(ps -o pid=,comm= -p "$daemon")"
"$new" list --socket "$sock"
echo "new: $(switches "$daemon") context switches per 10 s"
grep -iE "hand|ended|error" "$work/b.log" | head
