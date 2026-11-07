"""A make variable's value, read through the root Makefile's `print-%` rule.

For tests that pin a value make sets: asking make keeps them right wherever the line that sets it
moves, as the Makefile's split into mk/ moved every app and Rust variable.
"""

import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

# A make that runs this test passes its own command-line overrides down through these, which would
# report the caller's value instead of the Makefile's.
INHERITED = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES")


def make_value(name):
    env = {key: value for key, value in os.environ.items()
           if key not in INHERITED and key != name}
    result = subprocess.run(
        ["make", "-s", "--no-print-directory", "-C", str(ROOT), f"print-{name}"],
        env=env, capture_output=True, text=True, check=True, timeout=30,
    )
    return result.stdout.strip()
