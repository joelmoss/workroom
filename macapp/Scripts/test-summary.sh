#!/bin/sh
#
# Prints the verdict of the xcodebuild test run that just finished: its counts, then each failing
# test with its message. `make app-test` and `make app-uitest` call it after their test step,
# because xcodebuild's own console summary is buried under the build log (or missing entirely
# under Xcode 26+), so agents kept digging the bundle out of DerivedData by hand.
#
# Usage: test-summary.sh <logs-dir> <scheme> <stamp-file>
#   Reports the newest `Test-<scheme>-*.xcresult` in <logs-dir> that is newer than <stamp-file>,
#   which the caller touches just before the test step. An older bundle is a previous run's, so it
#   is never reported as this one's.
# Usage: test-summary.sh <bundle.xcresult>
#   Reports that bundle, such as one downloaded from a CI run's artifacts.
#
# Always exits 0: the caller keeps xcodebuild's exit status, and a summary that cannot be read must
# not turn a passing run red. Needs the command sandbox off (xcresulttool writes to system temp).
set -u

if [ "$#" -eq 1 ]; then
  bundle="$1"
  if [ ! -d "$bundle" ]; then
    echo "test-summary: no result bundle at ${bundle}"
    exit 0
  fi
else
  logs="$1"
  scheme="$2"
  stamp="$3"

  bundle="$(find "$logs" -maxdepth 1 -name "Test-${scheme}-*.xcresult" -newer "$stamp" 2>/dev/null |
    sort | tail -n 1)"
  if [ -z "$bundle" ]; then
    echo "test-summary: no ${scheme} result bundle from this run in ${logs} (the run stopped before" \
      "tests started, or -resultBundlePath put it elsewhere)"
    exit 0
  fi
fi

if ! json="$(xcrun xcresulttool get test-results summary --compact --path "$bundle" 2>&1)"; then
  echo "test-summary: couldn't read ${bundle}: ${json}"
  exit 0
fi

printf '%s' "$json" | python3 -c '
import json, sys
bundle = sys.argv[1]
try:
    d = json.load(sys.stdin)
except ValueError as e:
    print(f"test-summary: unreadable summary for {bundle}: {e}")
    sys.exit(0)
counts = [d.get(k, 0) for k in ("passedTests", "failedTests", "skippedTests", "totalTestCount")]
print()
print("Tests: %s - %d passed, %d failed, %d skipped (of %d)" % (d.get("result", "?"), *counts))
for f in d.get("testFailures", []):
    name = f.get("testIdentifierString") or f.get("testName", "?")
    text = (f.get("failureText") or "").strip().replace("\n", " ")
    print("  FAIL %s/%s: %s" % (f.get("targetName", "?"), name, text))
' "$bundle"

# A test that failed and then passed on a retry (`make app-test` retries a failure once) counts as
# passed above. Name each one, so a flake stays visible instead of turning a run red: the per-test
# tree lists every run of a test case as a "Repetition" child.
#
# TEST_SUMMARY_CLASSES=1 also prints each class's counts, as `CLASS <bundle>/<class>: N passed, N
# failed, N skipped`, for a run of several opt-in classes where one of them skipping whole hides in
# the total (macapp/Scripts/remote-tests.sh). A class with no test that ran has no line.
if tests="$(xcrun xcresulttool get test-results tests --compact --path "$bundle" 2>/dev/null)"; then
  printf '%s' "$tests" | TEST_SUMMARY_CLASSES="${TEST_SUMMARY_CLASSES:-}" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
classes = {}
def walk(node, path):
    kind = node.get("nodeType")
    name = node.get("name", "?")
    children = node.get("children", [])
    if kind == "Test Case":
        counts = classes.setdefault("/".join(path), {"passed": 0, "failed": 0, "skipped": 0})
        result = node.get("result")
        if result in ("Passed", "Expected Failure"):
            counts["passed"] += 1
        elif result == "Skipped":
            counts["skipped"] += 1
        else:
            counts["failed"] += 1
        runs = [c for c in children if c.get("nodeType") == "Repetition"]
        if node.get("result") == "Passed" and any(r.get("result") == "Failed" for r in runs):
            first = next((m.get("name", "") for r in runs if r.get("result") == "Failed"
                          for m in r.get("children", []) if m.get("nodeType") == "Failure Message"), "")
            print("  FLAKY %s: passed on retry after: %s" % ("/".join(path + [name]),
                                                            first.strip().replace("\n", " ")))
        return
    if kind in ("Unit test bundle", "UI test bundle", "Test Suite"):
        path = path + [name]
    for child in children:
        walk(child, path)
for node in d.get("testNodes", []):
    walk(node, [])
if os.environ.get("TEST_SUMMARY_CLASSES") == "1":
    for name, counts in sorted(classes.items()):
        print("  CLASS %s: %d passed, %d failed, %d skipped" % (
            name, counts["passed"], counts["failed"], counts["skipped"]))
'
fi
echo "Result bundle: ${bundle}"
exit 0
