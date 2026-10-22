#!/bin/sh
#
# Dependency-free test for test-summary.sh, with a stub `xcrun` so it needs no Xcode or real bundle.
# Run: sh macapp/Scripts/test-summary_test.sh   (exits non-zero on any failure).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# A named template, because template-less BSD `mktemp -d` ignores $TMPDIR (see build-daemon_test.sh).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-summary_test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/logs"
cat >"$TMP/bin/xcrun" <<'EOF'
#!/bin/sh
cat "$STUB_JSON"
EOF
chmod +x "$TMP/bin/xcrun"
cat >"$TMP/failed.json" <<'EOF'
{"result":"Failed","passedTests":7,"failedTests":1,"skippedTests":2,"totalTestCount":10,
 "testFailures":[{"testName":"testB()","targetName":"WorkroomAppTests",
 "testIdentifierString":"FooTests/testB()","failureText":"XCTAssertEqual failed:\n(1) != (2)"}]}
EOF

fails=0
# check <description> <output> <expected substring>
check() {
  case "$2" in
  *"$3"*) ;;
  *)
    echo "FAIL: $1: output lacks '$3'. Got:"
    echo "$2"
    fails=$((fails + 1))
    ;;
  esac
}

run() {
  PATH="$TMP/bin:$PATH" STUB_JSON="$TMP/failed.json" \
    sh "$DIR/test-summary.sh" "$TMP/logs" WorkroomApp "$TMP/stamp"
}

# A bundle older than the stamp is a previous run's: it must not be reported as this one's.
mkdir "$TMP/logs/Test-WorkroomApp-old.xcresult"
touch -t 202001010000 "$TMP/logs/Test-WorkroomApp-old.xcresult"
touch "$TMP/stamp"
out="$(run)"
check "stale bundle ignored" "$out" "no WorkroomApp result bundle from this run"

# Another scheme's fresh bundle is not this run's either.
mkdir "$TMP/logs/Test-WorkroomAppUITests-new.xcresult"
out="$(run)"
check "other scheme ignored" "$out" "no WorkroomApp result bundle from this run"

mkdir "$TMP/logs/Test-WorkroomApp-new.xcresult"
out="$(run)"
check "counts" "$out" "Tests: Failed - 7 passed, 1 failed, 2 skipped (of 10)"
check "failure line" "$out" "FAIL WorkroomAppTests/FooTests/testB(): XCTAssertEqual failed: (1) != (2)"
check "bundle path" "$out" "Test-WorkroomApp-new.xcresult"

run >/dev/null || { echo "FAIL: exit status non-zero"; fails=$((fails + 1)); }

# A bundle named outright (one downloaded from CI, say) is reported whatever its age or name.
mkdir "$TMP/ci.xcresult"
touch -t 202001010000 "$TMP/ci.xcresult"
out="$(PATH="$TMP/bin:$PATH" STUB_JSON="$TMP/failed.json" sh "$DIR/test-summary.sh" "$TMP/ci.xcresult")"
check "named bundle counts" "$out" "Tests: Failed - 7 passed, 1 failed, 2 skipped (of 10)"
check "named bundle path" "$out" "Result bundle: $TMP/ci.xcresult"

out="$(sh "$DIR/test-summary.sh" "$TMP/missing.xcresult")"
check "named bundle missing" "$out" "test-summary: no result bundle at $TMP/missing.xcresult"

if [ "$fails" -ne 0 ]; then
  echo "test-summary_test: $fails failure(s)" >&2
  exit 1
fi
echo "test-summary_test: all cases passed"
