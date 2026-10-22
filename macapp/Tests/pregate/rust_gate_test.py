#!/usr/bin/env python3
"""The `vcs/` Rust lane for gstack's pre-gate (`.gstack/pregate.json`).

CI's rust job is `make vcs-lint` (rustfmt, clippy, rustdoc) plus `make vcs-test` (the workspace
tests, then workroomd with `terminal-state`), both on the pinned toolchain. Without this lane the
pre-gate stopped on any change under `vcs/` or the fixtures the Rust tests read. See
app_gate_test.py for why this is a Python file. Not a test of its own; nothing else runs it.

    python3 macapp/Tests/pregate/rust_gate_test.py

Run with the command sandbox disabled, as the cargo targets need.
"""

import os
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


class RustGateTest(unittest.TestCase):
    def test_vcs_lint_then_vcs_test(self):
        for target in ("vcs-lint", "vcs-test"):
            subprocess.run(["make", target], cwd=REPO_ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
