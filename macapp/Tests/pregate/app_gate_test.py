#!/usr/bin/env python3
"""The macapp lane for gstack's pre-gate (`.gstack/pregate.json`).

gstack-pregate only recognises JS/TS, Python, Go and Ruby files as tests, so it cannot map a Swift
change to `make app-lint` and `make app-test` directly. Its `dependencies` map the app's Swift
sources, tests, packages, resources and build settings to this file instead, and this file runs the
two make targets: the pre-landing gate in macapp/AGENTS.md. A WorkroomAppUITests change gets lint
only here, as in CI: XCUITest runs only under `make app-uitest`. macapp/Scripts and the
run-supervisor test have gates of their own and are not mapped here. Not a test of its own;
nothing else runs it.

    python3 macapp/Tests/pregate/app_gate_test.py

Run with the command sandbox disabled, as `make app-test` needs.
"""

import os
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


class AppGateTest(unittest.TestCase):
    def test_app_lint_then_app_test(self):
        for target in ("app-lint", "app-test"):
            subprocess.run(["make", target], cwd=REPO_ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
