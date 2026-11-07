#!/usr/bin/env python3
"""Which of CI's path-filtered jobs a pull request's changes need.

Reads the changed paths, one per line, on stdin and prints one `<job>=true|false` line per job,
in the form `$GITHUB_OUTPUT` takes. ci.yml's `changes` job runs it on a pull request's diff; a
push runs every job, by passing nothing.

Each rule names the jobs whose tests or build read that path, which is wider than the language it
is written in: the shared tables under `testdata/` are read by several languages' tests, the app
bundles the daemon, the Rust tests read the daemon bootstrap scripts, and the Go and app tests both
read `docs-site/`. A path no rule names runs every job, as does an empty diff, so a file a new test
starts to read is over-tested until a rule says otherwise, never skipped; each narrow rule sits
ahead of a catch-all for its tree (`.github/`, `mk/`, `testdata/`) that runs everything. Add a rule
here when a test reads a new path outside its own tree. The master push runs everything whatever
this says.
"""

import sys
from fnmatch import fnmatchcase

JOBS = ("cli", "rust", "packages", "app", "scripts")
ALL = frozenset(JOBS)

# First match wins. Patterns are fnmatch globs, matched case-sensitively, whose `*` also matches
# "/": "mk/*" is everything under mk/, and "*.md" is every Markdown file in the tree.
RULES = (
    # ci.yml calls every job. Each other workflow, and each composite action, runs the jobs that
    # run it: test_changed_areas.py reads those off the workflows and checks these rules name them.
    ((".github/workflows/ci.yml",), ALL),
    ((".github/workflows/ci-go.yml",), {"cli"}),
    ((".github/workflows/ci-rust.yml",), {"rust"}),
    ((".github/workflows/ci-app.yml", ".github/actions/setup-app-build/*"),
     {"packages", "app", "scripts"}),
    ((".github/actions/setup-daemon-build/*",), {"app", "scripts"}),
    ((".github/actions/install-zig/*", ".github/actions/install-cargo-zigbuild/*"),
     {"rust", "app", "scripts"}),
    # No pull request runs these, but test-invariants_test.sh (app-scripts) checks that both still
    # run the app's tests.
    ((".github/workflows/release.yml", ".github/workflows/nightly.yml"), {"scripts"}),
    # Run by no pull request job. The `workflows` job, which is never filtered, lints every file
    # here and is ci-actions.yml itself.
    ((".github/workflows/ci-actions.yml", ".github/workflows/ci-docs.yml",
      ".github/workflows/download-stats.yml", ".github/workflows/appcast-notes.yml",
      ".github/actions/import-signing-certificate/*", ".github/dependabot.yml",
      ".github/CODEOWNERS", ".github/PULL_REQUEST_TEMPLATE.md", ".github/ISSUE_TEMPLATE/*"),
     frozenset()),
    # Only the macOS jobs run `make`, and their targets live in mk/app.mk. The cli and Rust jobs
    # call go and cargo directly, and the `workflows` job parses every mk file through
    # `make actions-lint`, so a broken include fails there.
    (("Makefile", "mk/app.mk"), {"packages", "app", "scripts"}),
    (("mk/cli.mk", "mk/docs.mk", "mk/vcs.mk", "mk/actions.mk"), frozenset()),
    ((".github/*", "mk/*"), ALL),
    # The shared fixture tables, each with the jobs whose tests read it. The tables a Rust unit
    # test include_str!s count the app too: its macOS `cargo test --lib` compiles those tests.
    (("testdata/contracts/frames.tsv",), {"rust", "packages"}),
    (("testdata/contracts/*",), {"cli", "packages", "app"}),
    (("testdata/twins/*",), {"cli", "rust", "packages", "app"}),
    (("testdata/program-status/*",), {"rust", "packages", "app"}),
    (("testdata/script-env/*",), {"cli", "rust", "app"}),
    (("testdata/fixtures/*",), {"cli"}),
    (("testdata/*",), ALL),
    # The app's and the daemon's own docs, which nothing builds, bundles or reads. The Markdown the
    # app bundles lives under macapp/Resources and stays with the app.
    (("macapp/AGENTS.md", "macapp/README.md", "macapp/QA-libghostty.md",
      "macapp/QA-libghostty-results/*", "vcs/scripts/oq19/*.md"), frozenset()),
    # The app's packages, which the app imports and the script tests grep.
    (("macapp/Packages/*",), {"packages", "app", "scripts"}),
    # The daemon's far-side bootstrap, which remote_transport.rs runs too.
    (("macapp/Resources/daemon-bootstrap/*",), {"rust", "app", "scripts"}),
    (("macapp/*",), {"app", "scripts"}),
    # The app bundles the daemon and runs its macOS-only tests; the script tests build it.
    (("vcs/*",), {"rust", "app", "scripts"}),
    # The app's setup-go and the CLI it compiles read the toolchain from go.mod.
    (("go.mod", "go.sum"), {"cli", "app", "scripts"}),
    # KeyboardShortcutsDocsTests reads this page; cmd/docs_test.go and internal/docsite read all.
    (("docs-site/pages/reference/keyboard-shortcuts.md",), {"cli", "app"}),
    (("docs-site/*",), {"cli"}),
    # Go sources only: a data file under cmd/ or internal/ (channel_cases.tsv, which the app and
    # the script tests read) has no rule and so runs everything.
    (("*.go", ".golangci.yml", ".goreleaser.yml"), {"cli"}),
    # Read by no job's tests. The `workflows` job, which is never filtered, covers scripts/ci/.
    (("docs/*", "*.md", ".agents/*", ".claude/*", ".out-of-scope/*", ".gstack/*", "scripts/ci/*",
      "MIT-LICENSE"), frozenset()),
)


def jobs_for(path):
    for patterns, jobs in RULES:
        if any(fnmatchcase(path, pattern) for pattern in patterns):
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
