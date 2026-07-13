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
set -euo pipefail

vcs=$(cd "$(dirname "$0")/.." && pwd)   # vcs/
repo=$(cd "$vcs/.." && pwd)
cd "$vcs"

LIBNAME=libwr_vcs_uniffi.a
universal=false
[[ "${1:-}" == "--universal" ]] && universal=true

# Build the cdylib+staticlib+bindgen bin (release). For universal, also cross-compile x86_64 and
# lipo the two staticlibs; otherwise use the host (arm64) staticlib directly.
cargo build --release -p wr-vcs-uniffi
LIB="target/release/$LIBNAME"
if $universal; then
  cargo build --release -p wr-vcs-uniffi --target x86_64-apple-darwin
  cargo build --release -p wr-vcs-uniffi --target aarch64-apple-darwin
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

PKG="$repo/vcs/swift/WrVcs"

# Library-ONLY xcframework (no -headers): a headers-bearing static xcframework copies its
# module.modulemap into the shared Debug/include/, colliding with GhosttyKit's identically-named
# one ("Multiple commands produce include/module.modulemap"). The importable C module is instead
# provided by the SPM C target `wr_vcs_uniffiFFI` (headers below), whose modulemap SPM namespaces.
XC="$PKG/Frameworks/WrVcsFFI.xcframework"
mkdir -p "$PKG/Frameworks"
rm -rf "$XC"
xcodebuild -create-xcframework -library "$LIB" -output "$XC" >/dev/null

# FFI header + modulemap → the wr_vcs_uniffiFFI C target's include dir (module `wr_vcs_uniffiFFI`,
# which the generated Swift imports).
FFI="$PKG/Sources/wr_vcs_uniffiFFI/include"
mkdir -p "$FFI"
cp "$BIND/wr_vcs_uniffiFFI.h" "$FFI/"
cp "$BIND/wr_vcs_uniffiFFI.modulemap" "$FFI/module.modulemap"

# Generated Swift API → the WrVcs target (module `WrVcs`).
GEN="$PKG/Sources/WrVcs"
mkdir -p "$GEN"
cp "$BIND/wr_vcs_uniffi.swift" "$GEN/wr_vcs_uniffi.swift"

echo "built: $XC"
echo "       $GEN/wr_vcs_uniffi.swift"
