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
# Env vars provided by Xcode: SRCROOT, TARGET_BUILD_DIR, EXECUTABLE_FOLDER_PATH,
# EXPANDED_CODE_SIGN_IDENTITY, ARCHS, DERIVED_FILE_DIR.
set -euo pipefail

HELPER_NAME="wr-agent"
CARGO_DIR="$(cd "${SRCROOT}/../vcs" && pwd)"
DEST_DIR="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
DEST="${DEST_DIR}/${HELPER_NAME}"

# Xcode's build environment lacks cargo/rustup on PATH.
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
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
if [ "${#TARGETS[@]}" -gt 1 ] || [ "${TARGETS[0]}" != "$(rustc -vV | awk '/^host:/{print $2}')" ]; then
  if ! command -v rustup >/dev/null 2>&1; then
    echo "error: cross-compiling $HELPER_NAME needs rustup (Homebrew rust cannot). Install rustup, then 'rustup target add ${TARGETS[*]}'." >&2
    exit 1
  fi
  for target in "${TARGETS[@]}"; do
    if ! rustup target list --installed --toolchain stable 2>/dev/null | grep -qx "$target"; then
      echo "error: rustup target '$target' is not installed. Run 'rustup target add $target'." >&2
      exit 1
    fi
  done
  CARGO="rustup run stable cargo"
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

SLICES=()
for target in "${TARGETS[@]}"; do
  ( cd "$CARGO_DIR" && $CARGO build --release -p wr-agent --target "$target" )
  cp -f "$CARGO_DIR/target/$target/release/$HELPER_NAME" "$SLICE_DIR/${HELPER_NAME}-slice-$target"
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
