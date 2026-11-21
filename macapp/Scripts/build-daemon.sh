#!/bin/bash
#
# Builds the one `workroom` binary (ADR 0078: the CLI, and the daemon as `workroom serve`) and
# embeds it in the app bundle's Contents/Resources, then signs it with the same identity as the
# app. Run as a post-compile Xcode script phase (before Xcode's final code-sign) so the embedded
# binary is covered by the app signature — an unsigned or post-sign-modified helper fails
# notarization/Gatekeeper.
#
# Resources, NOT Contents/MacOS: "workroom" there would be the app executable "Workroom" on a
# case-insensitive filesystem, and the build would overwrite the GUI. It is the Go CLI's old path,
# so the `/usr/local/bin/workroom` link the app installs (`CommandLineInstaller`) doesn't change, and
# `PersistentSessionPaths.binaryURL(for:)` and `WorkroomCLI.bundledBinaryURL` both look there.
#
# Every build also puts a static Linux build per arch in Contents/Resources, for remote hosts. See
# the end of this file.
#
# Env vars provided by Xcode: SRCROOT, TARGET_BUILD_DIR, EXECUTABLE_FOLDER_PATH,
# UNLOCALIZED_RESOURCES_FOLDER_PATH, EXPANDED_CODE_SIGN_IDENTITY, ARCHS, DERIVED_FILE_DIR,
# CONFIGURATION, MARKETING_VERSION, WORKROOM_RELEASE_CHANNEL.
set -euo pipefail

HELPER_NAME="workroom"
CARGO_DIR="$(cd "${SRCROOT}/../vcs" && pwd)"
DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
DEST="${DEST_DIR}/${HELPER_NAME}"
# Where the daemon was until #681. See "One binary" below.
FORMER_DAEMON="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/workroomd"

# Stamped into the binary for `workroom version` and `update`'s channel logic, as build-helper.sh
# stamped the Go CLI until #681: the app's version (release.sh sets MARKETING_VERSION from the tag;
# a Debug build has project.yml's), and "nightly" for the Nightly build, empty otherwise. Read by
# `option_env!` in the commands module, which cargo rebuilds when either changes.
export WORKROOM_VERSION="${MARKETING_VERSION:-dev}"
export WORKROOM_RELEASE_CHANNEL="${WORKROOM_RELEASE_CHANNEL:-}"

# Xcode's build environment lacks cargo/rustup on PATH. `~/.local/bin` is on it for mise, which is
# how vcs/scripts/build-ghostty-vt.sh gets the pinned Zig on a cache miss — without it an engine-sha
# bump fails an Xcode-driven build with "no zig and no mise" while the same build from a terminal
# succeeds.
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: 'cargo' not found on PATH. Install Rust or adjust PATH in build-daemon.sh." >&2
  exit 1
fi

# `ARCHS` is a SPACE-SEPARATED LIST — a universal Release build passes "arm64 x86_64" — so this
# iterates rather than matching a single token, and hard-errors on anything unknown.
#
# This is not defensiveness for its own sake: build-helper.sh once `case`d the whole string and
# fell through to an arm64 default, so 23 shipped betas contained an arm64-only Go CLI inside a fat
# app. macapp/AGENTS.md records that any new universal Mac binary must reuse this iteration rather
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

# Homebrew's rust ships only the host arch's std, so cross-compiling needs rustup, or the build
# fails with a cryptic "can't find crate for `core`".
CARGO="cargo"
# The toolchain is mk/vcs.mk's VCS_RUST, the one source of truth: the shipped binary's notices
# describe that Rust's standard library and musl (#714, third-party/components.json pins them to
# it), and the daemon build identity hashes the compiler (#680), so a runner's newer `stable` would
# ship code the notices do not cover and hand every host's daemon off for nothing.
# WORKROOMD_RUST_TOOLCHAIN may name another for a Debug build; a Release or Nightly one refuses it.
PINNED_RUST="$(awk '$1 == "VCS_RUST" && $2 == ":=" {print $3}' "${SRCROOT}/../mk/vcs.mk")"
if [ -z "$PINNED_RUST" ]; then
  echo "error: cannot read VCS_RUST from mk/vcs.mk." >&2
  exit 1
fi
AGENT_TOOLCHAIN="${WORKROOMD_RUST_TOOLCHAIN:-$PINNED_RUST}"
if [ "${CONFIGURATION:-Debug}" != "Debug" ]; then
  # `|| true`: under pipefail a toolchain rustup does not have would end the script silently.
  shipped="$(rustup run "$AGENT_TOOLCHAIN" rustc --version 2>/dev/null | awk '{print $2}' || true)"
  if [ "$shipped" != "$PINNED_RUST" ]; then
    echo "error: a ${CONFIGURATION} build ships the daemon built by Rust $PINNED_RUST (mk/vcs.mk's VCS_RUST), which its third-party notices describe; '$AGENT_TOOLCHAIN' is ${shipped:-not installed}. Run 'rustup toolchain install $PINNED_RUST' and add its targets." >&2
    exit 1
  fi
fi
# ponytail: the 1.93 floor came from jj-lib, which the daemon no longer links (#266). It stays until
# the remaining crates' MSRV is checked. Xcode can expose an older default rustup toolchain than the
# terminal's Homebrew rust, so select the pinned toolchain when necessary.
if ! rustc --version | awk '{split($2,v,"."); exit !(v[1] > 1 || v[1] == 1 && v[2] >= 93)}'; then
  if ! rustup run "$AGENT_TOOLCHAIN" rustc --version 2>/dev/null | awk '{split($2,v,"."); exit !(v[1] > 1 || v[1] == 1 && v[2] >= 93)}'; then
    echo "error: workroomd needs Rust >= 1.93. Run 'rustup update $AGENT_TOOLCHAIN'." >&2
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
    echo "error: workroomd needs Rust >= 1.93. Run 'rustup toolchain install $AGENT_TOOLCHAIN', or set WORKROOMD_RUST_TOOLCHAIN to a compatible installed toolchain." >&2
    exit 1
  fi
  CARGO="rustup run $AGENT_TOOLCHAIN cargo"
fi

# Prefer rustup's toolchain whenever it is installed and new enough, even for a host-only build.
# The PATH above puts /opt/homebrew/bin first, and Homebrew's rustc (1.98.1) builds proc-macro
# dylibs that fail to load under the MACOSX_DEPLOYMENT_TARGET Xcode exports ("can't find crate for
# `thiserror_impl`"). vcs/scripts/build-apple.sh carried this pin (#234) until it was deleted (#266).
if [ "$CARGO" = "cargo" ] && command -v rustup >/dev/null 2>&1 \
  && rustup run "$AGENT_TOOLCHAIN" rustc --version 2>/dev/null | awk '{split($2,v,"."); exit !(v[1] > 1 || v[1] == 1 && v[2] >= 93)}'; then
  CARGO="rustup run $AGENT_TOOLCHAIN cargo"
fi

# Cargo resolves rustc through PATH even when rustup selected cargo. Pin the matching
# compiler so a Homebrew rustc cannot silently replace the cross-capable toolchain.
if [ "$CARGO" != "cargo" ]; then
  RUSTC="$(rustup which --toolchain "$AGENT_TOOLCHAIN" rustc)"
  export RUSTC
fi

echo "Building $HELPER_NAME (${TARGETS[*]}) -> $DEST"
mkdir -p "$DEST_DIR"

# Slices go to Xcode's intermediates dir, not `mktemp -d`, and cleanup is unconditional: the
# fallback can place them beside the helper inside the bundle, and a per-arch Mach-O stranded
# there by an interrupted run would be sealed into the app signature by a later single-arch build.
SLICE_DIR="${DERIVED_FILE_DIR:-$DEST_DIR}"
mkdir -p "$SLICE_DIR"
rm -f "$SLICE_DIR/${HELPER_NAME}-slice-"*
# The new binary is built here, beside `$DEST`, and renamed over it: never written into it. A
# running daemon (every persisted session's, and the one a hand-off replaces) executes `$DEST`, and
# macOS SIGKILLs a process whose signed binary changes under it ("Code Signature Invalid"). Writing
# in place ended every Dev session on each rebuild, before the app could hand the daemon off. A
# rename gives the new binary its own inode and leaves the running daemon its old one. Beside
# `$DEST`, not in `$SLICE_DIR`, because a rename cannot cross file systems.
STAGED="$DEST_DIR/.${HELPER_NAME}-staged"
rm -f "$STAGED"
trap 'rm -f "$SLICE_DIR/${HELPER_NAME}-slice-"* "$STAGED"' EXIT

# Where cargo actually puts the binary. NOT unconditionally `$CARGO_DIR/target`: an outer
# CARGO_TARGET_DIR redirects the build, and copying from the default path would then embed a
# STALE binary from the developer's tree while reporting a successful build. build-daemon_test.sh
# sets exactly that variable to keep its builds out of the working tree, so the bug it hid was
# its own assertions passing against a binary this script never produced.
OUT_ROOT="${CARGO_TARGET_DIR:-$CARGO_DIR/target}"

# One feature list for the Mac and Linux builds alike. Only the Mac daemon can be run here, and the
# build test asserts `terminal-state yes` on it; sharing the list is what extends that check to the
# Linux ELFs, which this Mac cannot run.
DAEMON_FEATURES="terminal-state"

SLICES=()
for target in "${TARGETS[@]}"; do
  # `terminal-state` is not optional for the app, whatever its name suggests. Without it the
  # daemon keeps no shadow copy of the screen, so a pane reattaching to a live session is repainted
  # with nothing — which is what shipping it off looked like: after quitting and relaunching, a
  # persisted terminal showed an empty pane with no prompt. It is a cargo feature only because it
  # links libghostty-vt, which a bare `cargo test` should not have to build.
  #
  # The library is cached per (engine sha, target) outside the repo, so only the first build of a
  # given pin pays for it; see vcs/scripts/build-ghostty-vt.sh.
  ( cd "$CARGO_DIR" && $CARGO build --release -p workroom --features "$DAEMON_FEATURES" --target "$target" )
  cp -f "$OUT_ROOT/$target/release/workroom" "$SLICE_DIR/${HELPER_NAME}-slice-$target"
  SLICES+=("$SLICE_DIR/${HELPER_NAME}-slice-$target")
done

if [ "${#SLICES[@]}" -eq 1 ]; then
  cp -f "${SLICES[0]}" "$STAGED"
else
  lipo -create "${SLICES[@]}" -output "$STAGED"
fi
mv -f "$STAGED" "$DEST"
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

# One binary (ADR 0078: no release ships two). A bundle an earlier build of this checkout made still
# holds the daemon it put in Contents/MacOS, and the app's signature would seal it in again beside
# the new one. Both names are this script's own outputs, at fixed paths inside the bundle Xcode is
# building, so nothing else's file is at either: the former daemon (`workroomd`, which no other
# phase writes) and, below, the former Linux daemons. A Dev daemon still running from the old file
# keeps its inode; the next launch hands it off to `$DEST` (`DaemonHandOff.mustMove`).
rm -f "$FORMER_DAEMON" "$(dirname "$FORMER_DAEMON")/.workroomd-staged" \
  "$(dirname "$FORMER_DAEMON")/workroomd-slice-"*

# Linux builds (issue #227). Workroom.app pushes the daemon to a remote box on first connect
# (docs/designs/remote-workrooms.md, Distribution Plan), so the bundle carries a static musl build
# for each Linux arch, named by what `uname -m` prints there.
#
# Both ship ALWAYS. A remote box's arch has nothing to do with the Mac's, so these do not follow
# `ARCHS`, and the ARCH_LIST rule above (for universal MAC binaries) does not apply to them.
#
# Resources, not MacOS, and not codesigned. codesign sees an ELF as data, and the app's own
# signature seals it like any other resource.
#
# Every configuration, Debug included: every build offers remote workrooms, and a host with no daemon
# needs one pushed from this bundle. Cargo caches both builds, so only the first costs a compile.
RES_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if ! command -v cargo-zigbuild >/dev/null 2>&1; then
  echo "error: the Linux daemons need cargo-zigbuild. Run 'cargo install cargo-zigbuild --locked'." >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "error: the Linux daemons need rustup (Homebrew rust cannot cross-compile)." >&2
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
  echo "error: the Linux daemons need zig $ZIG_VERSION. Install mise, or put zig $ZIG_VERSION on PATH." >&2
  exit 1
fi

mkdir -p "$RES_DIR"
for arch in $LINUX_ARCHES; do
  target="$arch-unknown-linux-musl"
  echo "Building $HELPER_NAME ($target) -> $RES_DIR/${HELPER_NAME}-linux-$arch"
  ( cd "$CARGO_DIR" && PATH="$LINUX_PATH" cargo zigbuild --release -p workroom \
    --features "$DAEMON_FEATURES" --target "$target" )
  cp -f "$OUT_ROOT/$target/release/workroom" "$RES_DIR/${HELPER_NAME}-linux-$arch"
  # Their names until #681 (see "One binary" above).
  rm -f "$RES_DIR/workroomd-linux-$arch"
done
