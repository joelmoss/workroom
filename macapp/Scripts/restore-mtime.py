#!/usr/bin/env python3
"""Give every tracked file the mtime of the last commit that touched it.

A fresh checkout stamps every file with the checkout time, and xcodebuild's incremental check
keys on mtimes: against a restored DerivedData/Build every one of the app's own sources then
reads as changed and recompiles (~5 minutes of CI's app job, measured 2026-10-18), while nothing
in them did. Commit times are the same on every runner, so after this a cached build sees only
the files commits since it have actually touched.

Runs from the repository root in CI, before the build. Needs the history (`fetch-depth: 0`): in a
shallow clone, files older than the fetched window all get the boundary commit's time, which still
beats the checkout time but shifts as the window moves. Standard library only, like gui-lock.py.

The walk follows the first parents, with a merge listing what it brought in: a file's time is
when its change LANDED on the branch being built, which only moves forward along that branch,
rather than its author's commit time, which a merged branch may have had for weeks.

`--fresh <index file> <dir>`: every tracked path under <dir> whose entry differs between that file
and the checkout (`git ls-files -s -z` output for both), and every directory above one (a deleted
file changes only its directory), gets the present time instead. cargo decides "up to date" by mtime
newer-than the cached artifact, not by content, so a file that differs from what the cache was
built from but whose landing time is older than that build (a release branch that restored
master's cache; a master push after one whose run failed and saved nothing) would read as
unchanged and CI would test the cached build of the old code (measured: a content change with an
older mtime is not recompiled). CI saves the index of the checkout each cache was built from
inside the cached directory. An index rather than a commit: a PR run builds GitHub's merge
commit, which the next push's checkout no longer has, so a commit could not be diffed against.
Only under <dir> (CI passes the cargo workspace, vcs): xcodebuild rebuilds a file whose mtime
differs from the one it built at either way, so a Swift file left at now would be compiled into
the saved build dir at now and then recompiled by every later run, at its landing time again.
"""

import os
import subprocess
import sys
import time


def index_entries(listing: str) -> dict[str, str]:
    # `git ls-files -s -z`: one "<mode> <blob> <stage>\t<path>" record per NUL.
    entries = {}
    for record in listing.split("\0"):
        if record:
            meta, path = record.split("\t", 1)
            entries[path] = meta
    return entries


def main() -> int:
    fresh_from = fresh_under = None
    args = sys.argv[1:]
    if args[:1] == ["--fresh"] and len(args) == 3:
        fresh_from, fresh_under = args[1], args[2].rstrip("/") + "/"
    elif args:
        print(
            "usage: restore-mtime.py [--fresh <git ls-files -s -z output> <dir>]", file=sys.stderr
        )
        return 2
    root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    ).stdout.strip()
    current = index_entries(
        subprocess.run(
            ["git", "-C", root, "ls-files", "-s", "-z"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=True,
        ).stdout
    )
    tracked = set(current)
    pending = set(tracked)
    # Newest first; a file's first appearance is its last touch. Each commit prints as a
    # `COMMIT <epoch>` line, a blank line, then one path per line. `--no-renames` so a rename
    # shows the new path as added rather than as a rename pair this parser would have to split.
    # `--first-parent -m`: a merge lists what it brought in, against its first parent.
    log = subprocess.Popen(
        [
            "git",
            "-C",
            root,
            "log",
            "--first-parent",
            "-m",
            "--format=COMMIT %ct",
            "--name-only",
            "--no-renames",
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    assert log.stdout is not None
    stamped = 0
    when = 0
    for line in log.stdout:
        if not pending:
            break
        line = line.rstrip("\n")
        if line.startswith("COMMIT "):
            when = int(line[len("COMMIT ") :])
        elif line in pending:
            pending.discard(line)
            os.utime(os.path.join(root, line), (when, when))
            stamped += 1
    log.stdout.close()
    log.terminate()
    log.wait()
    # Directories too, deepest first, each to the newest time among its entries: git tracks no
    # directory, so a checkout leaves every one at now, and cargo's `rerun-if-changed` on one reads
    # the directory's own mtime, which reran the build script, and so rebuilt the crate, on every
    # CI run.
    # Over tracked entries only: an untracked build dir inside would otherwise carry its "now" up.
    children: dict[str, set[str]] = {}
    for path in tracked:
        child = path
        parent = os.path.dirname(child)
        while parent:
            if child in children.setdefault(parent, set()):
                break
            children[parent].add(child)
            child, parent = parent, os.path.dirname(parent)
    for directory in sorted(children, key=lambda d: d.count("/"), reverse=True):
        newest = max(os.lstat(os.path.join(root, entry)).st_mtime for entry in children[directory])
        os.utime(os.path.join(root, directory), (newest, newest))
    fresh = 0
    if fresh_from is not None:
        with open(fresh_from, encoding="utf-8", newline="") as built_file:
            built = index_entries(built_file.read())
        # A moved file is two entries, so the directory it left refreshes too.
        changed = sorted(
            p
            for p in built.keys() | current.keys()
            if p.startswith(fresh_under) and built.get(p) != current.get(p)
        )
        now = time.time()
        touched = set()
        for path in changed:
            fresh += 1
            # The file if it still exists, and every directory above it either way.
            while path and path not in touched:
                touched.add(path)
                full = os.path.join(root, path)
                if os.path.lexists(full):
                    os.utime(full, (now, now))
                path = os.path.dirname(path)
    print(
        f"restore-mtime: {stamped} files stamped, {len(pending)} not in the fetched history"
        + (f", {fresh} paths differing from {fresh_from} left fresh" if fresh_from else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
