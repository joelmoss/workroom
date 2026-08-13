#!/bin/bash
#
# Copies the workroom-session helper into Contents/MacOS next to the app binary and
# signs it with the same identity. Run as a post-compile Xcode script phase (before
# Xcode's final code-sign) so the helper is covered by the app signature.
set -euo pipefail

HELPER_NAME="workroom-session"
SOURCE="${BUILT_PRODUCTS_DIR}/${HELPER_NAME}"
DEST_DIR="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
DEST="${DEST_DIR}/${HELPER_NAME}"

if [ ! -x "$SOURCE" ]; then
  echo "error: ${HELPER_NAME} was not built at ${SOURCE}." >&2
  echo "error: add the workroom-session target to this scheme's build action." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp -f "$SOURCE" "$DEST"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ] || [ -z "$IDENTITY" ]; then
  echo "Ad-hoc signing ${HELPER_NAME} (local dev build)"
  codesign --force --sign - "$DEST"
else
  echo "Signing ${HELPER_NAME} with $IDENTITY (hardened runtime + timestamp)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DEST"
fi
