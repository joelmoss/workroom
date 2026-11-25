#!/usr/bin/env python3
"""Flags a unit test that shows a window the plain way (`make app-lint`).

    python3 macapp/Scripts/check-test-windows.py [--root DIR]

The unit suite runs on the developer's Mac, so a window a test orders front appears over their
work, dozens of times a run. Under WorkroomAppTests a window goes on screen through
`showTestWindow` (transparent and click-through, but still counted as on screen and visible) or,
for a test that needs an ordinary window, `showTestWindowVisibly(_:because:)`, both in
`Support/TestWindows.swift`. This refuses `orderFront(`, `orderFrontRegardless(` and
`makeKeyAndOrderFront(` anywhere else there, except on a line marked
`// check-test-windows: allow (<why>)`, for a test of the cloak itself. Standard library only.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.join(HERE, "..", "WorkroomAppTests")
HELPER = os.path.join("Support", "TestWindows.swift")
CALL = re.compile(r"\b(orderFront|orderFrontRegardless|makeKeyAndOrderFront)\s*\(")
ALLOW = re.compile(r"//\s*check-test-windows:\s*allow\b")


def strip_comment(line):
    """The line without a trailing `//` comment, so prose naming a call isn't flagged."""
    index = line.find("//")
    return line if index < 0 else line[:index]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=DEFAULT_ROOT)
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    failures = []
    for folder, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root)
            if relative == HELPER:
                continue
            with open(path, encoding="utf-8") as f:
                for number, line in enumerate(f, start=1):
                    if ALLOW.search(line):
                        continue
                    match = CALL.search(strip_comment(line))
                    if match:
                        failures.append(f"{relative}:{number}: {match.group(1)}")
    if failures:
        print(
            "A unit test shows a window the plain way, over the developer's work. Use "
            "showTestWindow(_:makeKey:), or showTestWindowVisibly(_:because:) for one that must be "
            f"seen ({HELPER}):",
            file=sys.stderr)
        for failure in sorted(failures):
            print(f"  {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
