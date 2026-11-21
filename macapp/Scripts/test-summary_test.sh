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
# `get test-results summary` answers with $STUB_JSON, `get test-results tests` with $STUB_TESTS
# (an empty tree unless a case sets it).
cat >"$TMP/bin/xcrun" <<'EOF'
#!/bin/sh
case "$*" in
*"test-results tests"*) cat "${STUB_TESTS:-/dev/null}" ;;
*) cat "$STUB_JSON" ;;
esac
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

# A test that failed, then passed on its retry, is named as FLAKY; one that passed first time, or
# failed every time, is not.
cat >"$TMP/tests.json" <<'EOF'
{"testNodes":[{"nodeType":"Test Plan","name":"WorkroomApp","children":[
 {"nodeType":"Unit test bundle","name":"WorkroomAppTests","children":[
  {"nodeType":"Test Suite","name":"BarTests","children":[
   {"nodeType":"Test Case","name":"testFlaky()","result":"Passed","children":[
    {"nodeType":"Repetition","name":"First Run","result":"Failed","children":[
     {"nodeType":"Failure Message","name":"XCTAssertLessThan failed:\n(8) is not less than (5)"}]},
    {"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]},
   {"nodeType":"Test Case","name":"testSteady()","result":"Passed"},
   {"nodeType":"Test Case","name":"testBroken()","result":"Failed","children":[
    {"nodeType":"Repetition","name":"First Run","result":"Failed"},
    {"nodeType":"Repetition","name":"Retry 1","result":"Failed"}]}]}]}]}]}
EOF
out="$(PATH="$TMP/bin:$PATH" STUB_JSON="$TMP/failed.json" STUB_TESTS="$TMP/tests.json" \
  sh "$DIR/test-summary.sh" "$TMP/ci.xcresult")"
check "flaky line" "$out" \
  "FLAKY WorkroomAppTests/BarTests/testFlaky(): passed on retry after: XCTAssertLessThan failed: (8) is not less than (5)"
case "$out" in
*"FLAKY"*"testSteady"* | *"FLAKY"*"testBroken"*)
  echo "FAIL: only the test that passed on a retry is FLAKY. Got:"
  echo "$out"
  fails=$((fails + 1))
  ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "test-summary_test: $fails failure(s)" >&2
  exit 1
fi
echo "test-summary_test: all cases passed"
