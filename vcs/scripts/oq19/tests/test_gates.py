"""Self-checks for the pre-registered OQ19 gates and labels.

Run BY FILE NAME (`python3 vcs/scripts/oq19/tests/test_gates.py`), never `unittest discover`: discover exits 0
with "Ran 0 tests" when the suite disappears, which would turn this gate green by deletion.

Every gate is checked three ways: a GOOD synthetic trace passes it, a BAD one fails it, and with the gate
patched to always pass, the BAD-trace assertion goes red. The third step is what proves the test is not
vacuous (an assertion the code already satisfies with the feature disabled proves nothing).
"""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import gates  # noqa: E402
import labels  # noqa: E402
from gates import FAIL, PASS, Interval  # noqa: E402
from labels import BUSY, IDLE  # noqa: E402


def busy(start, end, scenario="5", phase="work"):
    return Interval(scenario, phase, BUSY, start, end)


def idle(start, end, scenario="1", phase="idle"):
    return Interval(scenario, phase, IDLE, start, end)


class Labels(unittest.TestCase):
    def test_ids_are_unique_and_the_table_is_not_empty(self):
        ids = [s.id for s in labels.SCENARIOS]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertGreaterEqual(len(ids), 19)

    def test_critical_scenarios_are_exactly_the_ones_the_plan_names(self):
        self.assertEqual([s.id for s in labels.CRITICAL], ["4b", "7", "10"])

    def test_every_busy_phase_starts_at_the_worst_point_of_the_provider_timer(self):
        checked = 0
        for s in labels.SCENARIOS:
            before = 0
            for phase in s.phases:
                if phase.label == BUSY:
                    if before:
                        self.assertEqual(before, labels.QUIET_BEFORE_S, s.id)
                        checked += 1
                    break
                before += phase.seconds
        self.assertGreaterEqual(checked, 10)  # guards against the loop silently checking nothing

    def test_long_waits_outlast_every_window_and_the_provider_timeout(self):
        longest = max(gates.WINDOW_GRID_S)
        for sid in ("4b", "7"):
            turn = [p for p in labels.BY_ID[sid].phases if p.label == BUSY][0]
            self.assertGreater(turn.seconds, longest + labels.PROVIDER_TIMEOUT_S, sid)

    def test_post_phases_outlast_the_largest_window_plus_margin_and_interval(self):
        need = max(gates.WINDOW_GRID_S) + gates.TIME_TO_IDLE_MARGIN_S + max(gates.INTERVAL_GRID_S)
        self.assertGreaterEqual(labels.POST_IDLE_S, need)
        need_c = max(gates.WINDOW_GRID_COMPRESSED_S) + gates.TIME_TO_IDLE_MARGIN_S + max(gates.INTERVAL_GRID_S)
        self.assertGreaterEqual(labels.POST_IDLE_COMPRESSED_S, need_c)

    def test_compression_scales_the_policy_timescale_and_never_the_providers(self):
        for s in labels.SCENARIOS:
            for phase in s.phases:
                if phase.name == "quiet":  # the provider's worst point is real, not compressed
                    self.assertEqual(labels.seconds(phase, True), labels.QUIET_BEFORE_S, s.id)
        turn = [p for p in labels.BY_ID["4b"].phases if p.label == BUSY][0]
        sleep = [p for p in labels.BY_ID["7"].phases if p.label == BUSY][0]
        for long_wait in (turn, sleep):  # D11 survives compression: outlast the largest window + REAL timeout
            self.assertGreater(labels.seconds(long_wait, True),
                               max(gates.WINDOW_GRID_COMPRESSED_S) + labels.PROVIDER_TIMEOUT_S)
        self.assertEqual(gates.WINDOW_GRID_COMPRESSED_S, tuple(w // 10 for w in gates.WINDOW_GRID_S))

    def test_the_owner_decisions_are_encoded(self):
        self.assertEqual([p.label for p in labels.BY_ID["8"].phases], [IDLE])  # listening server: IDLE
        self.assertTrue(labels.BY_ID["18"].gated)  # staleness is gated
        self.assertFalse(labels.BY_ID["12"].gated)  # curves are reported, never gated
        self.assertFalse(labels.BY_ID["13"].gated)
        self.assertFalse(labels.BY_ID["17"].gated)  # OQ22 is the owner's decision


class VerdictSeries(unittest.TestCase):
    def test_time_before_the_first_verdict_is_idle(self):
        self.assertEqual(gates.verdict_at([(10, BUSY)], 5), IDLE)
        self.assertEqual(gates.verdict_at([(10, BUSY)], 10), BUSY)

    def test_upper_bounds_match_the_plan(self):
        self.assertAlmostEqual(gates.upper_bound(0, 5), 0.4507, places=3)  # 0/5 is a smoke test
        self.assertAlmostEqual(gates.upper_bound(0, 25), 0.1129, places=3)
        self.assertAlmostEqual(gates.upper_bound(1, 25), 0.1761, places=3)
        self.assertEqual(gates.upper_bound(5, 5), 1.0)


class FalseIdle(unittest.TestCase):
    def test_good_bad_and_disabled(self):
        work = busy(100, 400)
        good = [(100.5, BUSY)]  # verdict lands inside the onset allowance (1 s + 2 s)
        bad = [(100.5, BUSY), (200, IDLE)]  # declared idle mid-work
        self.assertEqual(gates.gate_false_idle(good, [work], 1)[0], PASS)
        self.assertEqual(gates.gate_false_idle(bad, [work], 1)[0], FAIL)
        with mock.patch.object(gates, "false_idle_seconds", lambda *a, **k: 0.0):
            self.assertEqual(gates.gate_false_idle(bad, [work], 1)[0], PASS)  # the disabled gate misses it

    def test_the_onset_allowance_is_excused_but_only_that(self):
        work = busy(100, 400)
        self.assertEqual(gates.gate_false_idle([(102.9, BUSY)], [work], 1)[0], PASS)  # 2.9 <= 1 + 2
        self.assertEqual(gates.gate_false_idle([(103.1, BUSY)], [work], 1)[0], FAIL)  # 3.1 > 1 + 2

    def test_never_detected_work_fails(self):
        self.assertEqual(gates.gate_false_idle([], [busy(100, 400)], 1)[0], FAIL)


class ProviderDeadline(unittest.TestCase):
    def test_good_bad_and_disabled(self):
        work = busy(0, 300)
        self.assertEqual(gates.gate_provider_deadline([(9.0, BUSY)], [work])[0], PASS)  # 110 + 9 < 120
        self.assertEqual(gates.gate_provider_deadline([(10.0, BUSY)], [work])[0], FAIL)  # 110 + 10 !< 120
        self.assertEqual(gates.gate_provider_deadline([], [work])[0], FAIL)  # never detected
        with mock.patch.object(gates, "provider_deadline_ok", lambda *a, **k: True):
            self.assertEqual(gates.gate_provider_deadline([(50.0, BUSY)], [work])[0], PASS)

    def test_a_detection_lag_can_pass_the_zero_gate_yet_cross_the_deadline(self):
        """The two gates are different properties: within the onset allowance is not the same as in time."""
        work = busy(0, 300)
        slow = [(4.0, BUSY)]  # 4 s lag, 5 s interval => allowance 7 s: false-idle passes
        self.assertEqual(gates.gate_false_idle(slow, [work], 5)[0], PASS)
        late = [(11.0, BUSY)]  # interval 10 => allowance 12: false-idle passes, deadline is crossed
        self.assertEqual(gates.gate_false_idle(late, [work], 10)[0], PASS)
        self.assertEqual(gates.gate_provider_deadline(late, [work])[0], FAIL)


class NoBusyForever(unittest.TestCase):
    def test_good_bad_and_disabled(self):
        quiet = idle(0, 300)
        self.assertEqual(gates.gate_no_busy_forever([], [quiet], {})[0], PASS)
        stuck = [(0, BUSY)]  # busy forever: the design doc's named failure
        self.assertEqual(gates.gate_no_busy_forever(stuck, [quiet], {})[0], FAIL)
        with mock.patch.object(gates, "busy_runs", lambda *a, **k: []), mock.patch.object(
            gates, "false_busy_seconds", lambda *a, **k: 0.0
        ):
            self.assertEqual(gates.gate_no_busy_forever(stuck, [quiet], {})[0], PASS)

    def test_a_hysteresis_tail_is_excused_at_the_start_but_a_later_run_is_not(self):
        post = idle(0, 300, "5", "post")
        tail = [(0, BUSY), (40, IDLE)]  # 40 s tail from the start, policy tail 60
        self.assertEqual(gates.gate_no_busy_forever(tail, [post], {post: 60})[0], PASS)
        self.assertEqual(gates.gate_no_busy_forever(tail, [post], {post: 20})[0], FAIL)  # 40 > 20 + 10
        later = [(100, BUSY), (140, IDLE)]  # a 40 s BUSY run that begins mid-idle: no tail excuse
        self.assertEqual(gates.gate_no_busy_forever(later, [post], {post: 60})[0], FAIL)

    def test_total_false_busy_fraction_is_capped(self):
        quiet = idle(0, 1000)
        flaps = [(t, BUSY if i % 2 == 0 else IDLE) for i, t in enumerate(range(100, 1000, 9))]
        self.assertEqual(gates.gate_no_busy_forever(flaps, [quiet], {})[0], FAIL)  # ~50% busy

    def test_the_d3_fallback_excuses_only_the_named_scenario(self):
        keepalive = idle(0, 300, "3b")
        other = idle(0, 300, "3a")
        stuck = [(0, BUSY)]
        self.assertEqual(gates.gate_no_busy_forever(stuck, [keepalive], {}, exempt=("3b",))[0], PASS)
        self.assertEqual(gates.gate_no_busy_forever(stuck, [other], {}, exempt=("3b",))[0], FAIL)


class TimeToIdle(unittest.TestCase):
    def test_good_bad_and_disabled(self):
        post = idle(0, 300, "5", "post")
        self.assertEqual(gates.gate_time_to_idle([(0, BUSY), (45, IDLE)], [post], 60)[0], PASS)
        self.assertEqual(gates.gate_time_to_idle([(0, BUSY), (75, IDLE)], [post], 60)[0], FAIL)  # 75 > 70
        self.assertEqual(gates.gate_time_to_idle([(0, BUSY)], [post], 60)[0], FAIL)  # never idle
        with mock.patch.object(gates, "time_to_idle", lambda *a, **k: 0.0):
            self.assertEqual(gates.gate_time_to_idle([(0, BUSY)], [post], 60)[0], PASS)


class Flapping(unittest.TestCase):
    """Scenario 12 is a REPORTED curve, not a gate: an always-BUSY policy would win a flapping gate."""

    def test_flaps_are_a_metric_and_evaluate_never_gates_them(self):
        calm = [(600, BUSY), (1200, IDLE)]
        noisy = [(t, BUSY if (t // 60) % 2 else IDLE) for t in range(60, 3600, 60)]
        self.assertEqual(gates.flaps_per_hour(calm, 0, 3600), 2.0)
        self.assertGreater(gates.flaps_per_hour(noisy, 0, 3600), 20)
        bursty = [Interval("12", "bursts", BUSY, 0, 1800)]
        self.assertEqual(gates.flap_metric(noisy, bursty), gates.flaps_per_hour(noisy, 0, 1800))
        self.assertNotIn("flapping", gates.evaluate(noisy, bursty, 1, 60))
        self.assertIsNone(gates.flap_metric(noisy, [idle(0, 10)]))


class SamplerCost(unittest.TestCase):
    def test_good_bad_and_disabled(self):
        self.assertEqual(gates.gate_sampler_cost(0.004)[0], PASS)
        self.assertEqual(gates.gate_sampler_cost(0.006)[0], FAIL)
        with mock.patch.object(gates, "SAMPLER_CPU_MAX", 1.0):
            self.assertEqual(gates.gate_sampler_cost(0.006)[0], PASS)


class D3Fallback(unittest.TestCase):
    def test_fires_only_when_no_policy_separates_3b_from_4b(self):
        none = [{"four_b_false_idle_zero": True, "three_b_no_busy_forever": False},
                {"four_b_false_idle_zero": False, "three_b_no_busy_forever": True}]
        self.assertTrue(gates.d3_fallback_fires(none))
        one = none + [{"four_b_false_idle_zero": True, "three_b_no_busy_forever": True}]
        self.assertFalse(gates.d3_fallback_fires(one))
        self.assertTrue(gates.d3_fallback_fires([]))  # no policy at all: cannot claim separation


class FinalClaim(unittest.TestCase):
    def run_(self, set_, scale, n, scenario="4b", mode="detached", failed=()):
        return [{"set": set_, "scale": scale, "mode": mode, "scenario": scenario,
                 "failed_gates": list(failed) if i == 0 else []} for i in range(n)]

    def all_clean(self):
        return (self.run_("tuning", "full", 5) + self.run_("tuning", "compressed", 20)
                + self.run_("holdout", "full", 5) + self.run_("holdout", "compressed", 20))

    def test_the_claim_rests_on_the_detached_holdout_at_both_scales_and_never_pools(self):
        verdict, table = gates.final_claim(self.all_clean())
        self.assertEqual(verdict, PASS)
        self.assertEqual(set(table), {("tuning", "full", "detached"), ("tuning", "compressed", "detached"),
                                      ("holdout", "full", "detached"), ("holdout", "compressed", "detached")})
        self.assertAlmostEqual(table[("holdout", "compressed", "detached")]["bound_any"], gates.upper_bound(0, 20))

    def test_a_clean_tuning_set_cannot_carry_a_failing_holdout(self):
        runs = self.run_("tuning", "full", 5) + self.run_("holdout", "full", 5, failed=("false_idle",)) \
            + self.run_("holdout", "compressed", 20)
        self.assertEqual(gates.final_claim(runs)[0], FAIL)

    def test_a_missing_holdout_scale_or_mode_is_not_a_pass(self):
        self.assertEqual(gates.final_claim(self.run_("holdout", "compressed", 20))[0], FAIL)
        attached = self.run_("holdout", "full", 5, mode="attached") + self.run_("holdout", "compressed", 20, mode="attached")
        self.assertEqual(gates.final_claim(attached)[0], FAIL)  # attached results never carry the claim

    def test_every_gate_carries_the_claim_not_just_false_idle(self):
        runs = self.run_("holdout", "full", 5, failed=("provider_deadline",)) + self.run_("holdout", "compressed", 20)
        self.assertEqual(gates.final_claim(runs)[0], FAIL)

    def test_the_false_idle_denominator_counts_only_runs_that_can_fail_it(self):
        """Idle-only scenarios cannot fail false-idle: counting them would manufacture a tighter bound."""
        runs = (self.run_("holdout", "full", 45, scenario="1") + self.run_("holdout", "full", 35, scenario="5")
                + self.run_("holdout", "compressed", 20))
        table = gates.final_claim(runs)[1]
        g = table[("holdout", "full", "detached")]
        self.assertEqual((g["runs"], g["busy_runs"]), (80, 35))
        self.assertAlmostEqual(g["bound_false_idle"], gates.upper_bound(0, 35))
        self.assertGreater(g["bound_false_idle"], gates.upper_bound(0, 80))  # not the flattering pooled bound

    def test_critical_scenarios_are_reported_on_their_own(self):
        runs = self.run_("holdout", "full", 5, scenario="4b") + self.run_("holdout", "full", 10, scenario="5") \
            + self.run_("holdout", "compressed", 20)
        g = gates.final_claim(runs)[1][("holdout", "full", "detached")]
        self.assertEqual(g["critical_runs"], 5)
        self.assertAlmostEqual(g["critical_bound"], gates.upper_bound(0, 5))
        self.assertEqual(g["by_scenario"]["5"], (10, 0))


class Evaluate(unittest.TestCase):
    def test_a_correct_run_passes_every_gate_and_a_missed_run_fails_the_right_ones(self):
        intervals = [idle(0, 110, "5", "quiet"), busy(110, 410), idle(410, 1050, "5", "post")]
        good = [(0, IDLE), (111, BUSY), (470, IDLE)]
        result = gates.evaluate(good, intervals, 1, 60)
        self.assertTrue(all(v[0] == PASS for v in result.values()), result)
        result = gates.evaluate([(0, IDLE)], intervals, 1, 60)
        self.assertEqual(result["false_idle"][0], FAIL)
        self.assertEqual(result["provider_deadline"][0], FAIL)

    def test_always_busy_fails_on_an_idle_scenario_and_nothing_the_caller_passes_can_excuse_it(self):
        """The design doc's headline failure (busy forever on an idle TUI) must not pass any gate."""
        for scenario, length in (("1", 300), ("16", 600), ("2c", 300)):
            iv = [idle(0, length, scenario)]
            result = gates.evaluate([(0, BUSY)], iv, 1, 60)
            self.assertEqual(result["no_busy_forever"][0], FAIL, scenario)
        # the excuses are not parameters any more
        for name in ("tails", "exempt"):
            self.assertNotIn(name, gates.evaluate.__code__.co_varnames[:gates.evaluate.__code__.co_argcount])
        with self.assertRaises(AssertionError):  # and the gate itself refuses to excuse anything but 3b
            gates.gate_no_busy_forever([(0, BUSY)], [idle(0, 300)], {}, exempt=("1",))

    def test_the_d3_exemption_comes_only_from_the_mechanised_rule(self):
        keepalive = [idle(0, 300, "3b")]
        self.assertEqual(gates.evaluate([(0, BUSY)], keepalive, 1, 60)["no_busy_forever"][0], FAIL)
        self.assertEqual(gates.evaluate([(0, BUSY)], keepalive, 1, 60, d3_fallback=True)["no_busy_forever"][0], PASS)

    def test_the_hysteresis_tail_is_the_configured_window_never_zero(self):
        """An explicit 'no tails' used to be silently replaced by a default; the tail now always equals the window."""
        post = [idle(410, 1050, "5", "post")]
        tail_60 = [(410, BUSY), (470, IDLE)]
        self.assertEqual(gates.evaluate(tail_60, post, 1, 60)["no_busy_forever"][0], PASS)
        self.assertEqual(gates.evaluate(tail_60, post, 1, 20)["no_busy_forever"][0], FAIL)  # 60 > 20 + 10

    def test_unsorted_verdicts_are_rejected_rather_than_silently_misread(self):
        with self.assertRaises(AssertionError):
            gates.evaluate([(300, IDLE), (100, BUSY)], [busy(0, 400)], 1, 60)

    def test_the_top_of_the_window_grid_is_reachable(self):
        """Review finding: a post phase shorter than the window made the largest window impossible to pass."""
        for window in gates.WINDOW_GRID_S:
            post = [idle(0, labels.POST_IDLE_S, "5", "post")]
            v = [(0, BUSY), (window, IDLE)]  # a policy that honours its window exactly
            self.assertEqual(gates.gate_time_to_idle(v, post, window)[0], PASS, window)


class Staleness(unittest.TestCase):
    """D10: while the sampler is blind the policy must fail safe to BUSY."""

    def gap(self):
        return [Interval("18", "gap", labels.STALE, 100, 115)]

    def test_good_bad_and_disabled(self):
        good = [(100, BUSY)]  # fail-safe rule fired
        bad = [(100, IDLE)]  # kept a stale IDLE verdict through the blind period
        self.assertEqual(gates.gate_staleness(good, self.gap(), 5)[0], PASS)
        self.assertEqual(gates.gate_staleness(bad, self.gap(), 5)[0], FAIL)
        with mock.patch.object(gates, "_seconds", lambda *a, **k: 0.0):
            self.assertEqual(gates.gate_staleness(bad, self.gap(), 5)[0], PASS)

    def test_a_policy_that_turns_busy_only_after_the_staleness_window_still_fails_early_idle(self):
        late = [(100, IDLE), (112.5, BUSY)]  # busy from 12.5; interval 5 => must be BUSY from 100+10+2=112
        self.assertEqual(gates.gate_staleness(late, self.gap(), 5)[0], FAIL)
        on_time = [(100, IDLE), (111.9, BUSY)]
        self.assertEqual(gates.gate_staleness(on_time, self.gap(), 5)[0], PASS)

    def test_a_gap_too_short_to_test_the_rule_fails_instead_of_passing_vacuously(self):
        short = [Interval("18", "gap", labels.STALE, 100, 108)]
        self.assertEqual(gates.gate_staleness([(100, IDLE)], short, 5)[0], FAIL)

    def test_evaluate_scores_it_only_when_a_gap_exists(self):
        ivs = [busy(110, 410, "18"), idle(410, 1050, "18", "post")]
        self.assertNotIn("staleness", gates.evaluate([(111, BUSY), (470, IDLE)], ivs, 1, 60))
        with_gap = ivs + self.gap()
        self.assertIn("staleness", gates.evaluate([(111, BUSY), (470, IDLE)], with_gap, 1, 60))


if __name__ == "__main__":
    unittest.main(verbosity=1)
