#!/bin/bash
#
# Builds `libghostty-vt` — Ghostty's terminal emulator as a standalone C library — for one target,
# and caches the result. The agent links it to keep a shadow copy of every session's screen, which
# is what lets a reattaching client be repainted instead of arriving at a blank terminal.
#
#   ./build-ghostty-vt.sh [--target <triple>] [--print-prefix]
#
# Targets are Zig triples: aarch64-macos, x86_64-macos, x86_64-linux-musl, aarch64-linux-musl.
# Defaults to the host.
#
# THE PIN IS THE POINT. This must build the same engine revision the app's GhosttyKit is built
# from, because a snapshot written by one and decoded by another is not a supported combination —
# snapshot format v1 carries no binary-compatibility guarantee, and the header says the API is
# "definitely going to change". macapp/project.yml is the single source of truth for which engine
# the app ships; GHOSTTY_SHA below must match the sha recorded there, and the two are bumped
# together. See docs/designs/remote-workrooms.md, Distribution Plan.
set -euo pipefail

# Must match `ghostty engine` in macapp/project.yml.
GHOSTTY_SHA="c4e16970a"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
# build.zig.zon's `minimum_zig_version` at the pinned sha.
ZIG_VERSION="0.16.0"

target=""
print_prefix=false
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    --print-prefix) print_prefix=true; shift ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$target" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target="aarch64-macos" ;;
    Darwin-x86_64) target="x86_64-macos" ;;
    Linux-x86_64) target="x86_64-linux-musl" ;;
    Linux-aarch64) target="aarch64-linux-musl" ;;
    *) echo "error: unsupported host $(uname -s)-$(uname -m); pass --target" >&2; exit 1 ;;
  esac
fi

# Cache outside the repo: this is a third-party build artifact keyed by (sha, target), shared by
# every checkout and worktree on the machine, and it must not land in `git status`.
CACHE_ROOT="${WR_GHOSTTY_VT_CACHE:-${HOME}/.cache/workroom/ghostty-vt}"
# The cache is keyed by target triple as well as sha. Sharing one Zig cache across two -Dtarget
# values yields a non-reproducible second binary — a trap exe-scroll's own build script documents.
PREFIX="${CACHE_ROOT}/${GHOSTTY_SHA}/${target}"

if $print_prefix; then
  echo "$PREFIX"
  exit 0
fi

# Already built? The archive plus the header it must ship with is the completeness check; a
# half-populated prefix from an interrupted build would otherwise look done.
if [ -f "${PREFIX}/lib/libghostty-vt.a" ] && [ -f "${PREFIX}/include/ghostty/vt/snapshot.h" ]; then
  echo "libghostty-vt: cached ($target, $GHOSTTY_SHA)" >&2
  echo "$PREFIX"
  exit 0
fi

# Zig via mise when it is available, since that is how the repo pins other toolchains; otherwise a
# `zig` already on PATH, checked for version so a mismatched one fails loudly rather than
# mysteriously several hundred lines into a build.
if command -v mise >/dev/null 2>&1; then
  mise install "zig@${ZIG_VERSION}" >/dev/null 2>&1 || true
  ZIG="mise exec zig@${ZIG_VERSION} -- zig"
elif command -v zig >/dev/null 2>&1; then
  have="$(zig version)"
  if [ "$have" != "$ZIG_VERSION" ]; then
    echo "error: zig $ZIG_VERSION required, found $have. Install mise, or 'zig' $ZIG_VERSION on PATH." >&2
    exit 1
  fi
  ZIG="zig"
else
  echo "error: no zig and no mise. libghostty-vt needs zig $ZIG_VERSION to build." >&2
  exit 1
fi

# Source resolution, in order of preference, so a build never reaches the network when it does not
# have to and never reaches it SILENTLY when it does:
#
#   1. $WR_GHOSTTY_SRC       — an existing checkout, for an air-gapped or vendored build
#   2. vcs/vendor/ghostty    — a submodule or manual checkout inside the repo
#   3. the cache             — already fetched for this sha on this machine
#   4. a clone from upstream — the only path that needs network, and it says so
SRC=""
if [ -n "${WR_GHOSTTY_SRC:-}" ]; then
  [ -d "${WR_GHOSTTY_SRC}/.git" ] || {
    echo "error: WR_GHOSTTY_SRC=${WR_GHOSTTY_SRC} is not a git checkout." >&2
    exit 1
  }
  SRC="$WR_GHOSTTY_SRC"
elif [ -d "$(dirname "$0")/../vendor/ghostty/.git" ]; then
  SRC="$(cd "$(dirname "$0")/../vendor/ghostty" && pwd)"
else
  SRC="${CACHE_ROOT}/src-${GHOSTTY_SHA}"
  if [ ! -d "${SRC}/.git" ]; then
    if ! git ls-remote --exit-code "$GHOSTTY_REPO" HEAD >/dev/null 2>&1; then
      echo "error: libghostty-vt needs ghostty @ ${GHOSTTY_SHA} and cannot reach ${GHOSTTY_REPO}." >&2
      echo "       This is the ONLY network dependency in the build, and only with the" >&2
      echo "       'terminal-state' feature. To build offline, point WR_GHOSTTY_SRC at a checkout," >&2
      echo "       place one at vcs/vendor/ghostty, or set WR_GHOSTTY_VT_PREFIX to a prebuilt" >&2
      echo "       library. See vcs/scripts/build-ghostty-vt.sh." >&2
      exit 1
    fi
    echo "libghostty-vt: fetching ghostty @ ${GHOSTTY_SHA}" >&2
    rm -rf "$SRC"
    mkdir -p "$(dirname "$SRC")"
    # Blobless rather than shallow: a shallow clone cannot check out an arbitrary sha, and a full
    # clone of ghostty is large enough to be worth avoiding.
    git clone --filter=blob:none --no-checkout "$GHOSTTY_REPO" "$SRC" >&2
  fi
fi
# Only the cache is ours to update. A checkout someone pointed us at is theirs: fetching into it
# would mutate a tree they may be working in, and the sha assertion below catches a wrong one
# with a readable message either way.
if ! git -C "$SRC" checkout --quiet "$GHOSTTY_SHA" 2>/dev/null; then
  if [ -n "${WR_GHOSTTY_SRC:-}" ] || [ "$SRC" != "${CACHE_ROOT}/src-${GHOSTTY_SHA}" ]; then
    echo "error: ${SRC} does not contain ghostty ${GHOSTTY_SHA}. Fetch it there first." >&2
    exit 1
  fi
  git -C "$SRC" fetch --filter=blob:none origin >&2
  git -C "$SRC" checkout --quiet "$GHOSTTY_SHA" >&2
fi

# Verify we got what we asked for. A moved branch or a truncated sha that resolved to something
# else would otherwise link a different emulator than the app ships, which is exactly the failure
# the pin exists to prevent.
actual="$(git -C "$SRC" rev-parse --short HEAD)"
if [ "$actual" != "$GHOSTTY_SHA" ]; then
  echo "error: ghostty checkout is $actual, expected $GHOSTTY_SHA." >&2
  exit 1
fi

echo "libghostty-vt: building ($target, $GHOSTTY_SHA)" >&2
BUILD_TMP="${PREFIX}.building.$$"
rm -rf "$BUILD_TMP"
trap 'rm -rf "$BUILD_TMP"' EXIT

( cd "$SRC" && $ZIG build \
    -Demit-lib-vt=true \
    -Doptimize=ReleaseFast \
    -Dtarget="$target" \
    --cache-dir "${CACHE_ROOT}/zig-cache-${target}" \
    --prefix "$BUILD_TMP" >&2 )

if [ ! -f "${BUILD_TMP}/lib/libghostty-vt.a" ]; then
  echo "error: build produced no libghostty-vt.a for $target." >&2
  exit 1
fi

# Publish atomically, so a concurrent reader never sees a half-written prefix.
rm -rf "$PREFIX"
mkdir -p "$(dirname "$PREFIX")"
mv "$BUILD_TMP" "$PREFIX"
trap - EXIT

echo "$PREFIX"
