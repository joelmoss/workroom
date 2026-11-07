"""Regression tests for the path filter that decides which CI jobs a pull request runs."""

import io
import re
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from changed_areas import JOBS, areas, main

ROOT = Path(__file__).resolve().parents[2]
GITHUB = ROOT / ".github"


def needed(*paths):
    return {job for job, run in areas(paths).items() if run}


def jobs_of(workflow):
    """Each job's name and body in a workflow's text: the 4-space lines under its 2-space key."""
    body = workflow.split("\njobs:\n", 1)[1]
    return dict(re.findall(r"^  ([\w-]+):\n((?:(?:    .*)?\n)*)", body, re.M))


def composites(text):
    """The local composite actions a job or an action uses, and those they use in turn."""
    found = set()
    for name in re.findall(r"uses: \./\.github/actions/([\w-]+)", text):
        found |= {name} | composites((GITHUB / "actions" / name / "action.yml").read_text())
    return found


def filtered_jobs():
    """Each job ci.yml's calls run behind the path filter: its workflow, the filter output it runs
    on, and the composites it uses. A job with no `if: inputs.<name>` always runs."""
    for call in jobs_of((GITHUB / "workflows" / "ci.yml").read_text()).values():
        called = re.search(r"uses: \./\.github/workflows/(\S+)", call)
        if not called:
            continue
        outputs = dict(re.findall(
            r"^\s+([\w-]+): \$\{\{ needs\.changes\.outputs\.(\w+) != 'false' \}\}", call, re.M))
        workflow = called[1]
        for job in jobs_of((GITHUB / "workflows" / workflow).read_text()).values():
            gate = re.search(r"^    if: inputs\.([\w-]+)$", job, re.M)
            if gate:
                yield workflow, outputs[gate[1]], composites(job)


class ChangedAreasTests(unittest.TestCase):
    def test_go_sources_run_only_the_cli_job(self):
        self.assertEqual(needed("cmd/list.go", "internal/vcs/vcs_test.go", "main.go"), {"cli"})

    def test_a_data_file_beside_the_go_code_runs_everything(self):
        # channel_cases.tsv is read by the app's ReleaseChannelTests and channel-helper_test.sh.
        self.assertEqual(needed("internal/channel/testdata/channel_cases.tsv"), set(JOBS))

    def test_each_fixture_table_runs_the_jobs_that_read_it(self):
        cases = {
            "testdata/contracts/list.json": {"cli", "packages", "app"},
            "testdata/contracts/create-events.ndjson": {"cli", "packages", "app"},
            "testdata/contracts/frames.tsv": {"rust", "packages"},
            "testdata/twins/login_shell.tsv": {"cli", "rust", "packages", "app"},
            "testdata/twins/split_base.tsv": {"cli", "rust", "packages", "app"},
            "testdata/program-status/status.json": {"rust", "packages", "app"},
            "testdata/script-env/local.txt": {"cli", "rust", "app"},
            "testdata/fixtures/setup": {"cli"},
        }
        for path, jobs in cases.items():
            with self.subTest(path=path):
                self.assertEqual(needed(path), jobs)

    def test_a_new_fixture_tree_runs_everything(self):
        self.assertEqual(needed("testdata/new-table/cases.tsv"), set(JOBS))

    def test_each_workflow_runs_its_own_jobs(self):
        cases = {
            ".github/workflows/ci.yml": set(JOBS),
            ".github/workflows/ci-go.yml": {"cli"},
            ".github/workflows/ci-rust.yml": {"rust"},
            ".github/workflows/ci-app.yml": {"packages", "app", "scripts"},
            ".github/workflows/release.yml": {"scripts"},
            ".github/workflows/nightly.yml": {"scripts"},
            ".github/workflows/ci-actions.yml": set(),
            ".github/workflows/download-stats.yml": set(),
        }
        for path, jobs in cases.items():
            with self.subTest(path=path):
                self.assertEqual(needed(path), jobs)

    def test_each_composite_runs_the_jobs_that_use_it(self):
        cases = {
            ".github/actions/setup-app-build/action.yml": {"packages", "app", "scripts"},
            ".github/actions/setup-daemon-build/action.yml": {"app", "scripts"},
            ".github/actions/install-zig/action.yml": {"rust", "app", "scripts"},
            ".github/actions/install-cargo-zigbuild/action.yml": {"rust", "app", "scripts"},
            ".github/actions/import-signing-certificate/action.yml": set(),
        }
        for path, jobs in cases.items():
            with self.subTest(path=path):
                self.assertEqual(needed(path), jobs)

    def test_repository_settings_and_templates_run_nothing_filtered(self):
        self.assertEqual(needed(".github/dependabot.yml", ".github/CODEOWNERS",
                                ".github/PULL_REQUEST_TEMPLATE.md",
                                ".github/ISSUE_TEMPLATE/bug_report.yml"), set())

    def test_the_makefile_and_the_app_targets_run_the_macos_jobs(self):
        for path in ("Makefile", "mk/app.mk"):
            with self.subTest(path=path):
                self.assertEqual(needed(path), {"packages", "app", "scripts"})

    def test_the_other_areas_make_targets_run_nothing_filtered(self):
        self.assertEqual(needed("mk/cli.mk", "mk/docs.mk", "mk/vcs.mk", "mk/actions.mk"), set())

    def test_new_plumbing_runs_everything(self):
        for path in (".github/workflows/ci-new.yml", ".github/actions/new/action.yml",
                     ".github/new.yml", "mk/new.mk"):
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
        self.assertEqual(needed("macapp/Resources/markdown/VENDOR.md"), {"app", "scripts"})
        self.assertEqual(needed("vcs/crates/workroomd/README.md"), {"rust", "app", "scripts"})

    def test_the_apps_and_the_daemons_own_docs_run_nothing_filtered(self):
        self.assertEqual(needed("macapp/AGENTS.md", "macapp/README.md", "macapp/QA-libghostty.md",
                                "macapp/QA-libghostty-results/2026-08-12-bump.md",
                                "vcs/scripts/oq19/results/boxd.md"), set())

    def test_the_oq19_scripts_still_run_the_daemon_jobs(self):
        self.assertEqual(needed("vcs/scripts/oq19/run.sh"), {"rust", "app", "scripts"})

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


class WorkflowReadersTests(unittest.TestCase):
    """The .github rules, checked against the workflows they describe rather than restated."""

    def test_every_filtered_job_is_found(self):
        found = {(workflow, job) for workflow, job, _ in filtered_jobs()}
        self.assertEqual({job for _, job in found}, set(JOBS))

    def test_a_workflow_runs_every_job_it_holds(self):
        for workflow, job, _ in filtered_jobs():
            with self.subTest(workflow=workflow, job=job):
                self.assertIn(job, needed(f".github/workflows/{workflow}"))

    def test_a_composite_runs_every_job_that_uses_it(self):
        for workflow, job, used in filtered_jobs():
            for name in used:
                with self.subTest(composite=name, job=job):
                    self.assertIn(job, needed(f".github/actions/{name}/action.yml"))

    def test_a_workflow_that_runs_the_app_tests_runs_the_invariants_that_check_it(self):
        # test-invariants_test.sh, which app-scripts runs, fails when a workflow that ran
        # `make app-test` or `make app-package-test` stops running it.
        for path in sorted((GITHUB / "workflows").glob("*.yml")):
            if re.search(r"make app-(package-)?test([^-]|$)", path.read_text(), re.M):
                with self.subTest(workflow=path.name):
                    self.assertIn("scripts", needed(f".github/workflows/{path.name}"))


if __name__ == "__main__":
    unittest.main()
