#!/usr/bin/env python3
"""Watch a PR's CI checks, printing transitions and returning promptly on failure."""

import argparse
import json
import subprocess
import time


FIELDS = "number,url,headRefOid,state,isDraft,mergeStateStatus,statusCheckRollup"


class SnapshotError(Exception):
    def __init__(self, message, retry=False):
        super().__init__(message)
        self.retry = retry


def read_snapshot(pr=None, repo=None):
    command = ["gh", "pr", "view"]
    if pr:
        command.append(pr)
    if repo:
        command += ["--repo", repo]
    command += ["--json", FIELDS]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired as error:
        raise SnapshotError("GitHub request timed out", retry=True) from error
    if result.returncode:
        message = result.stderr.strip()
        permanent = any(text in message.lower() for text in (
            "http 401", "http 404", "gh auth login", "no pull requests found",
            "could not resolve to a pullrequest", "could not resolve to a repository",
            "not a git repository", "no git remotes found",
        )) or ("http 403" in message.lower() and "rate limit" not in message.lower())
        raise SnapshotError(f"gh pr view failed: {message[-1000:]}", retry=not permanent)
    try:
        snapshot = json.loads(result.stdout)
        if (snapshot["state"] not in ("OPEN", "CLOSED", "MERGED")
                or not snapshot["headRefOid"] or not snapshot["url"]):
            raise ValueError("missing PR state or head")
        return snapshot
    except (ValueError, KeyError, TypeError) as error:
        raise SnapshotError("Unexpected GitHub PR snapshot; no passing verdict issued") from error


def pr_reader(pr=None, repo=None):
    def read():
        nonlocal pr, repo
        snapshot = read_snapshot(pr, repo)
        # Keep watching this PR even if the user checks out another branch while CI runs.
        pr, repo = snapshot["url"], None
        return snapshot
    return read


def evaluate(snapshot, expect):
    entries = []
    names = set()
    for check in snapshot.get("statusCheckRollup") or []:
        kind = check.get("__typename")
        if kind == "CheckRun":
            name = check["name"]
            detail = (check.get("conclusion") or check["status"]).lower()
            state = "pending" if check["status"].lower() != "completed" else (
                "pass" if detail in ("success", "neutral") else
                "skip" if detail == "skipped" else "fail"
            )
            workflow = check.get("workflowName") or ""
            url = check.get("detailsUrl") or ""
        elif kind == "StatusContext":
            name = check["context"]
            detail = check["state"].lower()
            state = "pass" if detail == "success" else (
                "pending" if detail in ("pending", "expected") else "fail"
            )
            workflow = ""
            url = check.get("targetUrl") or ""
        else:
            raise SnapshotError(f"Unknown check type {kind!r}; no passing verdict issued")
        entries.append(((kind, workflow, name, url), (state, detail)))
        names.add(name)
    # Names and optional links do not uniquely identify a check. Preserve every row,
    # with a stable ordering so API list reordering does not produce progress noise.
    rows = {}
    occurrences = {}
    for key, status in sorted(entries):
        index = occurrences.get(key, 0)
        occurrences[key] = index + 1
        rows[*key, index] = status
    missing = tuple(sorted(set(expect) - names)) if not snapshot.get("isDraft") else ()
    return rows, missing


def identity(snapshot, rows, missing):
    return (snapshot["headRefOid"], snapshot["state"], snapshot.get("isDraft"),
            snapshot.get("mergeStateStatus"), tuple(sorted(rows.items())), missing)


def label(key):
    return f"{key[1]} / {key[2]}" if key[1] else key[2]


def watch(read, emit, *, now=time.monotonic, sleep=time.sleep, interval=15, timeout=1800,
          expect=(), settle=30, registration_grace=180, expect_grace=600, outage=300):
    start = now()
    head = None
    seen = {}
    last_missing = None
    signature = None
    changed_at = start
    head_since = start
    outage_since = None
    cached = None
    while now() - start < timeout:
        try:
            snapshot = cached if cached is not None else read()
            cached = None
            rows, missing = evaluate(snapshot, expect)
            if snapshot["headRefOid"] != head:
                head = snapshot["headRefOid"]
                head_since = now()
                seen = {}
                last_missing = None
                signature = None
                emit(f"PR #{snapshot['number']} @ {head}: watching checks")
            current = identity(snapshot, rows, missing)
            if current != signature:
                signature = current
                changed_at = now()
            for key, status in sorted(rows.items()):
                if seen.get(key) != status:
                    emit(f"{status[0]:7} {label(key)} ({status[1]})")
                    if status[0] == "fail" and key[3]:
                        emit(f"        {key[3]}")
            seen = rows
            if missing != last_missing:
                if missing:
                    emit("Waiting for expected checks: " + ", ".join(missing))
                elif last_missing:
                    emit("All expected checks have registered")
                last_missing = missing

            failed = sum(status[0] == "fail" for status in rows.values())
            pending = sum(status[0] == "pending" for status in rows.values())
            outcome = None
            if snapshot["state"] == "MERGED":
                outcome = 0, "already merged"
            elif snapshot["state"] == "CLOSED":
                outcome = 1, "closed without merge"
            elif snapshot.get("mergeStateStatus") == "DIRTY":
                outcome = 2, "conflicts with the base branch"
            elif failed:
                outcome = 1, f"{failed} failed; {pending} other checks still pending"
            elif not rows:
                grace = max(registration_grace, expect_grace) if missing else registration_grace
                if now() - head_since >= grace:
                    outcome = 4, "no checks registered"
            elif not pending:
                if missing and now() - changed_at >= expect_grace:
                    outcome = 1, "expected checks never registered: " + ", ".join(missing)
                elif not missing and now() - changed_at >= settle:
                    passed = sum(status[0] == "pass" for status in rows.values())
                    skipped = sum(status[0] == "skip" for status in rows.values())
                    outcome = 0, f"checks passed ({passed} passed, {skipped} skipped)"
            if outcome:
                # A push or rerun during this read must not yield a verdict for stale checks.
                latest = read()
                latest_rows, latest_missing = evaluate(latest, expect)
                if identity(latest, latest_rows, latest_missing) != current:
                    cached = latest
            if outage_since is not None:
                emit("GitHub connection restored")
                outage_since = None
            if cached is not None:
                continue
            if outcome:
                emit(f"PR #{snapshot['number']} @ {head}: {outcome[1]}")
                return outcome[0]
        except SnapshotError as error:
            if not error.retry:
                emit(str(error))
                return 5
            if outage_since is None:
                outage_since = now()
                emit(f"GitHub unavailable; retrying: {error}")
            if now() - outage_since >= outage:
                emit("GitHub remained unavailable; no passing verdict issued")
                return 5
        sleep(min(interval, max(0, timeout - (now() - start))))
    pending_names = [label(key) for key, status in seen.items() if status[0] == "pending"]
    details = []
    if pending_names:
        details.append("pending: " + ", ".join(sorted(pending_names)))
    if last_missing:
        details.append("missing: " + ", ".join(last_missing))
    emit(f"Timed out watching {head or 'the PR'}; " + ("; ".join(details) or "checks not settled"))
    return 3


def positive(value):
    result = float(value)
    if not 0 < result < float("inf"):
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pr", nargs="?", help="PR number, URL or branch; defaults to this branch")
    parser.add_argument("--repo", help="GitHub OWNER/REPO; defaults to the current repository")
    parser.add_argument("--expect", action="append", default=[], help="check name that registers late")
    parser.add_argument("--interval", type=positive, default=15)
    parser.add_argument("--timeout", type=positive, default=1800)
    args = parser.parse_args()
    try:
        return watch(pr_reader(args.pr, args.repo), lambda text: print(text, flush=True),
                     interval=args.interval, timeout=args.timeout, expect=args.expect)
    except (OSError, KeyError, TypeError) as error:
        print(f"Cannot read checks: {error}; no passing verdict issued", flush=True)
        return 5


if __name__ == "__main__":
    raise SystemExit(main())
