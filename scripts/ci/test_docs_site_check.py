"""Tests for the check that a user-facing change brings its docs-site/ change."""

import io
import os
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from docs_site_check import USER_FACING, WAIVER, main, problems

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = "macapp/WorkroomApp/Views/AppShell/SettingsView.swift"


class ProblemsTests(unittest.TestCase):
    def test_a_user_facing_change_without_docs_is_a_problem(self):
        self.assertEqual(problems([SETTINGS, "macapp/Other.swift"], []), [SETTINGS])

    def test_a_docs_site_change_satisfies_it(self):
        self.assertEqual(problems([SETTINGS, "docs-site/pages/settings.md"], []), [])

    def test_the_waiver_label_satisfies_it(self):
        self.assertEqual(problems([SETTINGS], [WAIVER, "bug"]), [])

    def test_other_changes_need_no_docs(self):
        self.assertEqual(problems(["macapp/Other.swift", "docs/macapp/ui.md"], []), [])

    def test_every_user_facing_file_exists(self):
        # A renamed file would silently stop being checked.
        for path in USER_FACING:
            self.assertTrue((ROOT / path).is_file(), path)


class MainTests(unittest.TestCase):
    def run_main(self, paths, labels="[]"):
        out = io.StringIO()
        with patch("sys.stdin", io.StringIO("\n".join(paths) + "\n")), \
                patch.dict(os.environ, {"PR_LABELS": labels}), redirect_stdout(out):
            status = main()
        return status, out.getvalue()

    def test_fails_naming_the_file(self):
        status, out = self.run_main([SETTINGS])
        self.assertEqual(status, 1)
        self.assertIn(f"::error file={SETTINGS}::", out)
        self.assertIn(WAIVER, out)

    def test_passes_with_the_waiver(self):
        status, _ = self.run_main([SETTINGS], f'["{WAIVER}"]')
        self.assertEqual(status, 0)

    def test_passes_with_no_labels_set(self):
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "PR_LABELS"}
        with patch("sys.stdin", io.StringIO("README.md\n")), patch.dict(os.environ, env, clear=True), \
                redirect_stdout(out):
            self.assertEqual(main(), 0)


if __name__ == "__main__":
    unittest.main()
