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
print("Result bundle: " + bundle)
' "$bundle"
exit 0
