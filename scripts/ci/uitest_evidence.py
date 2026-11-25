#!/usr/bin/env python3
"""Fetches a UI-test run's evidence for its failed tests: message, screenshots and video frames.

A failed XCUITest's message rarely says why (an accessibility value can be stale while the screen
is right), so the evidence is what the screen showed. For a GitHub Actions run of
nightly-uitests.yml, or a local .xcresult, this writes per failed test:

  <out>/<Class>.<test>/            the test's exported attachments (screenshots, the screen recording)
  <out>/<Class>.<test>/frames/     the recording's last few seconds as PNGs, every half second

and prints each test's failure message and where its files are. Read the frames with an image
viewer (or the Read tool): the last ones show the screen at the failure.

Usage: uitest_evidence.py <run-id | bundle.xcresult> [-o DIR] [--seconds N] [Class/test() ...]
  Tests default to every failed one. DIR defaults to a new directory under $TMPDIR.
  A run id needs `gh` (authenticated) and downloads the run's `xcresult-uitests` artifact.

xcresulttool takes a test id as `Class/test()`, without the scheme: `WorkroomAppUITests/Class/…`
matches nothing and exports nothing, silently.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ARTIFACT = "xcresult-uitests"
FRAMES = Path(__file__).with_name("video_frames.swift")


def failures(nodes):
    """(Class/test(), message) for every failed test case under these xcresulttool test nodes."""
    found = []
    for node in nodes:
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
            messages = [
                c.get("name", "")
                for c in node.get("children", [])
                if c.get("nodeType") == "Failure Message"
            ]
            found.append((node.get("nodeIdentifier") or node.get("name", "?"), "\n".join(messages)))
        else:
            found += failures(node.get("children", []))
    return found


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def bundle_for(source, out):
    """The .xcresult for a bundle path, or for a run id after downloading its artifact into out."""
    if source.endswith(".xcresult"):
        return Path(source)
    dest = out / "download"
    run("gh", "run", "download", source, "-n", ARTIFACT, "-D", str(dest))
    bundles = sorted(dest.glob("*.xcresult"))
    if not bundles:
        sys.exit(f"run {source}'s {ARTIFACT} artifact holds no .xcresult")
    return bundles[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("source", help="a GitHub Actions run id, or a .xcresult bundle")
    parser.add_argument("tests", nargs="*", help="Class/test() ids; default every failed test")
    parser.add_argument("-o", "--out", type=Path)
    parser.add_argument("--seconds", type=float, default=4, help="seconds of recording to keep")
    args = parser.parse_intermixed_args()

    out = args.out or Path(tempfile.mkdtemp(prefix="uitest-evidence-"))
    out.mkdir(parents=True, exist_ok=True)
    bundle = bundle_for(args.source, out)
    tree = json.loads(run("xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)))
    failed = dict(failures(tree.get("testNodes", [])))
    tests = args.tests or list(failed)
    if not tests:
        print(f"No failed tests in {bundle}.")
        return 0

    for test in tests:
        test_id = test.split("/", 1)[1] if test.count("/") > 1 else test
        folder = out / test_id.replace("/", ".").rstrip("()")
        folder.mkdir(exist_ok=True)
        run(
            "xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
            "--output-path", str(folder), "--test-id", test_id,
        )
        print(f"== {test_id}\n{failed.get(test_id, '(not a failed test)')}\n   files: {folder}")
        for video in sorted(folder.glob("*.mp4")):
            frames = folder / "frames"
            frames.mkdir(exist_ok=True)
            run("swift", str(FRAMES), str(video), str(frames), str(args.seconds))
            last = sorted(frames.glob("*.png"))
            print(f"   frames: {frames} ({len(last)}; last {last[-1].name if last else 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
