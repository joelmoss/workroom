#!/usr/bin/env python3
"""This repo's own setup script, `scripts/workroom_setup`, on both kinds of workroom.

On this Mac it copies the root's `.claude/settings.local.json` into the new workroom. On a remote
workroom's host there is no root project (`WORKROOM_ROOT_PATH` is unset; see the README's
"Environment variables"), so it copies nothing and passes, rather than failing every remote create
of this repo. The backticked path above is what the pre-gate's import graph reads to select this
test for a change to the script. Nothing else runs it:

    python3 scripts/workroom_setup_test.py
"""

import os
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workroom_setup")


def run(workroom, **env):
    base = {k: v for k, v in os.environ.items() if not k.startswith("WORKROOM_")}
    base.update(env)
    return subprocess.run(
        ["bash", SCRIPT], cwd=workroom, env=base, capture_output=True, text=True
    )


class WorkroomSetupTest(unittest.TestCase):
    def test_a_remote_host_copies_nothing_and_passes(self):
        with tempfile.TemporaryDirectory() as workroom:
            result = run(workroom, WORKROOM_NAME="w", WORKROOM_PATH=workroom, WORKROOM_HOST="boxd")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("No root project on this host (boxd)", result.stdout)
            self.assertFalse(os.path.exists(os.path.join(workroom, ".claude")))

    def test_a_local_workroom_gets_the_roots_settings(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as workroom:
            os.makedirs(os.path.join(root, ".claude"))
            os.makedirs(os.path.join(workroom, ".claude"))
            with open(os.path.join(root, ".claude", "settings.local.json"), "w") as f:
                f.write('{"from": "root"}')
            result = run(
                workroom, WORKROOM_NAME="w", WORKROOM_PATH=workroom, WORKROOM_ROOT_PATH=root,
                WORKROOM_HOST="local",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(os.path.join(workroom, ".claude", "settings.local.json")) as f:
                self.assertEqual(f.read(), '{"from": "root"}')

    def test_it_refuses_to_run_outside_workroom(self):
        with tempfile.TemporaryDirectory() as workroom:
            result = run(workroom)
            self.assertEqual(result.returncode, 1)
            self.assertIn("WORKROOM_NAME is not set", result.stderr)


if __name__ == "__main__":
    unittest.main()
