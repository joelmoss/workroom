#!/bin/bash
#
# Builds the `workroom` Go CLI and embeds it inside the app bundle's Resources, then
# signs it with the same identity as the app. Run as a post-compile Xcode script
# phase (before Xcode's final code-sign) so the embedded binary is covered by the
# app signature — an unsigned/post-sign-modified helper fails notarization/Gatekeeper.
#
# Env vars provided by Xcode: SRCROOT, TARGET_BUILD_DIR, UNLOCALIZED_RESOURCES_FOLDER_PATH,
# EXPANDED_CODE_SIGN_IDENTITY, ARCHS, MACOSX_DEPLOYMENT_TARGET, MARKETING_VERSION.
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

# Match the app's architecture(s). For an arm64-only MVP this is arm64; for a
# universal app, build each arch and lipo. Default to the host arch when ARCHS unset.
ARCH="${ARCHS:-$(uname -m)}"
case "$ARCH" in
  arm64) GOARCH=arm64 ;;
  x86_64) GOARCH=amd64 ;;
  *) echo "warn: unexpected ARCHS='$ARCH', defaulting to arm64" >&2; GOARCH=arm64 ;;
esac

mkdir -p "$HELPER_DIR"
# Stamp the embedded CLI with the app's version so `workroom version` (and channel/update logic)
# reports a real version instead of "dev". release.sh sets MARKETING_VERSION from the git tag; a
# local Debug build falls back to the project.yml default. goreleaser injects the same
# `main.version` for the standalone CLI, so the two stay consistent.
VERSION="${MARKETING_VERSION:-dev}"
# Bake the app's channel identity into the bundled CLI (issue #91): "nightly" for the Workroom
# Nightly build, empty otherwise. Matches the standalone `workroom-nightly` binary's -X main.channel.
CHANNEL="${WORKROOM_RELEASE_CHANNEL:-}"
echo "Building workroom helper ($GOARCH, version=$VERSION, channel=${CHANNEL:-<main>}) -> $HELPER"
( cd "$GO_MODULE_DIR" && \
  CGO_ENABLED=0 GOOS=darwin GOARCH="$GOARCH" \
  go build -trimpath -ldflags "-s -w -X main.version=${VERSION} -X main.channel=${CHANNEL}" -o "$HELPER" . )

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
