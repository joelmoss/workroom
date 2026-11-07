"""Regression tests for the path filter that decides which CI jobs a pull request runs."""

import io
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from changed_areas import JOBS, areas, main


def needed(*paths):
    return {job for job, run in areas(paths).items() if run}


class ChangedAreasTests(unittest.TestCase):
    def test_go_sources_run_only_the_cli_job(self):
        self.assertEqual(needed("cmd/list.go", "internal/vcs/vcs_test.go", "main.go"), {"cli"})

    def test_a_data_file_beside_the_go_code_runs_everything(self):
        # channel_cases.tsv is read by the app's ReleaseChannelTests and channel-helper_test.sh.
        self.assertEqual(needed("internal/channel/testdata/channel_cases.tsv"), set(JOBS))

    def test_the_shared_fixtures_run_everything(self):
        self.assertEqual(needed("testdata/twins/login_shell.tsv"), set(JOBS))

    def test_ci_and_build_plumbing_run_everything(self):
        for path in (".github/workflows/ci-app.yml", ".github/actions/install-zig/action.yml",
                     "Makefile", "mk/cli.mk"):
            with self.subTest(path=path):
                self.assertEqual(needed(path), set(JOBS))

    def test_the_daemon_runs_rust_and_everything_that_bundles_it(self):
        self.assertEqual(needed("vcs/crates/workroomd/src/main.rs"), {"rust", "app", "scripts"})

    def test_the_bootstrap_scripts_also_run_rust(self):
        self.assertEqual(needed("macapp/Resources/daemon-bootstrap/probe.sh"),
                         {"rust", "app", "scripts"})

    def test_app_sources_skip_the_packages_and_rust(self):
        self.assertEqual(needed("macapp/WorkroomApp/Views/AppShell/RootView.swift"),
                         {"app", "scripts"})

    def test_package_sources_run_the_packages_and_the_app(self):
        self.assertEqual(needed("macapp/Packages/WorkroomDomain/Sources/WorkroomDomain/X.swift"),
                         {"packages", "app", "scripts"})

    def test_go_mod_runs_everything_that_builds_the_cli(self):
        self.assertEqual(needed("go.mod"), {"cli", "app", "scripts"})

    def test_docs_site_runs_the_go_checks_and_the_shortcuts_page_the_app(self):
        self.assertEqual(needed("docs-site/pages/guides/remote.md"), {"cli"})
        self.assertEqual(needed("docs-site/pages/reference/keyboard-shortcuts.md"), {"cli", "app"})

    def test_design_docs_run_nothing_filtered(self):
        self.assertEqual(needed("docs/designs/x.md", "README.md", "scripts/ci/watch_pr_checks.py"),
                         set())

    def test_markdown_inside_a_tree_follows_that_tree(self):
        self.assertEqual(needed("macapp/AGENTS.md"), {"app", "scripts"})

    def test_an_unknown_path_runs_everything(self):
        self.assertEqual(needed("install.sh"), set(JOBS))

    def test_no_paths_runs_everything(self):
        self.assertEqual(needed(), set(JOBS))
        self.assertEqual(needed(""), set(JOBS))

    def test_the_union_of_every_path(self):
        self.assertEqual(needed("cmd/list.go", "macapp/Packages/A/B.swift"),
                         {"cli", "packages", "app", "scripts"})

    def test_prints_github_output_lines(self):
        out = io.StringIO()
        with patch("sys.stdin", io.StringIO("cmd/list.go\n")), redirect_stdout(out):
            main()
        self.assertEqual(out.getvalue(), "cli=true\nrust=false\npackages=false\napp=false\n"
                         "scripts=false\n")


if __name__ == "__main__":
    unittest.main()
