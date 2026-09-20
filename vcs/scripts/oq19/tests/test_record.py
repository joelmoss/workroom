#!/usr/bin/env python3
"""Self-checks for record.py's planning: the hold-out must be what the pre-registration says, and only ever
follow a frozen, committed configuration. No containers are started."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import analyze as A  # noqa: E402
import gates  # noqa: E402
import labels  # noqa: E402
import record  # noqa: E402

FROZEN = {"config": {"policy": "P4", "cpu": 0.05, "pty": 30.0, "net": None, "wait": "agnostic", "age": None,
                     "grace": 0.0, "window": 2, "interval": 2, "staleness": True, "exclusions": True,
                     "lifecycle": True}, "key": "P4|...", "d3_fallback": True}


class Plan(unittest.TestCase):
    def test_holdout_matches_the_preregistered_sample_size(self):
        jobs, controls = record.plan_holdout(FROZEN)
        full = [j for j in jobs if not j["compressed"]]
        comp = [j for j in jobs if j["compressed"]]
        self.assertEqual({j["id"] for j in full}, {s.id for s in labels.GATED})
        self.assertTrue(all(sum(1 for j in full if j["id"] == s.id) == gates.HOLDOUT_REPEATS_FULL
                            for s in labels.GATED))
        self.assertEqual({j["id"] for j in comp}, {s.id for s in labels.CRITICAL})
        self.assertTrue(all(sum(1 for j in comp if j["id"] == s.id) == gates.HOLDOUT_REPEATS_COMPRESSED_CRITICAL
                            for s in labels.CRITICAL))
        self.assertEqual(controls, [])

    def test_every_holdout_run_is_closed_loop_at_the_winners_real_cadence(self):
        jobs, _ = record.plan_holdout(FROZEN)
        for j in jobs:
            self.assertEqual(j["interval"], 2.0)
            cl = json.loads(j["closed_loop"])
            self.assertEqual(cl["config"], FROZEN["config"])
            grid = gates.WINDOW_GRID_COMPRESSED_S if j["compressed"] else gates.WINDOW_GRID_S
            self.assertEqual(cl["window_s"], grid[2])  # the compressed run scales the policy's window

    def test_a_compressed_holdout_run_scales_the_grace_like_the_window(self):
        frozen = {"config": dict(FROZEN["config"], grace=10.0)}
        for j in record.plan_holdout(frozen)[0]:
            grace = json.loads(j["closed_loop"])["config"]["grace"]
            self.assertEqual(grace, 1.0 if j["compressed"] else 10.0, j["key"])
            self.assertTrue(j["key"].endswith("-r%d" % j["rep"]) and "-i2-" in j["key"])

    def test_holdout_seeds_never_repeat_a_tuning_seed(self):
        tuning = {j["seed"] for j in record.plan_jobs(interval=2.0)[0]}
        hold = {j["seed"] for j in record.plan_holdout(FROZEN)[0]}
        self.assertFalse(tuning & hold)

    def test_an_uncommitted_frozen_file_is_refused(self):
        with self.assertRaises(SystemExit):
            record.require_committed(os.path.join(record.REPO, "vcs", "scripts", "oq19", "results", "nonexistent.json"))


class Claim(unittest.TestCase):
    def result(self, sid, compressed=False, failed=(), agrees=True):
        return {"scenario": sid, "compressed": compressed, "mode": "detached", "failed": list(failed),
                "agrees_with_replay": agrees}

    def full_set(self):
        rs = [self.result(s.id) for s in labels.GATED for _ in range(gates.HOLDOUT_REPEATS_FULL)]
        rs += [self.result(s.id, True) for s in labels.CRITICAL
               for _ in range(gates.HOLDOUT_REPEATS_COMPRESSED_CRITICAL)]
        return rs

    def test_pass_needs_zero_failures_and_the_full_sample(self):
        verdict, _ = A.holdout_claim(self.full_set())
        self.assertEqual(verdict, gates.PASS)
        short = self.full_set()[:-1]
        self.assertEqual(A.holdout_claim(short)[0], gates.FAIL)          # one run short of the pre-registered size

    def test_one_failed_gate_or_a_loop_that_disagrees_with_its_replay_fails_the_claim(self):
        rs = self.full_set()
        rs[0] = self.result(rs[0]["scenario"], failed=["false_idle"])
        self.assertEqual(A.holdout_claim(rs)[0], gates.FAIL)
        rs = self.full_set()
        rs[3] = self.result(rs[3]["scenario"], agrees=False)
        self.assertEqual(A.holdout_claim(rs)[0], gates.FAIL)


if __name__ == "__main__":
    unittest.main()
