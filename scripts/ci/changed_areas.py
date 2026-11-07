#!/usr/bin/env python3
"""Which of CI's path-filtered jobs a pull request's changes need.

Reads the changed paths, one per line, on stdin and prints one `<job>=true|false` line per job,
in the form `$GITHUB_OUTPUT` takes. ci.yml's `changes` job runs it on a pull request's diff; a
push runs every job, by passing nothing.

Each rule names the jobs whose tests or build read that path, which is wider than the language it
is written in: every language's tests read `testdata/`, the app bundles the daemon, the Rust tests
read the daemon bootstrap scripts, and the Go and app tests both read `docs-site/`. A path no rule
names runs every job, as does an empty diff, so a file a new test starts to read is over-tested
until a rule says otherwise, never skipped. Add a rule here when a test reads a new path outside
its own tree. The master push runs everything whatever this says.
"""

import sys

JOBS = ("cli", "rust", "packages", "app", "scripts")
ALL = frozenset(JOBS)

# First match wins. A prefix ends in "/"; anything else is a whole path, or a suffix for "*.x".
RULES = (
    # Build and CI plumbing every job runs through.
    ((".github/", "Makefile", "mk/"), ALL),
    # The shared fixture tables (contracts, cross-language twins, program status, script env).
    (("testdata/",), ALL),
    # The app's packages, which the app imports and the script tests grep.
    (("macapp/Packages/",), {"packages", "app", "scripts"}),
    # The daemon's far-side bootstrap, which remote_transport.rs runs too.
    (("macapp/Resources/daemon-bootstrap/",), {"rust", "app", "scripts"}),
    (("macapp/",), {"app", "scripts"}),
    # The app bundles the daemon and runs its macOS-only tests; the script tests build it.
    (("vcs/",), {"rust", "app", "scripts"}),
    # The app's setup-go and the CLI it compiles read the toolchain from go.mod.
    (("go.mod", "go.sum"), {"cli", "app", "scripts"}),
    # KeyboardShortcutsDocsTests reads this page; cmd/docs_test.go and internal/docsite read all.
    (("docs-site/pages/reference/keyboard-shortcuts.md",), {"cli", "app"}),
    (("docs-site/",), {"cli"}),
    # Go sources only: a data file under cmd/ or internal/ (channel_cases.tsv, which the app and
    # the script tests read) has no rule and so runs everything.
    (("*.go", ".golangci.yml", ".goreleaser.yml"), {"cli"}),
    # Read by no job's tests. The `workflows` job, which is never filtered, covers scripts/ci/.
    (("docs/", "*.md", ".agents/", ".claude/", ".out-of-scope/", ".gstack/", "scripts/ci/",
      "MIT-LICENSE"), frozenset()),
)


def matches(path, pattern):
    if pattern.endswith("/"):
        return path.startswith(pattern)
    if pattern.startswith("*"):
        return path.endswith(pattern[1:])
    return path == pattern


def jobs_for(path):
    for patterns, jobs in RULES:
        if any(matches(path, pattern) for pattern in patterns):
            return jobs
    return ALL


def areas(paths):
    paths = [path for path in paths if path]
    if not paths:
        return {job: True for job in JOBS}
    needed = set()
    for path in paths:
        needed |= jobs_for(path)
    return {job: job in needed for job in JOBS}


def main():
    for job, needed in areas(line.rstrip("\n") for line in sys.stdin).items():
        print(f"{job}={'true' if needed else 'false'}")


if __name__ == "__main__":
    main()
