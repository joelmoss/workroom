#!/bin/bash
#
# What an idle workroomd costs. Starts the given binary on a socket of its own, attaches a few
# shells and leaves them alone, then records the daemon's CPU time (ps) and its context switches
# and BSD syscalls per 10 s (top) over the window. Run it on a binary from before a change and one
# from after, same machine, same minute: the measure that found the pty reader waking 200 times a
# second per session (2026-10-22: 1.0% of a core and ~690 switches/s with 4 idle sessions, then
# ~1.6 switches/s). macOS only: `top -d` and `ps -M` are what it reads.
#
#   daemon-idle-bench.sh <workroomd binary> [seconds=60] [sessions=4]
#
# Prints the CPU time before and after, one line per 10 s sample (%CPU, context switches, BSD
# syscalls), and the average switches per second. Exits non-zero if the daemon dies underneath it.
set -u

bin="${1:?usage: daemon-idle-bench.sh <workroomd binary> [seconds=60] [sessions=4]}"
secs="${2:-60}"
sessions="${3:-4}"

# Not under /tmp: a daemon there looks every second, as the socket fallback must (serve.rs
# `poll_timeout`), and this measures the usual daemon. $TMPDIR keeps the socket path well under
# the ~100 bytes a Unix socket path allows.
work="$(mktemp -d "${TMPDIR:-/tmp}/wrbench.XXXXXX")"
sock="$work/d.sock"
pids=()
cleanup() {
  disown -a 2>/dev/null  # no "Terminated" line per job we kill
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  [ -n "${daemon:-}" ] && kill "$daemon" 2>/dev/null
  sleep 1
  rm -rf "$work"
}
trap cleanup EXIT

"$bin" serve --socket "$sock" --idle-timeout never >"$work/serve.log" 2>&1 &
daemon=$!
sleep 1
for _ in $(seq "$sessions"); do
  (tail -f /dev/null | "$bin" attach --socket "$sock" --session "$(uuidgen)" >/dev/null 2>&1) &
  pids+=($!)
done
sleep 8  # let the shells finish starting up
echo "sessions:"
"$bin" list --socket "$sock" 2>&1 | head -n "$((sessions + 2))"
kill -0 "$daemon" 2>/dev/null || { echo "the daemon died:"; cat "$work/serve.log"; exit 1; }

before="$(ps -o time= -p "$daemon")"
echo "sampling $secs s ..."
# One line per 10 s interval; the first top sample is since process start, so it is dropped.
samples="$(top -d -l "$((secs / 10 + 1))" -s 10 -pid "$daemon" -stats pid,cpu,csw,sysbsd,command 2>/dev/null \
  | awk -v pid="$daemon" '$1 == pid' | tail -n +2)"
after="$(ps -o time= -p "$daemon")"
kill -0 "$daemon" 2>/dev/null || { echo "the daemon died during the run:"; cat "$work/serve.log"; exit 1; }

echo "cpu time: $before -> $after over $secs s"
echo "per 10 s: %CPU CSW SYSBSD"
echo "$samples" | awk '{ print $2, $3, $4 }'
echo "$samples" | awk '{ csw += $3; n++ } END { if (n) printf "average: %.1f context switches/s\n", csw / (n * 10) }'
