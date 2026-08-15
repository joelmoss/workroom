#!/bin/bash
#
# Build a Developer ID-signed, notarized, stapled Workroom.dmg installer for distribution
# (the app inside is notarized + stapled too). Requires `create-dmg` (brew install create-dmg).
#
# Notarization auth, either:
#   - Local: store credentials in a keychain profile (an app-specific password from
#     https://appleid.apple.com, NOT your Apple ID password), then run the script:
#
#       xcrun notarytool store-credentials "workroom-notary" \
#           --apple-id "you@example.com" \
#           --team-id  B898J443L9 \
#           --password "abcd-efgh-ijkl-mnop"
#
#   - CI / API key: set NOTARY_KEY_PATH (App Store Connect .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID.
#
# Optional — Sentry dSYM upload (so release crash reports symbolicate): install sentry-cli
# (brew install getsentry/tools/sentry-cli) and set SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT.
# Absent any of them the upload step skips; it never blocks a release.
#
# Then: macapp/Scripts/release.sh
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-workroom-notary}"
MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="${MACAPP_DIR}/WorkroomApp.xcodeproj"
BUILD="${MACAPP_DIR}/build/release"

# Which build identity to ship (issue #91). Release = the main "Workroom" app (stable/pre chosen at
# runtime); Nightly = the side-by-side "Workroom Nightly" app. The exported product name (and thus
# the .app/.dmg names) follows PRODUCT_NAME, which the config sets in project.yml.
CONFIGURATION="${CONFIGURATION:-Release}"
case "$CONFIGURATION" in
  Release) APP_NAME="Workroom" ;;
  Nightly) APP_NAME="Workroom Nightly" ;;
  *) echo "error: unsupported CONFIGURATION '$CONFIGURATION' (want Release or Nightly)." >&2; exit 1 ;;
esac

ARCHIVE="${BUILD}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD}/export"
APP="${EXPORT_DIR}/${APP_NAME}.app"
ZIP="${BUILD}/${APP_NAME}.zip"
DMG="${BUILD}/${APP_NAME}.dmg"

export PATH="/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# Run `xcrun notarytool <subcommand> …` with whichever auth is configured: an App Store
# Connect API key when NOTARY_KEY_PATH is set (CI: --key/--key-id/--issuer), else a local
# keychain profile (NOTARY_PROFILE, default "workroom-notary"; see the store-credentials note).
notarytool_auth() {
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    xcrun notarytool "$@" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  else
    xcrun notarytool "$@" --keychain-profile "$PROFILE"
  fi
}

# Submit a container (.zip/.dmg) and wait. NOTE: `notarytool submit --wait` exits 0 even when
# the result is Invalid, so we parse the final status ourselves; on anything but Accepted we
# dump Apple's per-file notary log (which states exactly what was rejected) and abort — never
# proceed to staple a ticket that was never issued.
notarize() {
  local out id status
  out="$(notarytool_auth submit "$1" --wait 2>&1)" || true
  echo "$out"
  id="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*id: \(.*\)$/\1/p' | head -1)"
  status="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*status: \(.*\)$/\1/p' | head -1)"
  if [ "$status" != "Accepted" ]; then
    echo "error: notarization returned '${status:-unknown}' for $(basename "$1")." >&2
    if [ -n "$id" ]; then
      echo "--- notary log ($id) ---" >&2
      notarytool_auth log "$id" >&2 || true
    fi
    exit 1
  fi
}

# ALWAYS regenerate, like every `make app-*` target does — never gate on the directory existing.
# `.xcodeproj/` is gitignored EXCEPT the tracked `project.xcworkspace/.../Package.resolved` (see
# .gitignore), so a fresh CI checkout already has the bundle DIRECTORY without a `project.pbxproj`
# in it. A `[ ! -d "$PROJ" ]` guard therefore skipped generation and xcodebuild died with
# "missing its project.pbxproj file" — which is exactly how nightly 2.0.0-nightly.576 failed.
echo "Generating Xcode project…"
( cd "$MACAPP_DIR" && xcodegen generate )

# Version for this build. CI passes the exact tag via $VERSION; locally we fall back to the
# latest tag. CFBundleVersion is the commit count — monotonic, so Sparkle always treats a newer
# release as an upgrade. Both values feed the appcast item (see Scripts/appcast.sh).
RAW_VERSION="${VERSION:-$(git -C "$MACAPP_DIR/.." describe --tags --always 2>/dev/null || echo 0.0.0)}"
SHORT_VERSION="${RAW_VERSION#v}"
BUILD_NUMBER="$(git -C "$MACAPP_DIR/.." rev-list --count HEAD 2>/dev/null || echo 1)"

# Archive + export with the Developer ID method (NOT a plain `build`): exportArchive re-signs
# the app AND all nested code — Sparkle's XPC services + Autoupdate/Updater helpers, the embedded
# Go helper — with our Developer ID, hardened runtime, and a secure timestamp. A plain `build`
# leaves nested helpers without a timestamp (and injects get-task-allow), which notarization
# rejects. Archiving also produces a distribution build with get-task-allow omitted.
echo "==> Archiving $CONFIGURATION ($APP_NAME) $SHORT_VERSION ($BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project "$PROJ" -scheme WorkroomApp -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD" \
  -clonedSourcePackagesDirPath "$BUILD/SourcePackages" \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$SHORT_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

# Upload dSYMs to Sentry so release crashes symbolicate. The archive bundles them in
# Workroom.xcarchive/dSYMs/ (the app's, plus the from-source Sentry frameworks'). Optional and
# non-fatal, like the Sparkle signing below: runs only when sentry-cli is installed and
# SENTRY_AUTH_TOKEN/SENTRY_ORG/SENTRY_PROJECT are set, else it skips with a note. We do this right
# after archiving — symbols are tied to the compiled binary, not to signing/notarization — and a
# symbol-upload hiccup must never block shipping an otherwise-good build.
# Under GitHub Actions every branch below annotates the run summary: `::notice::` when symbols really
# uploaded, `::warning::` when they didn't. A plain echo into a 2000-line log is what let the nightly
# ship unsymbolicated for weeks (the app frames in WORKROOM-2B were three unnamed addresses), and a
# skip-only warning still wouldn't prove the happy path — so both directions are stated.
if [ -n "${SENTRY_AUTH_TOKEN:-}" ] && [ -n "${SENTRY_ORG:-}" ] && [ -n "${SENTRY_PROJECT:-}" ]; then
  if command -v sentry-cli >/dev/null 2>&1; then
    echo "==> Uploading dSYMs to Sentry ($SENTRY_ORG/$SENTRY_PROJECT)"
    if sentry-cli debug-files upload --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "${ARCHIVE}/dSYMs"; then
      echo "${GITHUB_ACTIONS:+::notice::}Sentry dSYM upload succeeded ($SENTRY_ORG/$SENTRY_PROJECT)."
    else
      echo "${GITHUB_ACTIONS:+::warning::}Sentry dSYM upload failed; continuing release." >&2
    fi
  else
    echo "${GITHUB_ACTIONS:+::warning::}sentry-cli not found; skipping Sentry dSYM upload (brew install getsentry/tools/sentry-cli)." >&2
  fi
else
  echo "${GITHUB_ACTIONS:+::warning::}SENTRY_AUTH_TOKEN/SENTRY_ORG/SENTRY_PROJECT unset; skipping Sentry dSYM upload." >&2
fi

EXPORT_PLIST="${BUILD}/ExportOptions.plist"
cat >"$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>B898J443L9</string>
</dict>
</plist>
PLIST

echo "==> Exporting (Developer ID; re-signs nested code with a secure timestamp)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

# A release must be universal all the way down. This is asserted, not assumed, because it silently
# regressed once: `ARCHS` is a space-separated list ("arm64 x86_64") and build-helper.sh used to
# match it as a single token, falling back to an arm64-only Go build with nothing but a `warn:` in
# the xcodebuild log. The result shipped as a fat app wrapping a thin CLI — and since the app drives
# every workroom operation through that CLI, it launched fine on an Intel Mac and then failed at
# everything. Nothing downstream catches this: codesign, notarization and Gatekeeper are all happy
# with a thin nested binary.
echo "==> Verifying architectures (app + embedded CLI)"
check_universal() {
  local label="$1" path="$2" archs
  # Distinguish the three ways this can go wrong. Collapsing them into one "missing the arm64 slice"
  # message sends whoever hits it at 2am hunting an architecture problem that isn't one.
  command -v lipo >/dev/null 2>&1 || { echo "error: 'lipo' not on PATH — cannot verify $label." >&2; exit 1; }
  [ -f "$path" ] || { echo "error: $label not found at $path." >&2; exit 1; }
  archs="$(lipo -archs "$path" 2>/dev/null || true)"
  [ -n "$archs" ] || { echo "error: $label is not a Mach-O binary (lipo read no architectures) — $path" >&2; exit 1; }
  for want in arm64 x86_64; do
    case " $archs " in
      *" $want "*) ;;
      *) echo "error: $label is missing the $want slice (has: ${archs:-none}) — $path" >&2; exit 1 ;;
    esac
  done
  echo "    $label: $archs"
}
check_universal "app binary" "$APP/Contents/MacOS/${APP_NAME}"
check_universal "embedded workroom CLI" "$APP/Contents/Resources/workroom"

# Naming only those two would leave the invariant narrower than the sentence above claims: Sparkle
# ships XPC services, an Autoupdate tool and an Updater app, and notarization is just as happy with
# a thin one of those. So sweep EVERY Mach-O in the bundle. `file` decides what is executable code,
# rather than a path allowlist that a future dependency silently escapes.
echo "    sweeping all nested Mach-O binaries…"
while IFS= read -r macho; do
  case "$macho" in
    "$APP/Contents/MacOS/${APP_NAME}" | "$APP/Contents/Resources/workroom") continue ;;
  esac
  check_universal "nested: ${macho#"$APP/"}" "$macho"
done < <(find "$APP" -type f -perm -u+x -exec sh -c 'file -b "$1" | grep -q "Mach-O" && echo "$1"' _ {} \;)

# Ghostty's shell integration reaches the engine's `+action` CLI through Contents/MacOS/ghostty, a
# relative symlink to the app binary (created by the "Symlink ghostty" build phase). The sweep above
# cannot see it — `find -type f` does not match symlinks — and nothing else in the pipeline would
# notice it missing, because it fails exactly the way this whole area fails: silently. `ssh-terminfo`
# users would just quietly re-push terminfo on every connect. So assert it here, on the artifact.
echo "==> Verifying the ghostty CLI symlink"
GHOSTTY_LINK="$APP/Contents/MacOS/ghostty"
[ -L "$GHOSTTY_LINK" ] \
  || { echo "error: $GHOSTTY_LINK is missing or not a symlink — shell integration cannot reach '+ssh-cache'." >&2; exit 1; }
GHOSTTY_TARGET="$(readlink "$GHOSTTY_LINK")"
case "$GHOSTTY_TARGET" in
  /*) echo "error: ghostty symlink is absolute ($GHOSTTY_TARGET); it must be relative or it breaks once the bundle is copied or mounted from the DMG." >&2; exit 1 ;;
esac
[ "$GHOSTTY_TARGET" = "$APP_NAME" ] \
  || { echo "error: ghostty symlink points at '$GHOSTTY_TARGET', expected '$APP_NAME'." >&2; exit 1; }
# The one check that proves function rather than packaging: run the shipped artifact. `+ssh-cache`
# with no arguments lists the cache and exits 0 even when empty. Uses a throwaway XDG_STATE_HOME so
# a release never reads or writes the release engineer's own ssh terminfo cache.
GHOSTTY_PROBE_STATE="$(mktemp -d)"
# Guard the emptiness explicitly rather than trusting `set -e` to have caught a failed mktemp: an
# empty value would make this `XDG_STATE_HOME=` — which is not "isolated", it is a fallback to the
# release engineer's REAL ~/.local/state, the precise thing the temp dir exists to avoid.
[ -n "$GHOSTTY_PROBE_STATE" ] && [ -d "$GHOSTTY_PROBE_STATE" ] \
  || { echo "error: could not create a temp XDG_STATE_HOME to probe the ghostty CLI." >&2; exit 1; }
ghostty_probe_rc=0
XDG_STATE_HOME="$GHOSTTY_PROBE_STATE" "$GHOSTTY_LINK" +ssh-cache >/dev/null 2>&1 || ghostty_probe_rc=$?
rm -rf "$GHOSTTY_PROBE_STATE"
[ "$ghostty_probe_rc" -eq 0 ] \
  || { echo "error: shipped ghostty cannot dispatch '+ssh-cache' — the libghostty action layer is broken." >&2; exit 1; }
echo "    ghostty -> $GHOSTTY_TARGET (relative, dispatches +ssh-cache)"

echo "==> Verifying signatures"
codesign --verify --strict --verbose=2 "$APP"
echo "--- embedded helper ---"
codesign -dv --verbose=4 "$APP/Contents/Resources/workroom" 2>&1 \
  | grep -iE "Authority|TeamIdentifier|flags|Timestamp" || true

echo "==> Notarizing app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"

echo "==> Stapling app + Gatekeeper assessment"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP" || true

# Package the notarized + stapled app into a drag-to-Applications DMG, sign it with the same
# Developer ID, then notarize + staple the DMG so it opens with no Gatekeeper prompt. The
# stapled app lives inside a stapled DMG, so first launch is clean even offline.
echo "==> Building DMG installer"
command -v create-dmg >/dev/null 2>&1 \
  || { echo "error: 'create-dmg' not found on PATH. Install it (brew install create-dmg)." >&2; exit 1; }
STAGE="${BUILD}/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
create-dmg \
  --volname "$APP_NAME" \
  --window-size 660 400 --icon-size 100 \
  --icon "${APP_NAME}.app" 160 185 \
  --app-drop-link 500 185 \
  --hide-extension "${APP_NAME}.app" \
  --codesign "Developer ID Application" \
  "$DMG" "$STAGE"

echo "==> Notarizing + stapling DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true

# EdDSA-sign the DMG for Sparkle and record the fields the appcast needs (Scripts/appcast.sh
# turns these into a feed item). CI passes the private key via $SPARKLE_PRIVATE_KEY; locally
# sign_update falls back to the key `generate_keys` stored in your login keychain. The EdDSA
# `sign_update` ships in the Sparkle SPM package's artifacts (not the deprecated old_dsa_scripts).
#
# This is a 3-way outcome, not a pass/fail: no key configured is intentional and must stay silent;
# sign_update missing under SourcePackages is a packaging regression (Sparkle SPM relocated/renamed
# it before) and must be loud, exactly like the Sentry dSYM block above — a plain skip-only note is
# what let a signing regression ship a DMG with no matching appcast item and no one notice. So the
# fields file is now ALWAYS written, carrying an explicit SPARKLE_STATUS that Scripts/appcast.sh
# branches on, instead of the file's mere presence standing in for "signed".
SIGN_UPDATE="$(find "$BUILD/SourcePackages" -type f -name sign_update -not -path '*/old_dsa_scripts/*' 2>/dev/null | head -1 || true)"
SPARKLE_STATUS=""
SIG_ATTRS=""
if [ -z "$SIGN_UPDATE" ]; then
  SPARKLE_STATUS="missing-tool"
  echo "${GITHUB_ACTIONS:+::warning::}Sparkle's sign_update not found under SourcePackages; DMG will not be EdDSA-signed (packaging regression?)." >&2
elif [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "==> EdDSA-signing the DMG for Sparkle (provided key)"
  # Use --ed-key-file: the -s key-string flag is deprecated and now errors. The secret holds the
  # same base64 the keychain export (generate_keys -x) produces, which --ed-key-file reads.
  SPARKLE_KEYFILE="$(mktemp)"
  printf '%s' "$SPARKLE_PRIVATE_KEY" >"$SPARKLE_KEYFILE"
  SIG_ATTRS="$("$SIGN_UPDATE" "$DMG" --ed-key-file "$SPARKLE_KEYFILE")"
  rm -f "$SPARKLE_KEYFILE"
  SPARKLE_STATUS="signed"
elif SIG_ATTRS="$("$SIGN_UPDATE" "$DMG" 2>/dev/null)"; then
  echo "==> EdDSA-signed the DMG for Sparkle (keychain key)"
  SPARKLE_STATUS="signed"
else
  echo "note: no Sparkle EdDSA key (set SPARKLE_PRIVATE_KEY or run generate_keys); skipping appcast." >&2
  SPARKLE_STATUS="unconfigured"
  SIG_ATTRS=""
fi
{
  echo "SPARKLE_STATUS=$SPARKLE_STATUS"
  echo "SHORT_VERSION=$SHORT_VERSION"
  echo "BUILD_NUMBER=$BUILD_NUMBER"
  # Single-quoted: the value holds spaces and double quotes (sparkle:edSignature="…" length="…").
  echo "ENCLOSURE_ATTRS='$SIG_ATTRS'"
} >"$BUILD/appcast-fields.env"
echo "    appcast fields → $BUILD/appcast-fields.env (SPARKLE_STATUS=$SPARKLE_STATUS)"

echo "✅ Notarized + stapled installer: $DMG"
