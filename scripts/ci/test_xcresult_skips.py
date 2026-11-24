"""Tests for the nightly UI-test run's skip gate."""

import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from xcresult_skips import main, problems, skipped


def case(name, result):
    return {"nodeType": "Test Case", "nodeIdentifier": name, "name": name, "result": result}


def tree(*cases):
    suite = {"nodeType": "Test Suite", "name": "S", "result": "Passed", "children": list(cases)}
    bundle = {"nodeType": "UI test bundle", "name": "B", "children": [suite]}
    return {"testNodes": [{"nodeType": "Test Plan", "name": "P", "children": [bundle]}]}


class SkippedTests(unittest.TestCase):
    def test_finds_skipped_cases_at_any_depth(self):
        t = tree(case("A/testOne()", "Passed"), case("A/testTwo()", "Skipped"))
        self.assertEqual(skipped(t["testNodes"]), ["A/testTwo()"])

    def test_a_skipped_case_is_not_searched_below(self):
        # Repetitions under a retried case are its own runs, not more cases.
        c = case("A/testTwo()", "Skipped")
        c["children"] = [{"nodeType": "Repetition", "result": "Skipped"}]
        self.assertEqual(skipped(tree(c)["testNodes"]), ["A/testTwo()"])


class ProblemsTests(unittest.TestCase):
    def test_an_unlisted_skip_fails(self):
        t = tree(case("A/testTwo()", "Skipped"))
        self.assertEqual(
            problems(t, {"skippedTests": 1}, set()), ["unexpected skip: A/testTwo()"])

    def test_an_allowed_skip_passes(self):
        t = tree(case("A/testTwo()", "Skipped"))
        self.assertEqual(problems(t, {"skippedTests": 1}, {"A/testTwo()"}), [])

    def test_no_skips_pass(self):
        self.assertEqual(problems(tree(case("A/t()", "Passed")), {"skippedTests": 0}, set()), [])

    def test_a_count_the_walk_misses_fails(self):
        # A format change that hides skipped cases from the walk must not read as none.
        self.assertEqual(len(problems(tree(), {"skippedTests": 2}, set())), 1)


class MainTests(unittest.TestCase):
    def run_main(self, path, allowed=""):
        t = tree(case("A/testTwo()", "Skipped"))
        reads = {"tests": t, "summary": {"skippedTests": 1}}
        out = io.StringIO()
        with redirect_stdout(out):
            status = main([str(path)], {"ALLOWED_SKIPS": allowed}, lambda kind, _: reads[kind])
        return status, out.getvalue()

    def test_reads_the_newest_bundle_in_a_logs_dir(self):
        with tempfile.TemporaryDirectory() as d:
            for stamp in ("2026.11.01", "2026.11.02"):
                (Path(d) / f"Test-WorkroomAppUITests-{stamp}.xcresult").mkdir()
            status, out = self.run_main(d, "A/testTwo()\n")
            self.assertEqual(status, 0)
            self.assertIn("2026.11.02", out)

    def test_fails_on_an_unlisted_skip(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "Test-WorkroomAppUITests-x.xcresult").mkdir()
            status, out = self.run_main(d)
            self.assertEqual(status, 1)
            self.assertIn("unexpected skip: A/testTwo()", out)

    def test_fails_without_a_bundle(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.run_main(d)[0], 1)


if __name__ == "__main__":
    unittest.main()
