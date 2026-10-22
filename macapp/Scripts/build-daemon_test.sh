#!/bin/sh
#
# Dependency-free test for build-daemon.sh's architecture handling. No bats — just sh, cargo and
# lipo. Run: sh macapp/Scripts/build-daemon_test.sh   (exits non-zero on any mismatch).
#
# Why this exists, and why it is a copy of build-helper_test.sh rather than a shared helper: the
# bug it guards against already shipped once. `ARCHS` is a SPACE-SEPARATED LIST, build-helper.sh
# matched it as a single token, and 23 betas went out with an arm64-only CLI inside a fat .app —
# announced by nothing louder than a `warn:` in the build log. macapp/AGENTS.md records the rule
# that any new universal Mac binary must reuse that iteration; this is what proves workroomd does.
#
# CI never catches it: `make app-test` builds Debug with a single native arch, so the multi-arch
# branch is only exercised by a real Release/Nightly build.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# Overridable so the suite can be pointed at a modified copy, to confirm these cases actually FAIL
# against single-token ARCHS logic rather than passing vacuously.
HELPER="${BUILD_DAEMON:-${DIR}/build-daemon.sh}"
fails=0

command -v cargo >/dev/null 2>&1 || { echo "build-daemon_test: SKIP (cargo not on PATH)"; exit 0; }
command -v lipo >/dev/null 2>&1 || { echo "build-daemon_test: SKIP (lipo not on PATH)"; exit 0; }

# Cross-compiling needs rustup with both targets installed. Skip rather than fail on a machine that
# has only the host arch — the single-arch cases below still run and still catch a broken loop.
CROSS=1
if ! command -v rustup >/dev/null 2>&1; then
  CROSS=0
else
  for t in aarch64-apple-darwin x86_64-apple-darwin; do
    rustup target list --installed --toolchain "${WORKROOMD_RUST_TOOLCHAIN:-stable}" 2>/dev/null | grep -qx "$t" || CROSS=0
  done
fi

# Every configuration builds the Linux daemons (#227), so every case needs cargo-zigbuild and both
# musl targets.
LINUX=1
command -v cargo-zigbuild >/dev/null 2>&1 || LINUX=0
for t in aarch64-unknown-linux-musl x86_64-unknown-linux-musl; do
  command -v rustup >/dev/null 2>&1 \
    && rustup target list --installed --toolchain "${WORKROOMD_RUST_TOOLCHAIN:-stable}" 2>/dev/null | grep -qx "$t" \
    || LINUX=0
done
[ "$LINUX" -eq 1 ] || { echo "build-daemon_test: SKIP (cargo-zigbuild or musl targets not installed)"; exit 0; }

# Template-less `mktemp -d` is not $TMPDIR-aware on macOS (BSD mktemp asks
# confstr(_CS_DARWIN_USER_TEMP_DIR)), which makes the suite unrunnable in a sandbox that only
# grants $TMPDIR. Naming the template honours $TMPDIR on both BSD and GNU mktemp.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/build-daemon_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The real crate, but its own CARGO_TARGET_DIR, kept apart from cargo's default so the test neither
# pollutes nor is polluted by the developer's build tree. The daemon includes the VCS backends, so
# the first build is a full Cargo build.
#
# BUILD_DAEMON_TEST_TARGET_DIR swaps in a kept directory. CI restores it from the Actions cache, which
# halves the test (8m03s to 4m22s on macos-15); locally it defaults to one under vcs/target, which
# cargo owns and git ignores, so a rerun rebuilds nothing (73s to a few seconds). It must not be
# `vcs/target` ITSELF: build-daemon.sh copying from that default path instead of CARGO_TARGET_DIR
# is a bug this test catches only while the two differ.
REPO="$(cd "$DIR/../.." && pwd)"
export CARGO_TARGET_DIR="${BUILD_DAEMON_TEST_TARGET_DIR:-$REPO/vcs/target/build-daemon-test}"

# run_daemon <case-name> <ARCHS value> [CONFIGURATION] -> sets $OUT to the built helper path, $RC to
# the exit code. CONFIGURATION defaults to unset, which the script treats as Debug.
run_daemon() {
  case_name="$1"
  archs="$2"
  dest="$WORK/out-$case_name"
  mkdir -p "$dest/MacOS"
  OUT="$dest/MacOS/workroomd"
  SRCROOT="$REPO/macapp" \
  TARGET_BUILD_DIR="$dest" \
  EXECUTABLE_FOLDER_PATH="MacOS" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH="Resources" \
  DERIVED_FILE_DIR="$dest/intermediates" \
  CONFIGURATION="${3:-}" \
  ARCHS="$archs" \
    sh "$HELPER" >"$dest/log" 2>&1
  RC=$?
}

# expect_archs <case-name> <ARCHS value> <space-separated wanted archs>
expect_archs() {
  run_daemon "$1" "$2"
  if [ "$RC" -ne 0 ]; then
    echo "FAIL: ARCHS='$2' exited $RC, want 0. Log:"
    sed 's/^/    /' "$WORK/out-$1/log"
    fails=$((fails + 1))
    return
  fi
  got="$(lipo -archs "$OUT" 2>/dev/null)"
  for want in $3; do
    case " $got " in
      *" $want "*) ;;
      *)
        echo "FAIL: ARCHS='$2' produced '$got', missing '$want'"
        fails=$((fails + 1))
        ;;
    esac
  done
  # A stranded per-arch slice inside Contents/MacOS would be an unsigned Mach-O sealed into the
  # shipped app signature by a later single-arch build.
  if ls "$(dirname "$OUT")"/workroomd-slice-* >/dev/null 2>&1; then
    echo "FAIL: ARCHS='$2' left workroomd-slice-* inside MacOS"
    fails=$((fails + 1))
  fi
  # The binary must actually answer, or the app's health probe reports it unhealthy.
  # Only meaningful when a slice for this machine's arch is present.
  if [ "$(lipo -archs "$OUT" 2>/dev/null | tr ' ' '\n' | grep -cx "$(uname -m)")" -gt 0 ]; then
    if ! "$OUT" protocol 2>/dev/null | grep -q '^protocol '; then
      echo "FAIL: ARCHS='$2' built a binary that does not answer 'protocol'"
      fails=$((fails + 1))
    fi
    # The shipped daemon MUST keep a shadow copy of each session's screen. Without it every
    # session still works and every reattach comes back blank — a pane with no prompt after the
    # app is quit and relaunched, which is exactly how it was found, in the GUI, by hand.
    if ! "$OUT" protocol 2>/dev/null | grep -q '^terminal-state yes$'; then
      echo "FAIL: ARCHS='$2' built a daemon that cannot repaint a reattaching client"
      fails=$((fails + 1))
    fi
  fi
}

# expect_failure <case-name> <ARCHS value> <substring the error must contain>
expect_failure() {
  run_daemon "$1" "$2"
  if [ "$RC" -eq 0 ]; then
    echo "FAIL: ARCHS='$2' succeeded, want non-zero exit"
    fails=$((fails + 1))
    return
  fi
  if ! grep -q "$3" "$WORK/out-$1/log"; then
    echo "FAIL: ARCHS='$2' error did not mention '$3'. Log:"
    sed 's/^/    /' "$WORK/out-$1/log"
    fails=$((fails + 1))
  fi
}

HOST_ARCH="$(uname -m)"
expect_archs host "$HOST_ARCH" "$HOST_ARCH"

# A rebuild renames a new binary into place and never writes into the old one. A running daemon
# executes that file, and macOS SIGKILLs a process whose signed binary changes under it, so writing
# in place ended every Dev session on each rebuild, and any hand-off with them (#230).
#
# A hard link keeps hold of the file a running daemon would be executing. Its inode, not the path, is
# what must stay untouched: `codesign --force` leaves a new inode at the path either way.
ln "$OUT" "$WORK/running-daemon"
before="$(stat -f %m "$WORK/running-daemon")"
sleep 1
run_daemon host "$HOST_ARCH"
after="$(stat -f %m "$WORK/running-daemon")"
if [ "$RC" -ne 0 ] || [ "$before" != "$after" ]; then
  echo "FAIL: a rebuild wrote into the binary a running daemon executes (mtime $before -> $after, exit $RC)"
  fails=$((fails + 1))
fi
if [ -e "$(dirname "$OUT")/.workroomd-staged" ]; then
  echo "FAIL: a rebuild left .workroomd-staged inside MacOS"
  fails=$((fails + 1))
fi

if [ "$CROSS" -eq 1 ]; then
  # The case that shipped broken: a space-separated list must produce BOTH slices.
  expect_archs universal "arm64 x86_64" "arm64 x86_64"
  expect_archs universal_reversed "x86_64 arm64" "arm64 x86_64"
else
  echo "build-daemon_test: SKIP universal cases (rustup targets not installed)"
fi

# An unknown arch must be a hard error, not a silent fallback to the host — that fallback is
# precisely how the arm64-only CLI shipped.
expect_failure unknown_arch "arm64 ppc64" "unsupported arch"
# Whitespace-only ARCHS survives `${ARCHS:-...}` (it is set and non-empty) and yields no
# iterations; that must be a readable error, not a bash "unbound variable" death.
expect_failure blank_archs "   " "no architectures"

# expect_linux_daemons <case-name>: both ELFs present, static, and the right arch.
expect_linux_daemons() {
  if [ "$RC" -ne 0 ]; then
    echo "FAIL: $1 exited $RC, want 0. Log:"
    sed 's/^/    /' "$WORK/out-$1/log"
    fails=$((fails + 1))
    return
  fi
  for pair in "aarch64:ARM aarch64" "x86_64:x86-64"; do
    arch="${pair%%:*}"
    want="${pair#*:}"
    desc="$(file -b "$WORK/out-$1/Resources/workroomd-linux-$arch" 2>/dev/null)"
    case "$desc" in
      *"ELF 64-bit"*"$want"*"statically linked"*) ;;
      *)
        echo "FAIL: $1: workroomd-linux-$arch is not a static $want ELF: '${desc:-missing}'"
        fails=$((fails + 1))
        ;;
    esac
  done
}

# Every build ships a static Linux daemon for EVERY Linux arch, whatever ARCHS says: the remote box's
# arch has nothing to do with the Mac's. Debug included, since every build offers remote workrooms;
# its stale file must come back as a real daemon. The Linux CI job runs `protocol` on the ELFs, which
# this Mac cannot.
mkdir -p "$WORK/out-debug_linux/Resources"
: >"$WORK/out-debug_linux/Resources/workroomd-linux-aarch64"
run_daemon debug_linux "$HOST_ARCH"
expect_linux_daemons debug_linux
# Reuses the Linux builds above, so it costs a copy, not a compile.
run_daemon release_linux "$HOST_ARCH" Release
expect_linux_daemons release_linux

if [ "$fails" -eq 0 ]; then
  echo "build-daemon_test: OK"
  exit 0
fi
echo "build-daemon_test: $fails failure(s)"
exit 1
