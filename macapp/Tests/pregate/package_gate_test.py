#!/usr/bin/env python3
"""The macapp/Packages lane for gstack's pre-gate (`.gstack/pregate.json`).

`make app-test` never runs the local packages' own tests; `make app-package-test` does, as the CI
`app` job does beside it. See app_gate_test.py for why this is a Python file. Not a test of its own;
nothing else runs it.

    python3 macapp/Tests/pregate/package_gate_test.py

Run with the command sandbox disabled, as `make app-package-test` needs.
"""

import os
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


class PackageGateTest(unittest.TestCase):
    def test_app_package_test(self):
        subprocess.run(["make", "app-package-test"], cwd=REPO_ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
