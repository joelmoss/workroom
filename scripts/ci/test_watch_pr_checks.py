"""Regression tests for CI waiting; all network calls and time are controlled."""

import copy
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from watch_pr_checks import FIELDS, SnapshotError, pr_reader, read_snapshot, watch


def check(name="app", status="completed", conclusion="success"):
    return {"__typename": "CheckRun", "name": name, "status": status,
            "conclusion": conclusion, "workflowName": "CI",
            "detailsUrl": f"https://github.com/owner/repo/actions/runs/1/job/{name}"}


def snapshot(checks=None, **changes):
    return {"number": 1, "url": "https://github.com/owner/repo/pull/1",
            "headRefOid": "a" * 40, "state": "OPEN", "isDraft": False,
            "mergeStateStatus": "CLEAN", "statusCheckRollup": checks or [], **changes}


class WatchTests(unittest.TestCase):
    def run_watch(self, snapshots, **options):
        clock = [0]
        index = [0]
        messages = []

        def read():
            value = snapshots[min(index[0], len(snapshots) - 1)]
            index[0] += 1
            if isinstance(value, Exception):
                raise value
            return copy.deepcopy(value)

        def sleep(seconds):
            clock[0] += seconds

        code = watch(read, messages.append, now=lambda: clock[0], sleep=sleep,
                     **{"interval": 1, "timeout": 15, "settle": 1, **options})
        return code, messages, clock[0]

    def test_failure_returns_while_other_jobs_are_still_running(self):
        code, messages, elapsed = self.run_watch([
            snapshot([check("rust", conclusion="failure"), check(status="in_progress", conclusion=None)])
        ])
        self.assertEqual(code, 1)
        self.assertEqual(elapsed, 0)
        self.assertIn("1 failed; 1 other checks still pending", messages[-1])
        self.assertTrue(any("/job/rust" in line for line in messages))

    def test_unchanged_checks_are_quiet(self):
        queued = snapshot([check(status="queued", conclusion=None)])
        code, messages, _ = self.run_watch([queued, queued, snapshot([check()])])
        self.assertEqual(code, 0)
        self.assertEqual(sum("CI / app" in line for line in messages), 2)

    def test_new_head_during_failure_confirmation_is_followed(self):
        newer = {"headRefOid": "b" * 40}
        code, messages, _ = self.run_watch([
            snapshot([check(conclusion="failure")]),
            snapshot([check(status="queued", conclusion=None)], **newer),
            snapshot([check()], **newer),
        ])
        self.assertEqual(code, 0)
        self.assertIn("b" * 40, messages[-1])

    def test_new_head_restarts_settle_window(self):
        code, _, elapsed = self.run_watch([
            snapshot([check()]), snapshot([check()], headRefOid="b" * 40),
        ], settle=2)
        self.assertEqual(code, 0)
        self.assertEqual(elapsed, 3)

    def test_late_check_during_confirmation_prevents_early_success(self):
        code, messages, elapsed = self.run_watch([
            snapshot([check()]),
            snapshot([check(), check("review", status="queued", conclusion=None)]),
            snapshot([check(), check("review")]),
        ], settle=0)
        self.assertEqual(code, 0)
        self.assertGreater(elapsed, 0)
        self.assertTrue(any(line.startswith("pending") and "review" in line for line in messages))

    def test_expected_check_can_register_after_other_jobs_finish(self):
        code, messages, _ = self.run_watch([
            snapshot([check()]), snapshot([check()]), snapshot([check(), check("review")]),
        ], expect=["review"], expect_grace=5)
        self.assertEqual(code, 0)
        self.assertIn("All expected checks have registered", messages)

    def test_missing_expected_check_fails_after_grace(self):
        code, messages, _ = self.run_watch([snapshot([check()])], expect=["review"], expect_grace=2)
        self.assertEqual(code, 1)
        self.assertIn("expected checks never registered: review", messages[-1])

    def test_draft_does_not_wait_for_review_bot_checks(self):
        code, _, _ = self.run_watch([snapshot([check()], isDraft=True)], expect=["review"])
        self.assertEqual(code, 0)

    def test_no_checks_is_not_success(self):
        code, _, _ = self.run_watch([snapshot()], registration_grace=2)
        self.assertEqual(code, 4)

    def test_neutral_and_skipped_are_reported_separately(self):
        code, messages, _ = self.run_watch([
            snapshot([check(conclusion="neutral"), check("docs-deploy", conclusion="skipped")])
        ])
        self.assertEqual(code, 0)
        self.assertIn("1 passed, 1 skipped", messages[-1])

    def test_legacy_status_does_not_hide_same_named_failed_check(self):
        code, _, _ = self.run_watch([snapshot([
            check(conclusion="failure"),
            {"__typename": "StatusContext", "context": "app", "state": "SUCCESS"},
        ])])
        self.assertEqual(code, 1)

    def test_optional_links_are_not_used_to_discard_duplicate_named_checks(self):
        failed = check(conclusion="failure")
        passed = check()
        failed["detailsUrl"] = passed["detailsUrl"] = ""
        code, _, _ = self.run_watch([snapshot([failed, passed])])
        self.assertEqual(code, 1)

    def test_unknown_check_type_does_not_issue_a_pass(self):
        code, _, _ = self.run_watch([snapshot([{"__typename": "FutureCheck"}])])
        self.assertEqual(code, 5)

    def test_timeout_is_not_success(self):
        code, messages, _ = self.run_watch(
            [snapshot([check(status="queued", conclusion=None)])], timeout=2
        )
        self.assertEqual(code, 3)
        self.assertIn("pending: CI / app", messages[-1])

    def test_conflict_closed_and_merged_states(self):
        for changes, wanted in (({"mergeStateStatus": "DIRTY"}, 2),
                                ({"state": "CLOSED"}, 1), ({"state": "MERGED"}, 0)):
            with self.subTest(changes=changes):
                code, _, _ = self.run_watch([snapshot(**changes)])
                self.assertEqual(code, wanted)

    def test_api_outage_has_one_notice_then_recovery(self):
        error = SnapshotError("connection lost", retry=True)
        code, messages, _ = self.run_watch([error, error, snapshot([check()])])
        self.assertEqual(code, 0)
        self.assertEqual(sum("retrying" in line for line in messages), 1)
        self.assertEqual(messages.count("GitHub connection restored"), 1)

    def test_permanent_and_prolonged_api_errors_do_not_issue_a_pass(self):
        for error in (SnapshotError("not authenticated"), SnapshotError("offline", retry=True)):
            with self.subTest(error=str(error)):
                code, _, _ = self.run_watch([error], outage=2)
                self.assertEqual(code, 5)

    def test_failed_confirmation_requests_do_not_reset_outage_budget(self):
        ok = snapshot([check()])
        error = SnapshotError("offline", retry=True)
        code, _, elapsed = self.run_watch([ok, error, ok, error, ok, error], settle=0, outage=2)
        self.assertEqual(code, 5)
        self.assertEqual(elapsed, 2)


class SnapshotTests(unittest.TestCase):
    @patch("watch_pr_checks.read_snapshot")
    def test_reader_pins_the_initial_pr_before_the_user_can_switch_branches(self, read):
        read.return_value = snapshot()
        reader = pr_reader(None, "owner/repo")
        reader()
        reader()
        self.assertEqual(read.call_args_list[0].args, (None, "owner/repo"))
        self.assertEqual(read.call_args_list[1].args, (snapshot()["url"], None))

    @patch("watch_pr_checks.subprocess.run")
    def test_read_uses_only_the_requested_pr_and_read_only_json_fields(self, run):
        run.return_value = SimpleNamespace(returncode=0, stdout=json.dumps(snapshot()), stderr="")
        self.assertEqual(read_snapshot("545", "joelmoss/workroom"), snapshot())
        self.assertEqual(run.call_args.args[0], [
            "gh", "pr", "view", "545", "--repo", "joelmoss/workroom", "--json", FIELDS,
        ])

    @patch("watch_pr_checks.subprocess.run")
    def test_invalid_payload_is_a_protocol_error(self, run):
        for payload in ("not JSON", "{}", "null"):
            with self.subTest(payload=payload):
                run.return_value = SimpleNamespace(returncode=0, stdout=payload, stderr="")
                with self.assertRaises(SnapshotError):
                    read_snapshot()

    @patch("watch_pr_checks.subprocess.run")
    def test_authentication_fails_fast_but_rate_limits_retry(self, run):
        for message, retry in (("HTTP 401: bad credentials", False),
                               ("HTTP 403: API rate limit exceeded", True)):
            run.return_value = SimpleNamespace(returncode=1, stdout="", stderr=message)
            with self.assertRaises(SnapshotError) as failure:
                read_snapshot()
            self.assertEqual(failure.exception.retry, retry)


if __name__ == "__main__":
    unittest.main()
