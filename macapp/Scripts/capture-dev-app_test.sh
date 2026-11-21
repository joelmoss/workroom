#!/bin/sh
#
# Test for capture-dev-app.sh's failure paths, which need no screen: a wrong argument count, and an
# app that isn't running. The capture itself drives the owner's screen, so it is checked by hand
# (`make app-run`, then `make app-capture`).
# Run: sh macapp/Scripts/capture-dev-app_test.sh   (exits non-zero on any failure).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/capture-dev-app_test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0

out="$(sh "$DIR/capture-dev-app.sh" 2>&1)"
status=$?
[ "$status" -eq 2 ] || { echo "FAIL: no arguments exits 2, got $status"; fails=$((fails + 1)); }
case "$out" in *usage:*) ;; *) echo "FAIL: no arguments prints usage. Got: $out"; fails=$((fails + 1)) ;; esac

out="$(sh "$DIR/capture-dev-app.sh" com.example.not-running.capture-test "$TMP/out.png" 2>&1)"
status=$?
[ "$status" -ne 0 ] || { echo "FAIL: an app that isn't running exits non-zero"; fails=$((fails + 1)); }
case "$out" in *"not running"*) ;; *) echo "FAIL: says the app isn't running. Got: $out"; fails=$((fails + 1)) ;; esac
[ ! -e "$TMP/out.png" ] || { echo "FAIL: no capture is written for an app that isn't running"; fails=$((fails + 1)); }

if [ "$fails" -ne 0 ]; then
  echo "capture-dev-app_test: $fails failure(s)" >&2
  exit 1
fi
echo "capture-dev-app_test: all cases passed"
