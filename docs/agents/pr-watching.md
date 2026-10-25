# Watching pull request checks and reviews

Start one background watcher from the repository root:

```sh
python3 scripts/ci/watch_pr_checks.py --expect rust --expect daemon-terminal-state --expect app
```

It discovers and pins this branch's PR through `gh`, so a later checkout does not switch the watch.
Pass a PR number or URL and `--repo OWNER/REPO` to
watch another PR. Authentication comes from `gh`; the watcher only reads PR/check metadata.
It does not post comments, push, approve or merge.

The watcher prints the current head and each check's initial state, then only changes. It exits
on a completed failure even while other jobs run, with the failed check's link. Every terminal
verdict is confirmed by a fresh snapshot: a push or rerun during the poll is followed instead of
reporting stale checks. Passing checks settle for 30 seconds for late registrations; `--expect`
names a check that must register before success. Drafts do not wait for expected review bots.

## Handling the result

| Exit | Meaning | Next step |
| --- | --- | --- |
| 0 | Checks passed, or the PR was already merged | Inspect the final message, then finish the review hand-off below if still open |
| 1 | Failed check, absent expected check, or closed unmerged PR | Read the failure, fix a demonstrated defect, commit and push if authorized; restart the watcher for the new head |
| 2 | Base conflict | Rebase if authorized, resolve, validate and watch the new head |
| 3 | Timeout | Report the pending/missing checks named in the output |
| 4 | No checks registered | Report that no gate ran; do not treat this as a pass |
| 5 | Authentication, API or protocol error | Restore access or report the error; no passing verdict was issued |

The default poll interval is 15 seconds and overall timeout 30 minutes. `--interval` and
`--timeout` accept positive seconds. A head with no checks gets a three-minute registration grace
(ten minutes when expected checks are named). A missing expected check gets up to ten minutes
after the other checks finish. Transient API failures retry
for up to five minutes; authentication/discovery errors stop immediately.

For a failed Actions job while the rest of its workflow still runs, `gh run view --log-failed`
may refuse to return logs. The check's link contains the job ID. Read that completed job directly:

```sh
gh api repos/OWNER/REPO/actions/jobs/JOB_ID/logs
```

## Review hand-off

A CI pass is not review approval. Use the available review-resolution skill/tool to fetch fresh
unanswered comments (`npx --yes agent-reviews --unanswered --expanded`) and handle genuine findings.
Keep its rules for fresh inline detail, replies after fixes, non-threadable summary skips and
recurrent-fix limits. Once the checked head is clean, run its late-comment watch once:

```sh
npx --yes agent-reviews --watch --unanswered --timeout 180
```

Check requested reviews and review decisions freshly too. New fixes return to the CI watcher.
Before an authorized merge, verify the current head, base, draft state, mergeability and completed
reviews, then guard the merge with `--match-head-commit`. This watcher grants no merge permission.

Use the emitted state transitions for progress reports. The repository can improve the watcher;
it cannot relax a higher-priority host requirement for periodic progress messages during idle waits.
