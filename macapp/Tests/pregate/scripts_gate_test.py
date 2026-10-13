#!/usr/bin/env python3
"""The `macapp/Scripts` lane for gstack's pre-gate (`.gstack/pregate.json`).

The build, release and test-infra scripts are checked by `make app-scripts-lint` (shellcheck) and
`make app-test-scripts`, which also runs the repo invariants in test-invariants_test.sh. Without
this lane the pre-gate stopped on any script change, since nothing mapped it to a test. The
backticked directory above is a path literal the pre-gate's import graph reads, so this lane
selects itself even before the base branch's `dependencies` map it. See app_gate_test.py for why
this is a Python file. Not a test of its own; nothing else runs it.

    python3 macapp/Tests/pregate/scripts_gate_test.py

Needs shellcheck on PATH, as `make app-scripts-lint` does.
"""

import os
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


class ScriptsGateTest(unittest.TestCase):
    def test_app_scripts_lint_then_app_test_scripts(self):
        for target in ("app-scripts-lint", "app-test-scripts"):
            subprocess.run(["make", target], cwd=REPO_ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
