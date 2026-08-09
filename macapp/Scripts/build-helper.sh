#!/bin/bash
#
# Builds the `workroom` Go CLI and embeds it inside the app bundle's Resources, then
# signs it with the same identity as the app. Run as a post-compile Xcode script
# phase (before Xcode's final code-sign) so the embedded binary is covered by the
# app signature — an unsigned/post-sign-modified helper fails notarization/Gatekeeper.
#
# Env vars provided by Xcode: SRCROOT, TARGET_BUILD_DIR, UNLOCALIZED_RESOURCES_FOLDER_PATH,
# EXPANDED_CODE_SIGN_IDENTITY, ARCHS, DERIVED_FILE_DIR, MACOSX_DEPLOYMENT_TARGET, MARKETING_VERSION.
set -euo pipefail

# The Go module lives one level up from macapp/ (this repo's root).
GO_MODULE_DIR="$(cd "${SRCROOT}/.." && pwd)"
# Embed in Contents/Resources (located at runtime via Bundle.main.url(forResource:)).
# It must NOT go in Contents/MacOS as "workroom": the app executable is "Workroom", and
# macOS's case-insensitive filesystem would treat the two as the same file — the helper
# would overwrite the app binary (a 10 MB Go CLI masquerading as the GUI).
HELPER_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
HELPER="${HELPER_DIR}/workroom"

# Xcode's build environment usually lacks Homebrew/Go on PATH.
export PATH="/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
if ! command -v go >/dev/null 2>&1; then
  echo "error: 'go' not found on PATH. Install Go or adjust PATH in build-helper.sh." >&2
  exit 1
fi

# Match the app's architecture(s). `ARCHS` is a SPACE-SEPARATED LIST — a universal Release build
# passes "arm64 x86_64" — so this must iterate, not match a single token.
#
# It used to `case "$ARCHS"` against `arm64` / `x86_64` and fall through to a `warn:` default of
# arm64 for anything else. That default is exactly what a universal build hit, so the shipped
# Release app was fat while the CLI inside it was arm64-only, with the warning buried in xcodebuild
# output. The app drives *every* workroom operation through this binary, so on an Intel Mac it
# launched and then failed at everything. Unknown archs are now a hard error for the same reason.
ARCH_LIST="${ARCHS:-$(uname -m)}"
GOARCHES=()
for arch in $ARCH_LIST; do
  case "$arch" in
    arm64) GOARCHES+=(arm64) ;;
    x86_64) GOARCHES+=(amd64) ;;
    *) echo "error: unsupported arch '$arch' in ARCHS='$ARCH_LIST'." >&2; exit 1 ;;
  esac
done
# `${ARCHS:-...}` only substitutes when unset or empty, so a whitespace-only ARCHS survives the
# default and yields no iterations. On bash 3.2 (what /bin/bash still is on macOS) an empty array
# under `set -u` is "unbound", so without this the script would die on `${GOARCHES[*]}` below with
# an unreadable error instead of the deliberate one.
if [ "${#GOARCHES[@]}" -eq 0 ]; then
  echo "error: ARCHS='$ARCH_LIST' yielded no architectures to build." >&2
  exit 1
fi

mkdir -p "$HELPER_DIR"
# Stamp the embedded CLI with the app's version so `workroom version` (and channel/update logic)
# reports a real version instead of "dev". release.sh sets MARKETING_VERSION from the git tag; a
# local Debug build falls back to the project.yml default. goreleaser injects the same
# `main.version` for the standalone CLI, so the two stay consistent.
VERSION="${MARKETING_VERSION:-dev}"
# Bake the app's channel identity into the bundled CLI (issue #91): "nightly" for the Workroom
# Nightly build, empty otherwise. Matches the standalone `workroom-nightly` binary's -X main.channel.
CHANNEL="${WORKROOM_RELEASE_CHANNEL:-}"
echo "Building workroom helper (${GOARCHES[*]}, version=$VERSION, channel=${CHANNEL:-<main>}) -> $HELPER"
LDFLAGS="-s -w -X main.version=${VERSION} -X main.channel=${CHANNEL}"
if [ "${#GOARCHES[@]}" -eq 1 ]; then
  ( cd "$GO_MODULE_DIR" && \
    CGO_ENABLED=0 GOOS=darwin GOARCH="${GOARCHES[0]}" \
    go build -trimpath -ldflags "$LDFLAGS" -o "$HELPER" . )
else
  # Build each slice to its own file, then lipo. CGO is off, so cross-compiling is just a GOARCH
  # change — no toolchain per arch.
  #
  # Slices go to Xcode's intermediates dir (or beside the helper as a fallback), NOT `mktemp -d`:
  # a build script should keep its intermediates in the build tree, and the system temp dir isn't
  # writable under every environment this runs in.
  #
  # The fallback can put them inside the bundle's Resources, so cleanup must be unconditional. If
  # the first `go build` succeeds and the second dies (or the phase is interrupted), a cleanup that
  # only ran after a successful `lipo` would leave an unsigned per-arch Mach-O in Resources — and a
  # later single-arch build never touches it, so the final app signature seals it in. Hence a trap,
  # plus a sweep of stale slices from a previous interrupted run before we start.
  SLICE_DIR="${DERIVED_FILE_DIR:-$HELPER_DIR}"
  mkdir -p "$SLICE_DIR"
  rm -f "$SLICE_DIR"/workroom-slice-*
  trap 'rm -f "$SLICE_DIR"/workroom-slice-*' EXIT
  SLICES=()
  for goarch in "${GOARCHES[@]}"; do
    ( cd "$GO_MODULE_DIR" && \
      CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" \
      go build -trimpath -ldflags "$LDFLAGS" -o "$SLICE_DIR/workroom-slice-$goarch" . )
    SLICES+=("$SLICE_DIR/workroom-slice-$goarch")
  done
  lipo -create "${SLICES[@]}" -output "$HELPER"
  rm -f "${SLICES[@]}"
  trap - EXIT
fi

# A single-arch build must also clear slices a previous multi-arch run may have stranded here —
# switching Release -> Debug is exactly the sequence that would otherwise leave one behind.
rm -f "$HELPER_DIR"/workroom-slice-*

# Sign the helper. Use the app's identity + hardened runtime + timestamp when a real
# Developer ID is present; otherwise ad-hoc sign for local dev.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ] || [ -z "$IDENTITY" ]; then
  echo "Ad-hoc signing helper (local dev build)"
  codesign --force --sign - "$HELPER"
else
  echo "Signing helper with $IDENTITY (hardened runtime + timestamp)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HELPER"
fi
