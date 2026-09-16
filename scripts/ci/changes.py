"""Skip native suites only when every changed path belongs to the standalone website."""

import os
import subprocess


def should_run(base, head):
    if not base or not head or set(base) == {"0"}:
        return True
    try:
        paths = subprocess.check_output(
            ["git", "diff", "--no-renames", "--name-only", "-z", base, head, "--"],
            stderr=subprocess.DEVNULL,
        ).split(b"\0")
    except subprocess.CalledProcessError:
        return True
    paths = [path for path in paths if path]
    # Empty comparisons also run: missing/unexpected event data must never turn a gate off.
    return not paths or any(not path.startswith(b"website/") for path in paths)


if __name__ == "__main__":
    print(f"run={str(should_run(os.getenv('DIFF_BASE'), os.getenv('DIFF_HEAD'))).lower()}")
