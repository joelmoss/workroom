#!/usr/bin/env python3
"""`scripts/agent-hooks/no_shell_edits.py`, the Bash hook that refuses shell edits in place.

    python3 scripts/agent-hooks/test_no_shell_edits.py
"""

import json
import os
import subprocess
import sys
import unittest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "no_shell_edits.py")


def run(command: str) -> subprocess.CompletedProcess:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    return subprocess.run(
        [sys.executable, HOOK], input=payload, capture_output=True, text=True, check=False
    )


class NoShellEditsTest(unittest.TestCase):
    def test_refuses_edits_in_place(self):
        for command in [
            "sed -i '' 's/a/b/' macapp/WorkroomApp/Core/AppStore.swift",
            "cd macapp && sed -E -i 's/a/b/' x.swift",
            "perl -pi -e 's/a/b/' cmd/delete.go",
            "python3 - <<'EOF'\np='macapp/x.swift'\nopen(p,'w').write(s)\nEOF",
            "python3 - <<'EOF'\nfrom pathlib import Path\nPath('README.md').write_text(s)\nEOF",
        ]:
            with self.subTest(command=command):
                result = run(command)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("Edit or Write tool", result.stderr)

    def test_lets_reads_and_scratch_writes_through(self):
        for command in [
            "sed -n 1,20p macapp/WorkroomApp/Core/AppStore.swift",
            "grep -n 'sed -i' AGENTS.md",
            'git commit -m "refuses sed -i, perl -i and a heredoc"',
            "echo \"it said: sed -i x y\"",
            "git diff | sed 's/^/  /'",
            "python3 - <<'EOF'\nimport json\nprint(json.load(open('a.json')))\nEOF",
            "cd /private/tmp/claude-501/x/scratchpad && python3 - <<'EOF'\n"
            "open('pr-body.md','w').write(b)\nEOF",
            "make app-test",
        ]:
            with self.subTest(command=command):
                self.assertEqual(run(command).returncode, 0)

    def test_input_it_cannot_read_passes(self):
        result = subprocess.run(
            [sys.executable, HOOK], input="not json", capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
