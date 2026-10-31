#!/bin/sh
# Test for build-ghostty-vt.sh's cache against a throwaway cache root. Every `xcodegen generate` runs
# `--kit`, so a kit cache that stops hitting rebuilds Ghostty each time, and one that hits on a
# half-built prefix links nothing. WR_GHOSTTY_SRC points at nothing, so a miss fails there instead of
# fetching or building. Run: sh macapp/Scripts/build-ghostty-vt_test.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/vcs/scripts/build-ghostty-vt.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/build-ghostty-vt_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
WR_GHOSTTY_VT_CACHE="$TMP/cache"
WR_GHOSTTY_SRC="$TMP/no-such-checkout"
export WR_GHOSTTY_VT_CACHE WR_GHOSTTY_SRC

# A kit with no Info.plist is half-built, and the vt library is no kit.
kit_prefix="$("$SCRIPT" --kit --print-prefix)"
vt_prefix="$("$SCRIPT" --target aarch64-macos --print-prefix)"
mkdir -p "$kit_prefix/GhosttyKit.xcframework" "$vt_prefix/lib" "$vt_prefix/include/ghostty/vt"
: >"$vt_prefix/lib/libghostty-vt.a"
: >"$vt_prefix/include/ghostty/vt/snapshot.h"
if "$SCRIPT" --kit >"$TMP/out" 2>"$TMP/err"; then
  echo "FAIL: --kit accepted a prefix with no Info.plist:" && cat "$TMP/out"
  exit 1
fi
grep -q 'is not a git checkout' "$TMP/err" || {
  echo "FAIL: --kit stopped for the wrong reason:" && cat "$TMP/err"
  exit 1
}

: >"$kit_prefix/GhosttyKit.xcframework/Info.plist"
got="$("$SCRIPT" --kit 2>"$TMP/err")"
[ "$got" = "$kit_prefix/GhosttyKit.xcframework" ] || {
  echo "FAIL: --kit printed '$got', want the cached xcframework." && cat "$TMP/err"
  exit 1
}
grep -q 'GhosttyKit: cached' "$TMP/err" || {
  echo "FAIL: --kit did not say it used the cache:" && cat "$TMP/err"
  exit 1
}

got="$("$SCRIPT" --target aarch64-macos 2>/dev/null)"
[ "$got" = "$vt_prefix" ] || {
  echo "FAIL: the vt build printed '$got', want its own prefix."
  exit 1
}

echo "build-ghostty-vt_test: all cases passed"
