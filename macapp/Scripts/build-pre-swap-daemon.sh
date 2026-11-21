#!/bin/bash
#
# Builds the daemon an app from before the swap (#681, ADR 0078) runs, from the last commit before
# it, for DaemonHandOffTests' first launch after the swap: that test starts it at the old bundle's
# `Contents/MacOS/workroomd` and has the new app hand it off to `Contents/Resources/workroom`. The
# test's `TEST_RUNNER_WR_FORMER_DAEMON` names the file this writes. ci-app.yml's `app` job builds it,
# cached by PRE_SWAP_COMMIT.
#
#   build-pre-swap-daemon.sh <out-file>   build that commit's daemon and put it at <out-file>
#   build-pre-swap-daemon.sh --commit     print the commit, for a cache key
#
# Built as that commit's build-daemon.sh built the app's: `cargo build --release -p workroom
# --features terminal-state` on its mk/vcs.mk's VCS_RUST, from a `git worktree add` of it outside
# this checkout, removed afterwards. Needs Zig on PATH for libghostty-vt, as build-daemon.sh does.
# WORKROOMD_BUILD=1, the number ci-app.yml builds the app's daemon with: a daemon refuses a
# hand-off to a lower build, so the commit's own time would refuse every CI build's binary.
set -euo pipefail

# The last commit on master before the swap: the app it builds runs its daemon from
# Contents/MacOS/workroomd. It must never move. A later commit is the swapped app, whose daemon
# the test cannot stand in for an older app's; test-invariants_test.sh checks it is still that.
PRE_SWAP_COMMIT=26d0aadc2ef563ab6ffeba74b3562c392714e7af

if [ "${1:-}" = "--commit" ]; then
  echo "$PRE_SWAP_COMMIT"
  exit 0
fi
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: build-pre-swap-daemon.sh <out-file> | --commit" >&2
  exit 2
fi
OUT="$1"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pre-swap-daemon.XXXXXX")"
SRC="$WORK/src"
cleanup() {
  git -C "$REPO" worktree remove --force "$SRC" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

git -C "$REPO" worktree add --quiet --detach "$SRC" "$PRE_SWAP_COMMIT"
VCS_RUST="$(awk '/^VCS_RUST :=/{print $3}' "$SRC/mk/vcs.mk")"
if [ -z "$VCS_RUST" ]; then
  echo "error: no VCS_RUST in $PRE_SWAP_COMMIT's mk/vcs.mk" >&2
  exit 1
fi

echo "Building the pre-swap daemon ($PRE_SWAP_COMMIT, Rust $VCS_RUST) -> $OUT"
(
  cd "$SRC/vcs"
  RUSTC="$(rustup which --toolchain "$VCS_RUST" rustc)"
  export RUSTC
  WORKROOMD_BUILD=1 CARGO_TARGET_DIR="$WORK/target" \
    rustup run "$VCS_RUST" cargo build --release -p workroom --features terminal-state
)
mkdir -p "$(dirname "$OUT")"
cp -f "$WORK/target/release/workroom" "$OUT.tmp"
codesign --force --sign - "$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"
# It runs here, so a test that fails on it fails on the hand-off, not on a broken file.
"$OUT" protocol >/dev/null
