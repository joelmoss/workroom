#!/usr/bin/env python3
"""Fails a pull request that changes what users see without touching docs-site/.

AGENTS.md: "A PR that changes what users see or do ... updates `docs-site/` in the same PR." This is
the mechanical half of that rule: a change to one of the USER_FACING files below, with no change
under docs-site/, fails, unless the pull request carries the WAIVER label (a change users can't see,
such as a refactor of SettingsView). The CLI's pages need no entry here: `make docs-check` already
fails when they are stale.

Reads the changed paths, one per line, on stdin, and the pull request's label names as a JSON list
in $PR_LABELS. Exits 1, saying which file needs the docs, when the rule is broken. Run by
.github/workflows/docs-site-check.yml.
"""

import json
import os
import sys

# Each is where a user-visible setting, default or shortcut is declared. Add a file here when it
# becomes the one place such a thing is declared.
USER_FACING = (
    "macapp/WorkroomApp/Views/AppShell/SettingsView.swift",
    "macapp/WorkroomApp/Core/AppShell/DefaultsKeys.swift",
    "macapp/WorkroomApp/Core/AppShell/Shortcuts/ShortcutAction.swift",
)
DOCS = "docs-site/"
WAIVER = "no-docs"


def problems(paths, labels):
    """The user-facing files changed with no docs-site/ change and no waiver, in order."""
    if WAIVER in labels or any(p.startswith(DOCS) for p in paths):
        return []
    return [p for p in paths if p in USER_FACING]


def main():
    paths = [line.strip() for line in sys.stdin if line.strip()]
    labels = json.loads(os.environ.get("PR_LABELS") or "[]")
    found = problems(paths, labels)
    if not found:
        print("docs-site: nothing user-facing changed without its docs.")
        return 0
    for path in found:
        print(f"::error file={path}::{path} declares what users see, but docs-site/ is unchanged.")
    print(
        "Update docs-site/ in this pull request (AGENTS.md; mark a feature no stable release has "
        f"yet as Nightly, per docs-site/README.md), or add the '{WAIVER}' label if users see no "
        "change."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
