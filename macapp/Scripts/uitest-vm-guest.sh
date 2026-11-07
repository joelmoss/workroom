#!/usr/bin/env bash
#
# Runs one share of a `make app-uitest-vm` run in a throwaway Tart guest: clones the base image,
# boots it, unpacks the run's products snapshot in it, runs xcodebuild test-without-building there,
# and always stops and deletes the clone, however this script ends. uitest-vm.sh calls it under
# `gui-lock.py vm-slot`, which sets WR_VM_SLOT; see docs/designs/parallel-workroom-testing.md.
#
# Usage: uitest-vm-guest.sh <run-dir> <xctestrun> <bundle> <shard> <shards> <enumerate> [FLAG...]
#   <run-dir>    host directory shared read-write into the guest as "results"; holds products.tar,
#                and receives <bundle> (a .xcresult name) and this guest's tart log
#   <xctestrun>  the .xctestrun file name inside the products snapshot
#   <shard>/<shards>  this guest's share, 1-based, and how many guests split the run
#   <enumerate>  1: list the suite's tests in the guest (enumerating launches the test runner app,
#                so never on the host) and run every <shards>-th class from <shard>; 0: run FLAGs
#   FLAG...      xcodebuild test options ($(APP_UITEST_FLAGS), split per shard by uitest-vm.sh)
#
# Environment: WR_VM_SLOT (from gui-lock.py), VM_BASE (default wr-uitest-base), VM_BOOT_TIMEOUT
# (seconds to wait for the guest agent, default 180), VM_RUN_TIMEOUT (seconds the booted guest may
# take to unpack, list and run the tests, default 3600), VM_HOST_XCODE (the host's
# `xcodebuild -version`, which the guest's must match).
#
# Exit status: the guest xcodebuild's; 1 when the guest could not be set up; 124 when it ran past
# VM_RUN_TIMEOUT.
set -u

run_dir="$1"
xctestrun="$2"
bundle="$3"
shard="$4"
shards="$5"
enumerate="$6"
shift 6

slot="${WR_VM_SLOT:?uitest-vm-guest.sh runs under gui-lock.py vm-slot}"
base="${VM_BASE:-wr-uitest-base}"
boot_timeout="${VM_BOOT_TIMEOUT:-180}"
run_timeout="${VM_RUN_TIMEOUT:-3600}"
# The guest is named after its slot and this script's pid, so two runs never pick one name, and a
# clone a killed run left behind can be told apart from a live run's.
vm="wr-uitest-${slot}-$$"
share="/Volumes/My Shared Files/results"
log="$run_dir/$vm.tart.log"
# Tart prunes its OCI cache to make room for a clone; a test run must never delete images.
export TART_NO_AUTO_PRUNE=1

say() { echo "uitest-vm[$shard/$shards]: $*" >&2; }

created=
run_pid=
exec_pid=

cleanup() {
  status=$?
  # A second Ctrl-C, or a closed output pipe, must not abandon a running clone.
  trap '' INT TERM HUP PIPE
  if [ -n "$exec_pid" ]; then
    kill "$exec_pid" 2>/dev/null
    wait "$exec_pid" 2>/dev/null
  fi
  if [ -n "$run_pid" ]; then
    tart stop --timeout 10 "$vm" >>"$log" 2>&1
    kill "$run_pid" 2>/dev/null
    wait "$run_pid" 2>/dev/null
  fi
  if [ -n "$created" ] && ! tart delete "$vm" >>"$log" 2>&1; then
    say "could not delete the clone $vm; remove it with: tart delete $vm"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

case "$run_dir" in
  *:*) say "the run directory's path holds a ':', which tart --dir cannot take: $run_dir"; exit 1 ;;
esac

# A run that was SIGKILLed never reached its trap and left its clone behind. Only clones named by
# this script whose run is gone; never the base, nor another run's live guest.
for name in $(tart list --source local --quiet 2>/dev/null); do
  rest="${name#wr-uitest-}"
  [ "$rest" != "$name" ] || continue
  owner="${rest##*-}"
  clone_slot="${rest%-*}"
  case "$clone_slot" in '' | *[!0-9]*) continue ;; esac
  case "$owner" in '' | *[!0-9]*) continue ;; esac
  kill -0 "$owner" 2>/dev/null && continue
  say "removing $name, left behind by a run that is gone"
  tart stop --timeout 5 "$name" >/dev/null 2>&1
  tart delete "$name" >/dev/null 2>&1
done

say "cloning $base to $vm (VM slot $slot)"
if ! tart clone "$base" "$vm" >>"$log" 2>&1; then
  say "tart clone $base $vm failed:"; tail -n 5 "$log" >&2; exit 1
fi
created=1
# Clones share the base's MAC address; two guests on one MAC fight over the NAT's DHCP lease.
tart set "$vm" --random-mac >>"$log" 2>&1

started=$(date +%s)
tart run "$vm" --no-graphics "--dir=results:$run_dir" >>"$log" 2>&1 &
run_pid=$!

# The guest agent answers once the guest has booted and logged in: 17-30 s measured, up to 40 s
# when two guests boot at once.
until tart exec "$vm" true >/dev/null 2>&1; do
  if ! kill -0 "$run_pid" 2>/dev/null; then
    run_pid=
    say "the guest stopped before it answered; tart run's log:"; tail -n 20 "$log" >&2; exit 1
  fi
  if [ $(($(date +%s) - started)) -ge "$boot_timeout" ]; then
    say "the guest agent did not answer within ${boot_timeout}s (VM_BOOT_TIMEOUT); tart run's log:"
    tail -n 20 "$log" >&2
    exit 1
  fi
  sleep 2
done
say "guest up after $(($(date +%s) - started))s"

# VM_RUN_TIMEOUT covers everything from here on: unpacking, listing the suite and the tests. A guest
# that stalls says nothing: one full-suite guest sat 75 minutes in a test's Set Up before its VM
# stopped (2026-11-07). Bounded, so a stall fails the run instead of holding its slot.
deadline=$(($(date +%s) + run_timeout))

# Usage: in_guest <doing> <out> COMMAND...: runs COMMAND, its output appended to <out> (empty: this
# script's own), and exits 124 if it is still running at the deadline. In the background and waited
# for, because bash runs a trap only once its foreground command has exited: run in the foreground,
# a TERM would wait the command out before the guest stopped.
in_guest() {
  local doing="$1" out="$2" rc
  shift 2
  if [ -n "$out" ]; then
    "$@" >>"$out" 2>&1 &
  else
    "$@" &
  fi
  exec_pid=$!
  while kill -0 "$exec_pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "the guest ran past ${run_timeout}s (VM_RUN_TIMEOUT) while $doing; stopping it"
      exit 124
    fi
    sleep 2
  done
  wait "$exec_pid"
  rc=$?
  exec_pid=
  return "$rc"
}

# The .xctestrun resolves __PLATFORMS__ and the shared frameworks against the guest's Xcode, so a
# different Xcode there runs against the wrong runtime, or not at all.
guest_xcode="$(tart exec "$vm" xcodebuild -version 2>&1 | tr '\n' ' ')"
if [ -n "${VM_HOST_XCODE:-}" ] && [ "$guest_xcode" != "$VM_HOST_XCODE" ]; then
  say "the guest's Xcode ($guest_xcode) is not this Mac's ($VM_HOST_XCODE)."
  say "rebuild $base from the image whose Xcode matches \`xcodebuild -version\`."
  exit 1
fi

# Unpacked inside the guest, not run from the share: virtiofs breaks the symlinks inside the
# app's frameworks ("Too many levels of symbolic links").
guest_home="$(tart exec "$vm" printenv HOME)"
products="$guest_home/products"
if [ -z "$guest_home" ] || ! tart exec "$vm" mkdir -p "$products" \
  || ! in_guest "unpacking the products" "$log" \
    tart exec "$vm" tar -xf "$share/products.tar" -C "$products"; then
  say "could not unpack the products snapshot in the guest; its output is in $log"; exit 1
fi
# xcodebuild finds the test products next to the .xctestrun (__TESTROOT__), so no cd is needed.
xctestrun="$products/$xctestrun"

if [ "$enumerate" = 1 ]; then
  list="$run_dir/$vm.tests.json"
  if ! in_guest "listing the suite's tests" "$log" \
    tart exec "$vm" xcodebuild test-without-building -xctestrun "$xctestrun" \
    -destination platform=macOS -enumerate-tests -test-enumeration-format json \
    -test-enumeration-style flat -test-enumeration-output-path "$share/$(basename "$list")" "$@"
  then
    say "could not list the suite's tests in the guest; its output is in $log"; exit 1
  fi
  # Every guest lists the same products with the same flags, so each takes its own classes from
  # the same sorted list without asking the others.
  only="$(python3 -c '
import json, sys
values = json.load(open(sys.argv[1]))["values"]
classes = sorted({t["identifier"].rsplit("/", 1)[0] for v in values for t in v["enabledTests"]})
shard, shards = int(sys.argv[2]), int(sys.argv[3])
print(" ".join("-only-testing:" + c for c in classes[shard - 1::shards]))
' "$list" "$shard" "$shards")" || { say "could not read the guest's test list"; exit 1; }
  rm -f "$list"
  if [ -z "$only" ]; then
    say "no test classes left for this guest"; exit 0
  fi
  read -r -a classes <<<"$only"
  say "running ${#classes[@]} classes: ${only//-only-testing:WorkroomAppUITests\//}"
  set -- "$@" "${classes[@]}"
fi

say "xcodebuild test-without-building $*"
in_guest "running the tests" "" tart exec "$vm" xcodebuild test-without-building \
  -xctestrun "$xctestrun" -destination platform=macOS -resultBundlePath "$share/$bundle" "$@"
