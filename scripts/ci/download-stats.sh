#!/bin/bash
#
# Record every release asset's download_count as ONE snapshot file on the `download-stats` branch.
# GitHub keeps only a running total per asset, with no history, so daily numbers exist only as the
# difference between snapshots (scripts/ci/download_stats.py computes them).
#
# Run daily (.github/workflows/download-stats.yml) AND immediately before every `--clobber` upload
# (nightly, release, appcast-notes). A clobber replaces the asset with a new one at 0, so whatever
# the old asset counted since the last snapshot is gone unless it is read first. That is how the
# appcast feeds, re-uploaded on every publish, lose their poll counts today.
#
# Each snapshot is its own file, so concurrent writers never conflict: a rejected push just
# re-reads the branch tip and retries. The commit is built with plumbing against a private index,
# which leaves the caller's checkout (and its build output) untouched.
#
# Usage: download-stats.sh <reason>
# Required env: REPO (owner/repo), GH_TOKEN. Run inside a checkout whose `origin` the token can
# push to (actions/checkout persists the credentials).
set -euo pipefail

REASON="${1:?usage: download-stats.sh <reason>}"
: "${REPO:?REPO required}"
BRANCH="download-stats"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# No colons (invalid in paths on some checkouts). The run id keeps two same-second snapshots from
# sharing a path, where the later commit would silently replace the earlier file.
FILE="snapshots/${TS//:/}-${REASON}-${GITHUB_RUN_ID:-$$}.jsonl"

SNAP="$(mktemp)"
gh api "repos/${REPO}/releases" --paginate |
  jq -c --arg ts "$TS" --arg reason "$REASON" '.[] | .tag_name as $tag | .assets[] |
    {ts: $ts, reason: $reason, tag: $tag, asset: .name, id, created_at, count: .download_count}' \
    >"$SNAP"
# An empty snapshot would read as every asset vanishing; never record one.
if [ ! -s "$SNAP" ]; then
  echo "error: the releases API returned no assets for ${REPO}; not recording an empty snapshot." >&2
  exit 1
fi
echo "Captured $(wc -l <"$SNAP" | tr -d ' ') assets → ${FILE}"

export GIT_AUTHOR_NAME="github-actions[bot]" GIT_COMMITTER_NAME="github-actions[bot]"
export GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
BLOB="$(git hash-object -w "$SNAP")"

for attempt in 1 2 3 4 5; do
  INDEX="$(mktemp -u)"
  # Only a clean "no such ref" (exit 2) starts a new orphan branch; any other failure is fatal, so
  # a network error can never orphan the branch's history.
  rc=0
  git ls-remote --exit-code origin "refs/heads/${BRANCH}" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    # ponytail: depth-1 fetch still pulls every snapshot blob in the tip tree (~30 KB each, ~2/day);
    # shard by year if this fetch ever gets slow.
    git fetch --quiet --depth 1 origin "refs/heads/${BRANCH}"
    PARENT="$(git rev-parse FETCH_HEAD)"
    GIT_INDEX_FILE="$INDEX" git read-tree "$PARENT"
  elif [ "$rc" -eq 2 ]; then
    PARENT=""
    GIT_INDEX_FILE="$INDEX" git read-tree --empty
  else
    echo "error: could not read origin's ${BRANCH} branch (git ls-remote exit ${rc})." >&2
    exit 1
  fi
  GIT_INDEX_FILE="$INDEX" git update-index --add --cacheinfo "100644,${BLOB},${FILE}"
  TREE="$(GIT_INDEX_FILE="$INDEX" git write-tree)"
  rm -f "$INDEX"
  COMMIT="$(git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "Download stats: ${REASON} ${TS}")"
  # Never forced: losing a race is a non-fast-forward rejection, then a retry on the new tip.
  if git push --quiet origin "${COMMIT}:refs/heads/${BRANCH}"; then
    echo "✅ Recorded ${FILE} on ${BRANCH}"
    exit 0
  fi
  echo "Push to ${BRANCH} rejected (attempt ${attempt}); retrying on the new tip." >&2
  sleep $((attempt * 3))
done
echo "error: could not push the snapshot to ${BRANCH} after 5 attempts." >&2
exit 1
