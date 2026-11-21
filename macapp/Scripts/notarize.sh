# shellcheck shell=bash
#
# Notarization for the release scripts: release.sh (the app and its DMG) and cli-archives.sh (the
# standalone binaries). Sourced, not run.
#
# Auth, either:
#   - Local: a keychain profile, NOTARY_PROFILE (default "workroom-notary"); see release.sh for
#     `xcrun notarytool store-credentials`.
#   - CI / API key: NOTARY_KEY_PATH (App Store Connect .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID.

# Run `xcrun notarytool <subcommand> …` with whichever auth is configured: an App Store
# Connect API key when NOTARY_KEY_PATH is set (CI: --key/--key-id/--issuer), else a local
# keychain profile (NOTARY_PROFILE, default "workroom-notary"; see the store-credentials note).
notarytool_auth() {
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    xcrun notarytool "$@" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  else
    xcrun notarytool "$@" --keychain-profile "${NOTARY_PROFILE:-workroom-notary}"
  fi
}

# Submit a container (.zip/.dmg) and wait. NOTE: `notarytool submit --wait` exits 0 even when
# the result is Invalid, so we parse the final status ourselves; on anything but Accepted we
# dump Apple's per-file notary log (which states exactly what was rejected) and abort — never
# proceed to staple a ticket that was never issued.
#
# A wait that ends with no final status had the submission accepted for processing but lost
# its connection while polling (GitHub's runners went "offline" mid-wait twice on 2026-11-11).
# Apple keeps processing it, so wait on the same submission id again rather than fail the build.
notarize() {
  local out id status attempt
  out="$(notarytool_auth submit "$1" --wait 2>&1)" || true
  echo "$out"
  id="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*id: \(.*\)$/\1/p' | head -1)"
  status="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*status: \(.*\)$/\1/p' | head -1)"
  attempt=1
  while [ -z "$status" ] && [ -n "$id" ] && [ "$attempt" -le 5 ]; do
    echo "notarization wait for $id ended without a result; waiting again ($attempt/5)" >&2
    sleep 30
    out="$(notarytool_auth wait "$id" 2>&1)" || true
    echo "$out"
    status="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*status: \(.*\)$/\1/p' | tail -1)"
    attempt=$((attempt + 1))
  done
  if [ "$status" != "Accepted" ]; then
    echo "error: notarization returned '${status:-unknown}' for $(basename "$1")." >&2
    if [ -n "$id" ]; then
      echo "--- notary log ($id) ---" >&2
      notarytool_auth log "$id" >&2 || true
    fi
    exit 1
  fi
}
