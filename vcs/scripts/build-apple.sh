#!/usr/bin/env bash
# Build the Workroom VCS Rust core into an xcframework + Swift bindings the macOS app consumes.
#
#   build-apple.sh              # arm64 (host) — for local dev on Apple Silicon
#   build-apple.sh --universal  # arm64 + x86_64 (release/distribution; needs rustup targets)
#   build-apple.sh --print-input-hash # print the output-cache key without building
#   build-apple.sh --check      # build nothing; exit 1 if the outputs are stale/missing
#
# Outputs into the local SwiftPM package vcs/swift/WrVcs (Package.swift is tracked; these two are
# gitignored + regenerated). Wrapping the static xcframework in an SPM binaryTarget namespaces its
# modulemap, avoiding the "Multiple commands produce include/module.modulemap" collision a raw
# framework dep hits against the other static xcframeworks (e.g. GhosttyKit).
#   vcs/swift/WrVcs/Frameworks/WrVcsFFI.xcframework   — static lib + FFI headers/modulemap
#   vcs/swift/WrVcs/Sources/WrVcs/wr_vcs_uniffi.swift — the idiomatic Swift API (module `WrVcs`)
#
# Re-running with unchanged inputs is a no-op: the inputs are hashed into a stamp beside the outputs
# (WR_VCS_FORCE=1 rebuilds regardless). Matters because app-build/app-test/app-release all depend on
# app-vcs, and CI restores the outputs from cache and must not then recompile the whole crate graph.
set -euo pipefail

vcs=$(cd "$(dirname "$0")/.." && pwd)   # vcs/
repo=$(cd "$vcs/.." && pwd)
self="$vcs/scripts/$(basename "$0")"    # absolute: $0 is relative to the *caller's* cwd, not $vcs
cd "$vcs"

LIBNAME=libwr_vcs_uniffi.a
universal=false
check_only=false
case "${1:-}" in
  --universal) universal=true ;;
  --check) check_only=true ;;
esac

PKG="$repo/vcs/swift/WrVcs"
XC="$PKG/Frameworks/WrVcsFFI.xcframework"
FFI="$PKG/Sources/wr_vcs_uniffiFFI/include"
GEN="$PKG/Sources/WrVcs"
# In Frameworks/ so it's covered by the same gitignore entry — and by CI's output cache.
STAMP="$PKG/Frameworks/.build-stamp"

# Everything that can change the *content* of the outputs: Rust sources, manifests + lockfile, this
# script, and the compiler. The arch flavour is deliberately NOT hashed — it's stamped as a separate
# field (below), because the two callers judge it differently: a build must not let a host-arch core
# satisfy --universal, while --check has no way to know which flavour was built and shouldn't care
# (a universal core is exactly as fresh as a host one). Hashing it made every `make app-release`
# stamp universal and then fail its own Xcode gate, which checks the host flavour.
input_hash() {
  {
    # Relative paths (cwd is vcs/) so the hash doesn't move when the repo does — every workroom
    # copy of the tree would otherwise rebuild from scratch.
    # Everything in crates/ EXCEPT the two the app's VCS library does not link — keep in step with
    # vcs/Cargo.toml's `members`. Deliberately a denylist: an ALLOWLIST of wr-vcs-uniffi's
    # dependency closure lets a crate later pulled into that closure go unhashed, so CI hits its
    # output cache, skips the build, and ships an xcframework older than its sources — with
    # --check passing on the same hash. Here a new crate is hashed by default; only mistakenly
    # EXCLUDING a linked crate reintroduces that risk, and forgetting to exclude one merely costs
    # a rebuild. CI calls this function too, so there is no second cache key to edit.
    find crates -type f -not -path '*/target/*' \
      -not -path 'crates/wr-agent/*' -not -path 'crates/wr-vcs-git/*' \
      -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    # Cargo.lock is hashed for the WHOLE workspace, so a dependency added to a crate excluded above
    # (wr-agent's `notify`) still moves this hash and forces one rebuild — even though nothing
    # wr-vcs-uniffi links changed. That is the cost of hashing the lockfile rather than resolving
    # the dependency closure, and it is the safe direction: see the denylist note above.
    shasum -a 256 Cargo.toml Cargo.lock
    if [ -d .cargo ]; then
      find .cargo -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    fi
    shasum -a 256 < "$self"   # content only: the path itself varies with how we were invoked
    rustc --version
    # `--universal` compiles with rustup's stable (see RUSTC below), which need not be the PATH
    # rustc above, so hash it too. For EVERY flavour, not only `--universal`: `--check` and CI's
    # `--print-input-hash` never pass the flag, and a hash that differed by flavour would fail the
    # Xcode gate after every `make app-release` (the trap described above input_hash). A rustup
    # update therefore also rebuilds a host core it did not compile, which is the safe direction.
    rustup run stable rustc --version 2>/dev/null || echo "rustup stable: none"
    # Flags change codegen without touching a single hashed file. Known remaining gap: a .cargo
    # config ABOVE vcs/ (cargo walks parents, this only reads vcs/.cargo).
    echo "RUSTFLAGS=${RUSTFLAGS:-}"
    echo "CARGO_ENCODED_RUSTFLAGS=${CARGO_ENCODED_RUSTFLAGS:-}"
  } | shasum -a 256 | awk '{print $1}'
}

# Stamp format: line 1 = input_hash, line 2 = `universal=<bool>` (absent in the pre-two-field
# format, which simply reads as a hash mismatch and rebuilds once).
WANT=$(input_hash)
if [ "${1:-}" = "--print-input-hash" ]; then
  echo "$WANT"
  exit 0
fi
fresh=false          # outputs exist and match the current inputs
stamp_universal=false # ...and were built with --universal
if [ -d "$XC" ] && [ -f "$GEN/wr_vcs_uniffi.swift" ] && [ -f "$FFI/wr_vcs_uniffiFFI.h" ] &&
  [ -f "$STAMP" ] && [ "$(sed -n 1p "$STAMP")" = "$WANT" ]; then
  fresh=true
  [ "$(sed -n 2p "$STAMP")" = "universal=true" ] && stamp_universal=true
fi

# A build request is satisfied only if the stamped flavour covers it; --check ignores the flavour.
up_to_date=false
if $fresh && { ! $universal || $stamp_universal; }; then
  up_to_date=true
fi

# --check reports, never builds. It's the Xcode pre-build gate (see macapp/project.yml): an
# Xcode-driven build (⌘R/⌘U) or a raw `xcodebuild` has no `app-vcs` prerequisite, so it would
# happily link whatever core was built last — silently testing a stale engine (that cost a real
# debugging session: conflicted files read as `.modified` after a merge brought in a jj fix).
# Deliberately does NOT rebuild: SPM extracts a binaryTarget's xcframework before target build
# phases run, so replacing the .a here wouldn't reach *this* build's link anyway — better to stop
# with an actionable message than to look fixed while still linking the old core.
if $check_only; then
  $fresh && { echo "up to date: $XC"; exit 0; }
  echo "stale: the Rust VCS core doesn't match vcs/ — run 'make app-vcs'" >&2
  exit 1
fi

if [ -z "${WR_VCS_FORCE:-}" ] && $up_to_date; then
  echo "up to date: $XC (inputs unchanged; WR_VCS_FORCE=1 to rebuild)"
  exit 0
fi

# Build the cdylib+staticlib+bindgen bin (release). For universal, also cross-compile x86_64 and
# lipo the two staticlibs; otherwise use the host (arm64) staticlib directly.
cargo build --release -p wr-vcs-uniffi
LIB="target/release/$LIBNAME"
if $universal; then
  # Universal needs both arch stds. Homebrew rust ships only the host arch, so cross-compile via
  # rustup (which manages cross targets): `rustup target add x86_64-apple-darwin aarch64-apple-darwin`.
  # jj-lib's MSRV is 1.93, so rustup's `stable` must be >= that (a stale toolchain fails cryptically).
  need="1.93.0"
  have=$(rustup run stable rustc --version 2>/dev/null | awk '{print $2}')
  if [ -z "$have" ] || [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" != "$need" ]; then
    echo "error: --universal needs rustup 'stable' >= $need (have '${have:-none}'). Run 'rustup update stable && rustup target add x86_64-apple-darwin aarch64-apple-darwin'." >&2
    exit 1
  fi
  # `rustup run stable` selects stable's cargo, NOT its rustc: cargo takes `rustc` from PATH, and the
  # Makefile puts /opt/homebrew/bin first. With Homebrew rust installed, the x86_64 build therefore
  # ran Homebrew's compiler, which ships only the host std, and failed with "can't find crate for
  # `core`" while `rustup target list --installed` listed the target. Pin stable's own rustc, as
  # macapp/Scripts/build-agent.sh does. CI has no Homebrew rust, so it never saw this.
  RUSTC="$(rustup which --toolchain stable rustc)"
  export RUSTC
  rustup run stable cargo build --release -p wr-vcs-uniffi --target x86_64-apple-darwin
  rustup run stable cargo build --release -p wr-vcs-uniffi --target aarch64-apple-darwin
  mkdir -p target/apple
  lipo -create \
    "target/aarch64-apple-darwin/release/$LIBNAME" \
    "target/x86_64-apple-darwin/release/$LIBNAME" \
    -output "target/apple/$LIBNAME"
  LIB="target/apple/$LIBNAME"
fi

# Generate Swift bindings from the built dylib (library mode; must run from the workspace dir).
BIND="target/apple/bindings"
rm -rf "$BIND"; mkdir -p "$BIND"
./target/release/uniffi-bindgen generate \
  --library "target/release/libwr_vcs_uniffi.dylib" \
  --language swift --out-dir "$BIND" --no-format

# Library-ONLY xcframework (no -headers): a headers-bearing static xcframework copies its
# module.modulemap into the shared Debug/include/, colliding with GhosttyKit's identically-named
# one ("Multiple commands produce include/module.modulemap"). The importable C module is instead
# provided by the SPM C target `wr_vcs_uniffiFFI` (headers below), whose modulemap SPM namespaces.
mkdir -p "$PKG/Frameworks"
rm -f "$STAMP"   # outputs about to be replaced: don't leave a stamp vouching for a half-built set
rm -rf "$XC"
xcodebuild -create-xcframework -library "$LIB" -output "$XC" >/dev/null

# FFI header + modulemap → the wr_vcs_uniffiFFI C target's include dir (module `wr_vcs_uniffiFFI`,
# which the generated Swift imports).
mkdir -p "$FFI"
cp "$BIND/wr_vcs_uniffiFFI.h" "$FFI/"
cp "$BIND/wr_vcs_uniffiFFI.modulemap" "$FFI/module.modulemap"

# Generated Swift API → the WrVcs target (module `WrVcs`).
mkdir -p "$GEN"
cp "$BIND/wr_vcs_uniffi.swift" "$GEN/wr_vcs_uniffi.swift"

# Outputs complete — vouch for them. $WANT (the PRE-build hash), not a re-hash: re-hashing stamps
# a source edit made DURING the build as though it had been compiled, and every later run and
# --check then accepts those stale outputs forever. Stamping the inputs we actually built from
# fails safe — a mid-build edit simply mismatches on the next run and rebuilds.
{ echo "$WANT"; echo "universal=$universal"; } > "$STAMP"

echo "built: $XC"
echo "       $GEN/wr_vcs_uniffi.swift"
