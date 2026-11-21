#!/usr/bin/env python3
"""Tests for vendor-ghostty-themes.py's `stage`. Standard library only.

    python3 macapp/Scripts/vendor-ghostty-themes_test.py

Each case runs the real script as a subprocess against a throwaway themes directory
(VENDOR_GHOSTTY_THEMES_DIR) and a throwaway upstream checkout, never the bundled directory.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor-ghostty-themes.py")


def theme(seed):
    """A parseable theme whose 18 colours all differ from another seed's."""
    def colour(i):
        return "#%02x%02x%02x" % ((seed * 37 + i * 11) % 256, (seed * 53 + i * 7) % 256, (i * 13) % 256)
    lines = [f"background = {colour(16)}", f"foreground = {colour(17)}"]
    lines += [f"palette = {i}={colour(i)}" for i in range(16)]
    return "\n".join(lines) + "\n"


class StageTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vendor-themes-test-")
        self.addCleanup(shutil.rmtree, self.root)
        self.themes = os.path.join(self.root, "themes")
        self.upstream = os.path.join(self.root, "upstream")
        os.makedirs(self.themes)
        os.makedirs(self.upstream)

    def write(self, directory, name, text):
        with open(os.path.join(directory, name), "w", encoding="utf-8") as f:
            f.write(text)

    def record_checksums(self, *names):
        with open(os.path.join(self.themes, "CHECKSUMS"), "w", encoding="utf-8") as f:
            for name in names:
                with open(os.path.join(self.themes, name), "rb") as g:
                    f.write(f"{hashlib.sha256(g.read()).hexdigest()}  {name}\n")

    def stage(self):
        env = dict(os.environ, VENDOR_GHOSTTY_THEMES_DIR=self.themes)
        return subprocess.run(
            [sys.executable, "-I", SCRIPT, "stage", self.upstream], env=env, capture_output=True,
            text=True)

    def test_a_file_the_script_did_not_write_stops_the_sweep_and_nothing_is_touched(self):
        self.write(self.themes, "Old Shipped", theme(1))
        self.record_checksums("Old Shipped")
        self.write(self.themes, "notes.txt", "curation notes\n")  # hand-added, not in CHECKSUMS
        self.write(self.themes, "Edited", theme(2))
        self.record_checksums("Old Shipped", "Edited")
        self.write(self.themes, "Edited", theme(3))  # a local edit after the last full run
        self.write(self.upstream, "Fresh Theme", theme(4))

        result = self.stage()

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("notes.txt", result.stderr)
        self.assertIn("Edited", result.stderr)
        self.assertNotIn("Old Shipped", result.stderr.split("delete them:", 1)[1])
        self.assertEqual(
            sorted(os.listdir(self.themes)), ["CHECKSUMS", "Edited", "Old Shipped", "notes.txt"])
        with open(os.path.join(self.themes, "Edited"), encoding="utf-8") as f:
            self.assertEqual(f.read(), theme(3), "the local edit was overwritten")

    def test_its_own_output_is_swept_and_replaced_including_an_earlier_stage_of_this_checkout(self):
        self.write(self.themes, "Old Shipped", theme(1))
        self.record_checksums("Old Shipped")
        # Copied by an earlier `stage` of this checkout, so not in CHECKSUMS yet.
        self.write(self.upstream, "Staged Before", theme(5))
        shutil.copyfile(
            os.path.join(self.upstream, "Staged Before"),
            os.path.join(self.themes, "Staged Before"))
        self.write(self.upstream, "Fresh Theme", theme(4))

        result = self.stage()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(os.listdir(self.themes)), ["CHECKSUMS", "Fresh Theme", "Staged Before"])


if __name__ == "__main__":
    unittest.main()
