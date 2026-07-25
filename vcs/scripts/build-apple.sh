#!/usr/bin/env bash
# Build the Workroom VCS Rust core into an xcframework + Swift bindings the macOS app consumes.
#
#   build-apple.sh              # arm64 (host) — for local dev on Apple Silicon
#   build-apple.sh --universal  # arm64 + x86_64 (release/distribution; needs rustup targets)
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
[[ "${1:-}" == "--universal" ]] && universal=true

PKG="$repo/vcs/swift/WrVcs"
XC="$PKG/Frameworks/WrVcsFFI.xcframework"
FFI="$PKG/Sources/wr_vcs_uniffiFFI/include"
GEN="$PKG/Sources/WrVcs"
# In Frameworks/ so it's covered by the same gitignore entry — and by CI's output cache.
STAMP="$PKG/Frameworks/.build-stamp"

# Everything that can change the outputs: Rust sources, manifests + lockfile, this script, the
# compiler, and the arch flavour (a host-arch build must never satisfy a --universal request).
input_hash() {
  {
    # Relative paths (cwd is vcs/) so the hash doesn't move when the repo does — every workroom
    # copy of the tree would otherwise rebuild from scratch.
    find . -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
      -not -path './target/*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    shasum -a 256 < "$self"   # content only: the path itself varies with how we were invoked
    rustc --version
    # Tolerate a missing rustup here so the friendlier MSRV error below still gets to fire.
    if $universal; then rustup run stable rustc --version 2>/dev/null || echo "rustup: none"; fi
    echo "universal=$universal"
  } | shasum -a 256 | awk '{print $1}'
}

WANT=$(input_hash)
if [ -z "${WR_VCS_FORCE:-}" ] && [ -d "$XC" ] && [ -f "$GEN/wr_vcs_uniffi.swift" ] &&
  [ -f "$FFI/wr_vcs_uniffiFFI.h" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
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

# Outputs complete — vouch for them. Re-hashed rather than reusing $WANT so a source edit made
# mid-build doesn't get stamped as built.
input_hash > "$STAMP"

echo "built: $XC"
echo "       $GEN/wr_vcs_uniffi.swift"
