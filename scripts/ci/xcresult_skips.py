"""Fails a UI-test run that skipped a test nobody said may skip (nightly-uitests.yml).

A UI test that skips (no editor installed, no Homebrew bash, a window that never opened) passes the
run while proving nothing, and xcodebuild exits 0 for it. This reads the run's result bundle and
fails when a test case skipped that ALLOWED_SKIPS (one `Class/testMethod()` per line) does not
name, or when the bundle's skip count disagrees with the cases found, so a changed bundle format
fails rather than passing unread.

Usage: xcresult_skips.py <bundle.xcresult | logs-dir>
  A logs dir is searched for its newest Test-WorkroomAppUITests-*.xcresult.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

SCHEME = "WorkroomAppUITests"


def skipped(nodes):
    """Every skipped test case's `Class/testMethod()` under these xcresulttool test nodes."""
    found = []
    for node in nodes:
        if node.get("nodeType") == "Test Case" and node.get("result") == "Skipped":
            found.append(node.get("nodeIdentifier") or node.get("name", "?"))
        else:
            found += skipped(node.get("children", []))
    return found


def problems(tests, summary, allowed):
    """What fails the run: unexpected skips, and a skip count the walk could not account for."""
    found = skipped(tests.get("testNodes", []))
    out = [f"unexpected skip: {name}" for name in found if name not in allowed]
    count = summary.get("skippedTests", 0)
    if count != len(found):
        out.append(f"the summary counts {count} skipped, but {len(found)} skipped cases were found")
    return out


def bundle_from(path):
    path = Path(path)
    if path.suffix == ".xcresult":
        return path if path.is_dir() else None
    bundles = sorted(path.glob(f"Test-{SCHEME}-*.xcresult"))
    return bundles[-1] if bundles else None


def xcresulttool(kind, bundle):
    out = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", kind, "--compact", "--path", str(bundle)],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def main(argv=None, env=None, read=xcresulttool):
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if env is None else env
    if len(argv) != 1:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    bundle = bundle_from(argv[0])
    if bundle is None:
        print(f"::error::no {SCHEME} result bundle at {argv[0]}")
        return 1
    allowed = {line.strip() for line in env.get("ALLOWED_SKIPS", "").splitlines() if line.strip()}
    found = problems(read("tests", bundle), read("summary", bundle), allowed)
    for line in found:
        print(f"::error::{line}")
    if not found:
        print(f"No unexpected skips in {bundle.name}.")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
