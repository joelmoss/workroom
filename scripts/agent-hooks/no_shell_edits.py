#!/usr/bin/env python3
"""A Claude Code PreToolUse hook for Bash (`.claude/settings.json`): refuses a command that edits a
file in place from the shell, which AGENTS.md asks agents to do with their file-editing tool, so the
edit shows a reviewable diff.

Refused: `sed -i`, `perl -i`/`-pi`, and a Python heredoc that writes a file, unless every write
goes under /tmp (a scratchpad: a PR body, a log). Reads the hook's JSON on stdin; exit 2 blocks the
command and hands stderr to the agent. Tested by `scripts/agent-hooks/test_no_shell_edits.py`.
"""

import json
import re
import sys

# As a command word (after a separator or a space), so a quoted mention ('sed -i') passes.
IN_PLACE = re.compile(
    r"(?:^|[\s|;&(])(?:sed|gsed|perl)(?=\s)[^|;&\n]*\s(?:-[a-zA-Z]*i|--in-place)", re.MULTILINE
)
PYTHON_HEREDOC = re.compile(r"(?:^|[\s|;&(])python3?\s[^|;&\n]*<<", re.MULTILINE)
WRITES = re.compile(r"\.write\(|write_text\(|write_bytes\(|open\([^)]*,\s*(?:mode=)?['\"][wa]")


# Quoted text is a mention (a commit message, an echo, a grep pattern), not a command.
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", re.DOTALL)


def refusal(command: str) -> str | None:
    unquoted = QUOTED.sub("''", command)
    if IN_PLACE.search(unquoted):
        return "sed -i / perl -i edits a file in place"
    if PYTHON_HEREDOC.search(unquoted) and WRITES.search(command) and "/tmp/" not in command:
        return "a Python heredoc writes a file"
    return None


def main() -> int:
    try:
        command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except (ValueError, AttributeError):
        return 0
    why = refusal(command)
    if why is None:
        return 0
    print(
        f"BLOCK: {why}. Edit source files with the Edit or Write tool instead, so the change "
        "shows a reviewable diff (AGENTS.md). A scratch file under /tmp is fine.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
