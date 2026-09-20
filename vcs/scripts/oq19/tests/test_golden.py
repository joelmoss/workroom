#!/usr/bin/env python3
"""The golden-trace contract (plan decision D2): every fixture under golden/ replays, at the frozen configuration,
to EXACTLY the change-points in its expected.jsonl, and those verdicts pass the gates recorded in gates.json.
The Rust wakefulness service must pass the same replay. Rebuild with golden/build.py only for a NEW frozen
configuration, never to make a failing port pass."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import analyze as A  # noqa: E402
import gates  # noqa: E402

GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "golden")
FROZEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", "frozen.json")


class Golden(unittest.TestCase):
    def fixtures(self):
        return sorted(d for d in os.listdir(GOLDEN) if os.path.isfile(os.path.join(GOLDEN, d, "expected.jsonl")))

    def test_there_are_fixtures_and_each_replays_to_its_expected_change_points(self):
        with open(FROZEN) as f:
            frozen = json.load(f)
        c = A.Config(**frozen["config"])
        names = self.fixtures()
        self.assertGreaterEqual(len(names), 8, names)
        for name in names:
            d = os.path.join(GOLDEN, name)
            run = A.Run.load(d, name)
            got = A.verdict_series(A.effective(c, run), run.feats(c.interval, c.exclusions), A.window_for(c, run))
            want = [(r["t"], r["verdict"]) for r in A.load_jsonl(os.path.join(d, "expected.jsonl"))]
            self.assertEqual(got, want, name)
            res = gates.evaluate(got, run.intervals(), c.interval, A.window_for(c, run),
                                 d3_fallback=frozen.get("d3_fallback", False) and run.scenario == "3b")
            with open(os.path.join(d, "gates.json")) as f:
                self.assertEqual({g: s for g, (s, _) in res.items()}, json.load(f), name)
            self.assertTrue(all(s == gates.PASS for s, _ in res.values()), (name, res))

    def test_a_changed_parameter_breaks_the_contract(self):
        """Mutation check: the fixtures are sensitive to the configuration they were built with."""
        with open(FROZEN) as f:
            frozen = json.load(f)
        c = A.Config(**frozen["config"])._replace(cpu=1e9, pty=1e9, net=None, grace=0.0)
        name = "5-detached-full-r0"
        d = os.path.join(GOLDEN, name)
        run = A.Run.load(d, name)
        got = A.verdict_series(c, run.feats(c.interval, c.exclusions), A.window_for(c, run))
        want = [(r["t"], r["verdict"]) for r in A.load_jsonl(os.path.join(d, "expected.jsonl"))]
        self.assertNotEqual(got, want)


if __name__ == "__main__":
    unittest.main()
