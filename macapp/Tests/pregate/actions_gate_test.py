#!/usr/bin/env python3
"""The `.github/` lane for gstack's pre-gate (`.gstack/pregate.json`).

CI lints the workflows, the composite actions and `dependabot.yml` with `make actions-lint`
(jactionlint, shellcheck included). Without this lane the pre-gate stopped on any change under
`.github/`. See app_gate_test.py for why this is a Python file. Not a test of its own; nothing
else runs it.

    python3 macapp/Tests/pregate/actions_gate_test.py
"""

import os
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


class ActionsGateTest(unittest.TestCase):
    def test_actions_lint(self):
        subprocess.run(["make", "actions-lint"], cwd=REPO_ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
