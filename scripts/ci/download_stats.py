"""Daily release download counts from the snapshots scripts/ci/download-stats.sh records.

    git fetch origin download-stats
    python3 scripts/ci/download_stats.py [ref]    # ref defaults to origin/download-stats

Prints TSV: date, tag, asset, downloads. A row covers the downloads between two consecutive
snapshots, dated by the EARLIER one. The daily snapshot is scheduled just after 00:00 UTC, so
every interval starts on the day it covers. GitHub often runs crons late around midnight, so the
day boundary drifts by that delay: a run at 00:40 credits 00:00-00:40 to the previous day.

Assets are tracked by id, not name: a `--clobber` upload creates a new asset that starts at 0, and
its predecessor's final count is the snapshot taken just before the clobber. The first snapshot
only sets the baseline, since what it counted happened at unknown times.
"""

import io
import json
import subprocess
import sys
import tarfile
from collections import defaultdict


def daily(snapshots):
    """snapshots: [(ts, rows)] sorted by ts. Returns {(date, tag, asset): downloads}."""
    out = defaultdict(int)
    last = {}
    first_ts = prev_ts = snapshots[0][0] if snapshots else None
    for ts, rows in snapshots:
        for row in rows:
            seen = last.get(row["id"])
            last[row["id"]] = row["count"]
            if seen is None:
                if row["created_at"] <= first_ts:
                    continue  # existed before recording began: baseline only
                seen = 0  # uploaded since the previous snapshot, which would have listed it
            if row["count"] != seen:
                out[(prev_ts[:10], row["tag"], row["asset"])] += row["count"] - seen
        prev_ts = ts
    return dict(out)


def load(ref):
    archive = subprocess.run(["git", "archive", "--format=tar", ref, "snapshots"],
                             check=True, capture_output=True).stdout
    by_ts = defaultdict(list)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            if member.isfile():
                for line in tar.extractfile(member).read().decode().splitlines():
                    row = json.loads(line)
                    by_ts[row["ts"]].append(row)
    return sorted(by_ts.items())


if __name__ == "__main__":
    print("date\ttag\tasset\tdownloads")
    for (date, tag, asset), n in sorted(daily(load(sys.argv[1] if len(sys.argv) > 1
                                                    else "origin/download-stats")).items()):
        print(f"{date}\t{tag}\t{asset}\t{n}")
