import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from changes import should_run


class ChangeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        previous = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(os.chdir, previous)
        self.git("init", "-q")
        Path("website").mkdir()
        Path("website/index.html").write_text("website")
        Path("main.go").write_text("native code")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self):
        self.git("add", "-A")
        self.git("-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_website_only(self):
        Path("website/index.html").write_text("changed")
        Path("website/new\npage.html").write_text("new")
        self.assertFalse(should_run(self.base, self.commit()))

    def test_mixed_changes(self):
        Path("website/index.html").write_text("changed")
        Path("main.go").write_text("changed")
        self.assertTrue(should_run(self.base, self.commit()))

    def test_rename_into_website_keeps_native_deletion(self):
        Path("main.go").rename("website/main.go")
        self.assertTrue(should_run(self.base, self.commit()))

    def test_rename_out_of_website(self):
        Path("website/index.html").rename("index.html")
        self.assertTrue(should_run(self.base, self.commit()))

    def test_deleted_website_file(self):
        Path("website/index.html").unlink()
        self.assertFalse(should_run(self.base, self.commit()))

    def test_missing_or_empty_history_runs(self):
        for base in (None, "", "0" * 40, "missing-ref", self.base):
            with self.subTest(base=base):
                self.assertTrue(should_run(base, self.base))


if __name__ == "__main__":
    unittest.main()
