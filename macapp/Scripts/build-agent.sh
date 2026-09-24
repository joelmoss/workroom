#!/bin/bash
#
# Builds the `wr-agent` Rust helper and embeds it in the app bundle's Contents/MacOS, then signs
# it with the same identity as the app. Run as a post-compile Xcode script phase (before Xcode's
# final code-sign) so the embedded binary is covered by the app signature — an unsigned or
# post-sign-modified helper fails notarization/Gatekeeper.
#
# Unlike the Go CLI (see build-helper.sh), this one CAN live in Contents/MacOS: "wr-agent" does
# not collide with the app executable "Workroom" on a case-insensitive filesystem. It goes there
# because that is where `PersistentSessionPaths.binaryURL(for:)` looks, beside workroom-session.
#
# Release and Nightly builds also put a static Linux agent per arch in Contents/Resources, for remote
# hosts. See the end of this file.
#
# Env vars provided by Xcode: SRCROOT, TARGET_BUILD_DIR, EXECUTABLE_FOLDER_PATH,
# UNLOCALIZED_RESOURCES_FOLDER_PATH, EXPANDED_CODE_SIGN_IDENTITY, ARCHS, DERIVED_FILE_DIR,
# CONFIGURATION.
set -euo pipefail

HELPER_NAME="wr-agent"
CARGO_DIR="$(cd "${SRCROOT}/../vcs" && pwd)"
DEST_DIR="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
DEST="${DEST_DIR}/${HELPER_NAME}"

# Xcode's build environment lacks cargo/rustup on PATH. `~/.local/bin` is on it for mise, which is
# how vcs/scripts/build-ghostty-vt.sh gets the pinned Zig on a cache miss — without it an engine-sha
# bump fails an Xcode-driven build with "no zig and no mise" while the same build from a terminal
# succeeds.
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: 'cargo' not found on PATH. Install Rust or adjust PATH in build-agent.sh." >&2
  exit 1
fi

# `ARCHS` is a SPACE-SEPARATED LIST — a universal Release build passes "arm64 x86_64" — so this
# iterates rather than matching a single token, and hard-errors on anything unknown.
#
# This is not defensiveness for its own sake: build-helper.sh once `case`d the whole string and
# fell through to an arm64 default, so 23 shipped betas contained an arm64-only Go CLI inside a fat
# app. macapp/CLAUDE.md records that any new universal Mac binary must reuse this iteration rather
# than growing its own arch handling, which is what this is.
ARCH_LIST="${ARCHS:-$(uname -m)}"
TARGETS=()
for arch in $ARCH_LIST; do
  case "$arch" in
    arm64) TARGETS+=(aarch64-apple-darwin) ;;
    x86_64) TARGETS+=(x86_64-apple-darwin) ;;
    *) echo "error: unsupported arch '$arch' in ARCHS='$ARCH_LIST'." >&2; exit 1 ;;
  esac
done
# `${ARCHS:-...}` only substitutes when unset or empty, so a whitespace-only ARCHS survives the
# default and yields no iterations. On bash 3.2 (what /bin/bash still is on macOS) an empty array
# under `set -u` is "unbound", so catch it here with a readable error.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "error: ARCHS='$ARCH_LIST' yielded no architectures to build." >&2
  exit 1
fi

# Homebrew's rust ships only the host arch's std, so cross-compiling needs rustup — the same
# constraint vcs/scripts/build-apple.sh documents for the VCS core, and the same cryptic
# "can't find crate for `core`" if it is missing.
CARGO="cargo"
AGENT_TOOLCHAIN="${WR_AGENT_RUST_TOOLCHAIN:-stable}"
# The VCS service links jj-lib (MSRV 1.93). Xcode can expose an older default rustup
# toolchain than the terminal's Homebrew rust, so select stable when necessary.
if ! rustc --version | awk '{split($2,v,"."); exit !(v[1] > 1 || v[1] == 1 && v[2] >= 93)}'; then
  if ! rustup run "$AGENT_TOOLCHAIN" rustc --version 2>/dev/null | awk '{split($2,v,"."); exit !(v[1] > 1 || v[1] == 1 && v[2] >= 93)}'; then
    echo "error: wr-agent VCS needs Rust >= 1.93. Run 'rustup update $AGENT_TOOLCHAIN'." >&2
    exit 1
  fi
  CARGO="rustup run $AGENT_TOOLCHAIN cargo"
fi
if [ "${#TARGETS[@]}" -gt 1 ] || [ "${TARGETS[0]}" != "$(rustc -vV | awk '/^host:/{print $2}')" ]; then
  if ! command -v rustup >/dev/null 2>&1; then
    echo "error: cross-compiling $HELPER_NAME needs rustup (Homebrew rust cannot). Install rustup, then 'rustup target add ${TARGETS[*]}'." >&2
    exit 1
  fi
  for target in "${TARGETS[@]}"; do
    if ! rustup target list --installed --toolchain "$AGENT_TOOLCHAIN" 2>/dev/null | grep -qx "$target"; then
      echo "error: rustup target '$target' is not installed. Run 'rustup target add --toolchain $AGENT_TOOLCHAIN $target'." >&2
      exit 1
    fi
  done
  if ! rustup run "$AGENT_TOOLCHAIN" rustc --version 2>/dev/null | awk '{split($2,v,"."); exit !(v[1] > 1 || v[1] == 1 && v[2] >= 93)}'; then
    echo "error: wr-agent VCS needs Rust >= 1.93. Update stable or set WR_AGENT_RUST_TOOLCHAIN to a compatible installed toolchain." >&2
    exit 1
  fi
  CARGO="rustup run $AGENT_TOOLCHAIN cargo"
fi

# Cargo resolves rustc through PATH even when rustup selected cargo. Pin the matching
# compiler so a Homebrew rustc cannot silently replace the cross-capable toolchain.
if [ "$CARGO" != "cargo" ]; then
  export RUSTC="$(rustup which --toolchain "$AGENT_TOOLCHAIN" rustc)"
fi

echo "Building $HELPER_NAME (${TARGETS[*]}) -> $DEST"
mkdir -p "$DEST_DIR"

# Slices go to Xcode's intermediates dir, not `mktemp -d`, and cleanup is unconditional: the
# fallback can place them beside the helper inside the bundle, and a per-arch Mach-O stranded
# there by an interrupted run would be sealed into the app signature by a later single-arch build.
SLICE_DIR="${DERIVED_FILE_DIR:-$DEST_DIR}"
mkdir -p "$SLICE_DIR"
rm -f "$SLICE_DIR/${HELPER_NAME}-slice-"*
trap 'rm -f "$SLICE_DIR/${HELPER_NAME}-slice-"*' EXIT

# Where cargo actually puts the binary. NOT unconditionally `$CARGO_DIR/target`: an outer
# CARGO_TARGET_DIR redirects the build, and copying from the default path would then embed a
# STALE binary from the developer's tree while reporting a successful build. build-agent_test.sh
# sets exactly that variable to keep its builds out of the working tree, so the bug it hid was
# its own assertions passing against a binary this script never produced.
OUT_ROOT="${CARGO_TARGET_DIR:-$CARGO_DIR/target}"

SLICES=()
for target in "${TARGETS[@]}"; do
  # `terminal-state` is not optional for the app, whatever its name suggests. Without it the
  # agent keeps no shadow copy of the screen, so a pane reattaching to a live session is repainted
  # with nothing — which is what shipping it off looked like: after quitting and relaunching, a
  # persisted terminal showed an empty pane with no prompt. It is a cargo feature only because it
  # links libghostty-vt, which a bare `cargo test` should not have to build.
  #
  # The library is cached per (engine sha, target) outside the repo, so only the first build of a
  # given pin pays for it; see vcs/scripts/build-ghostty-vt.sh.
  ( cd "$CARGO_DIR" && $CARGO build --release -p wr-agent --features terminal-state --target "$target" )
  cp -f "$OUT_ROOT/$target/release/$HELPER_NAME" "$SLICE_DIR/${HELPER_NAME}-slice-$target"
  SLICES+=("$SLICE_DIR/${HELPER_NAME}-slice-$target")
done

if [ "${#SLICES[@]}" -eq 1 ]; then
  cp -f "${SLICES[0]}" "$DEST"
else
  lipo -create "${SLICES[@]}" -output "$DEST"
fi
rm -f "${SLICES[@]}"
trap - EXIT

# A single-arch build must also clear slices a previous multi-arch run may have stranded here —
# switching Release -> Debug is exactly the sequence that would otherwise leave one behind.
rm -f "$DEST_DIR/${HELPER_NAME}-slice-"*

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ] || [ -z "$IDENTITY" ]; then
  echo "Ad-hoc signing $HELPER_NAME (local dev build)"
  codesign --force --sign - "$DEST"
else
  echo "Signing $HELPER_NAME with $IDENTITY (hardened runtime + timestamp)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DEST"
fi

# Linux agents (issue #227). Workroom.app pushes the agent to a remote box on first connect
# (docs/designs/remote-workrooms.md, Distribution Plan), so the bundle carries a static musl build
# for each Linux arch, named by what `uname -m` prints there.
#
# Both ship ALWAYS. A remote box's arch has nothing to do with the Mac's, so these do not follow
# `ARCHS`, and the ARCH_LIST rule above (for universal MAC binaries) does not apply to them.
#
# Resources, not MacOS, and not codesigned. codesign sees an ELF as data, and the app's own
# signature seals it like any other resource.
#
# Release and Nightly only, unless WR_AGENT_LINUX=1. They are two more release builds of the agent,
# and a Debug app has no remote host to push them to yet. A build that skips them also removes any
# that an earlier opt-in build left, so a bundle never carries a stale agent.
RES_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ "${CONFIGURATION:-Debug}" = "Debug" ] && [ "${WR_AGENT_LINUX:-}" != "1" ]; then
  rm -f "$RES_DIR/${HELPER_NAME}-linux-"*
  exit 0
fi

if ! command -v cargo-zigbuild >/dev/null 2>&1; then
  echo "error: the Linux agents need cargo-zigbuild. Run 'cargo install cargo-zigbuild --locked'." >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "error: the Linux agents need rustup (Homebrew rust cannot cross-compile)." >&2
  exit 1
fi
LINUX_ARCHES="aarch64 x86_64"
for arch in $LINUX_ARCHES; do
  if ! rustup target list --installed --toolchain "$AGENT_TOOLCHAIN" 2>/dev/null | grep -qx "$arch-unknown-linux-musl"; then
    echo "error: rustup target '$arch-unknown-linux-musl' is not installed. Run 'rustup target add --toolchain $AGENT_TOOLCHAIN $arch-unknown-linux-musl'." >&2
    exit 1
  fi
done

# cargo-zigbuild re-invokes `cargo` from PATH, so a Homebrew cargo earlier on PATH (see the export at
# the top) would build against a std with no musl target: "can't find crate for `core`". Put the
# toolchain's own bin directory first. vcs/scripts/test-linux.sh documents the same trap.
TOOLCHAIN_BIN="$(dirname "$(rustup which --toolchain "$AGENT_TOOLCHAIN" cargo)")"

# cargo-zigbuild links with `zig`, at the version libghostty-vt is pinned to. mise's copy when mise
# has one, otherwise whatever is on PATH, and checked either way. The directory goes on PATH rather
# than using `mise exec`, which would also put the user's other mise tools (a rust, say) ahead of
# TOOLCHAIN_BIN.
ZIG_VERSION="$(awk -F'"' '/^ZIG_VERSION=/{print $2}' "$CARGO_DIR/scripts/build-ghostty-vt.sh")"
ZIG_DIR=""
if command -v mise >/dev/null 2>&1; then
  mise install "zig@${ZIG_VERSION}" >/dev/null 2>&1 || true
  ZIG_HOME="$(mise where "zig@${ZIG_VERSION}" 2>/dev/null || true)"
  for candidate in "$ZIG_HOME/bin" "$ZIG_HOME"; do
    if [ -n "$ZIG_HOME" ] && [ -x "$candidate/zig" ]; then
      ZIG_DIR="$candidate"
      break
    fi
  done
fi
LINUX_PATH="$TOOLCHAIN_BIN:${ZIG_DIR:+$ZIG_DIR:}$PATH"
if [ "$(PATH="$LINUX_PATH" zig version 2>/dev/null)" != "$ZIG_VERSION" ]; then
  echo "error: the Linux agents need zig $ZIG_VERSION. Install mise, or put zig $ZIG_VERSION on PATH." >&2
  exit 1
fi

mkdir -p "$RES_DIR"
for arch in $LINUX_ARCHES; do
  target="$arch-unknown-linux-musl"
  echo "Building $HELPER_NAME ($target) -> $RES_DIR/${HELPER_NAME}-linux-$arch"
  ( cd "$CARGO_DIR" && PATH="$LINUX_PATH" cargo zigbuild --release -p wr-agent \
    --features terminal-state --target "$target" )
  cp -f "$OUT_ROOT/$target/release/$HELPER_NAME" "$RES_DIR/${HELPER_NAME}-linux-$arch"
done
