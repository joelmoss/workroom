#!/usr/bin/env bash
#
# `make app-uitest-vm`'s test step: runs the UI tests just built for testing in Tart macOS guests
# instead of on this Mac's screen, so the person at it can keep working. Up to two guests run at
# once on a Mac (Virtualization.framework's limit), counted by `gui-lock.py vm-slot` across every
# checkout; a run that finds both slots taken waits and says who holds them. See "UI tests off the
# host screen" in docs/designs/parallel-workroom-testing.md.
#
# Usage (from macapp/): uitest-vm.sh <products-dir> [FLAG...]
#   <products-dir>  DerivedData/Build/Products, just built by build-for-testing
#   FLAG...         $(APP_UITEST_FLAGS): -only-testing:/-skip-testing: and other test options
#
# Environment:
#   VM_SHARDS=N      split the run across N guests at once (default 1). With -only-testing: entries
#                    their classes are dealt round-robin; without, each guest lists the suite and
#                    takes every Nth class.
#   VM_SLOTS=N       guests this Mac runs at once (default 2), the slot lock's count
#   VM_BASE=NAME     the base image to clone (default wr-uitest-base); never modified
#   VM_BOOT_TIMEOUT  seconds to wait for a guest to answer (default 180)
#   VM_RUN_TIMEOUT   seconds a booted guest may take to unpack, list and run its tests before it
#                    is stopped (default 3600)
#
# The products are snapshotted (tar) before waiting for a slot, so a rebuild in this checkout while
# the run waits does not change what it tests. Result bundles land in
# DerivedData/Logs/TestVM/<run>/; the snapshot is deleted however the run ends.
#
# Exit status: 0 when every guest's xcodebuild passed, else the first failing one's (1 when a guest
# could not be set up, 75 when the slot lock was unusable).
set -u

products="$1"
shift
scripts="$(cd "$(dirname "$0")" && pwd)"
shards="${VM_SHARDS:-1}"
slots="${VM_SLOTS:-2}"
base="${VM_BASE:-wr-uitest-base}"
export VM_BASE="$base"

say() { echo "uitest-vm: $*" >&2; }

case "$shards" in
  '' | *[!0-9]* | 0) say "VM_SHARDS must be a whole number of at least 1"; exit 2 ;;
esac
if ! command -v tart >/dev/null 2>&1; then
  say "tart is not on PATH. Install the notarized release from" \
    "https://github.com/cirruslabs/tart/releases (tart.tar.gz, tart.app into /Applications)."
  exit 1
fi
if ! tart get "$base" >/dev/null 2>&1; then
  say "no Tart VM named $base. Build it once as docs/designs/parallel-workroom-testing.md says."
  exit 1
fi

# The .xctestrun for this Mac's SDK; Build/Products keeps one per SDK it has built against.
sdk="$(xcrun --show-sdk-version)"
xctestrun="WorkroomAppUITests_macosx${sdk}-$(uname -m).xctestrun"
if [ ! -f "$products/$xctestrun" ]; then
  have=""
  for found in "$products"/*.xctestrun; do
    [ -e "$found" ] && have="$have ${found##*/}"
  done
  say "no $xctestrun in $products (have:${have:- none})"
  exit 1
fi
VM_HOST_XCODE="$(xcodebuild -version | tr '\n' ' ')"
export VM_HOST_XCODE

stamp="$(date +%Y.%m.%d_%H-%M-%S)"
run_dir="$(pwd)/DerivedData/Logs/TestVM/${stamp}-$$"
mkdir -p "$run_dir"
snapshot="$run_dir/products.tar"

pids=()
cleanup() {
  status=$?
  trap '' INT TERM HUP
  for pid in ${pids[@]+"${pids[@]}"}; do
    kill -TERM "$pid" 2>/dev/null
  done
  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" 2>/dev/null
  done
  rm -f "$snapshot"
  rmdir "$run_dir" 2>/dev/null
  exit "$status"
}
trap 'cleanup' EXIT

# Tarred, not copied file by file: the guest gets it through a virtiofs share, which breaks the
# symlinks inside framework bundles, so it is unpacked on the guest's own disk instead.
if ! tar -cf "$snapshot" -C "$products" .; then
  say "could not snapshot $products"; exit 1
fi

# Split the flags: -only-testing: entries are what shards divide, everything else every guest gets.
only=()
common=()
for flag in "$@"; do
  case "$flag" in
    # The scheme's only test target, so the same as no filter. Dropped rather than dealt: it names
    # no class, and next to a guest's class list xcodebuild would still run the whole target.
    -only-testing:WorkroomAppUITests) ;;
    -only-testing:*) only+=("$flag") ;;
    *) common+=("$flag") ;;
  esac
done

enumerate=0
declare -a shard_flags
if [ "$shards" -gt 1 ] && [ "${#only[@]}" -eq 0 ]; then
  enumerate=1
  say "no -only-testing: classes given: each of the $shards guests lists the suite and takes" \
    "one class in $shards"
  for ((i = 1; i <= shards; i++)); do shard_flags[i]=""; done
elif [ "$shards" -gt 1 ]; then
  # Deal whole classes, so a class's tests share one app launch sequence and one guest.
  classes=()
  for flag in "${only[@]}"; do
    id="${flag#-only-testing:}"
    target="${id%%/*}"
    rest="${id#*/}"
    class="$target/${rest%%/*}"
    known=
    for c in "${classes[@]+"${classes[@]}"}"; do [ "$c" = "$class" ] && known=1; done
    [ -n "$known" ] || classes+=("$class")
  done
  if [ "${#classes[@]}" -lt "$shards" ]; then
    say "only ${#classes[@]} class(es) to run, so ${#classes[@]} guest(s), not $shards"
    shards="${#classes[@]}"
  fi
  for ((i = 1; i <= shards; i++)); do shard_flags[i]=""; done
  for ((n = 0; n < ${#classes[@]}; n++)); do
    i=$((n % shards + 1))
    for flag in "${only[@]}"; do
      id="${flag#-only-testing:}"
      case "$id" in "${classes[n]}" | "${classes[n]}"/*) shard_flags[i]+=" $flag" ;; esac
    done
  done
else
  shard_flags[1]="${only[*]+"${only[*]}"}"
fi

say "snapshot taken; results go to $run_dir"
checkout="$(cd .. && pwd)"
for ((i = 1; i <= shards; i++)); do
  bundle="shard-$i.xcresult"
  [ "$shards" -eq 1 ] && bundle="UITests.xcresult"
  read -r -a extra <<<"${shard_flags[i]}"
  flags=(${common[@]+"${common[@]}"} ${extra[@]+"${extra[@]}"})
  command=(python3 "$scripts/gui-lock.py" vm-slot --slots "$slots"
    --label "app-uitest-vm $checkout (guest $i of $shards)" --
    bash "$scripts/uitest-vm-guest.sh" "$run_dir" "$xctestrun" "$bundle" "$i" "$shards" "$enumerate"
    ${flags[@]+"${flags[@]}"})
  if [ "$shards" -eq 1 ]; then
    "${command[@]}" &
  else
    # Each guest's lines carry its share, since both stream at once.
    "${command[@]}" > >(awk -v tag="[$i/$shards] " '{ print tag $0; fflush() }') 2>&1 &
  fi
  pids+=("$!")
done

# Waited on in the background so a TERM to this script reaches the trap, which passes it on to
# each guest's lock helper; Ctrl-C reaches them through the terminal's process group.
trap 'exit 143' TERM
trap 'exit 129' HUP
trap ':' INT
rc=0
statuses=()
for pid in "${pids[@]}"; do
  while :; do
    wait "$pid"
    status=$?
    kill -0 "$pid" 2>/dev/null || break
  done
  statuses+=("$status")
  [ "$rc" -eq 0 ] && [ "$status" -ne 0 ] && rc="$status"
done
pids=()
wait 2>/dev/null

bundles=()
for ((i = 1; i <= shards; i++)); do
  bundle="$run_dir/shard-$i.xcresult"
  [ "$shards" -eq 1 ] && bundle="$run_dir/UITests.xcresult"
  [ -d "$bundle" ] && bundles+=("$bundle")
  if [ "$shards" -gt 1 ]; then
    echo
    echo "Guest $i/$shards (xcodebuild exit ${statuses[i - 1]}):"
    sh "$scripts/test-summary.sh" "$bundle"
  fi
done
if [ "$shards" -eq 1 ]; then
  sh "$scripts/test-summary.sh" "${bundles[0]:-$run_dir/UITests.xcresult}"
elif [ "${#bundles[@]}" -gt 1 ]; then
  if xcrun xcresulttool merge --output-path "$run_dir/merged.xcresult" "${bundles[@]}" \
    >/dev/null 2>&1; then
    echo
    echo "All guests:"
    sh "$scripts/test-summary.sh" "$run_dir/merged.xcresult"
  else
    say "xcresulttool merge failed; the guests' summaries above are the result"
  fi
fi
# Ends with $rc as the status, which the EXIT trap's cleanup exits with. A subshell rather than a
# plain `exit`, which shellcheck (SC2329) reads as making the trap's function unreachable.
(exit "$rc")
