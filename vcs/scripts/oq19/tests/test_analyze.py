#!/usr/bin/env python3
"""Self-checks for analyze.py (run by `run.sh --self-test`, by file name).

Two kinds of test, and the second is the point:
  * a behaviour test: the policy reaches the right verdict on a synthetic trace with a known label;
  * a RED check: the same trace with ONE feature disabled at the source must make the gate that feature
    protects FAIL. A gate that stays green when its protection is removed is not testing anything (prior
    learning: assert-a-value-the-shape-already-has).
Synthetic traces only: no recorded trace, and nothing here reads or changes labels.py / gates.py.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import analyze as A  # noqa: E402
import gates  # noqa: E402
from labels import BUSY, IDLE, STALE  # noqa: E402

T0 = 1000.0
SAMPLER = 9
ROOT = 7


def P(pid, ppid, comm, state="S", ticks=0, wchan="0"):
    return [pid, ppid, pid, pid, comm, "/usr/bin/" + comm, state, ticks, 0, wchan]


def base_procs(t):
    """The driver (pid 1), the sampler (pid 9, spending a little CPU and forking `ss`) and an idle bash."""
    return [P(1, 0, "python3", "S", 0, "hrtimer_nanosleep"),
            P(SAMPLER, 1, "python3", "R", int((t - T0) * 1.0)),
            P(50, SAMPLER, "ss", "S", 1, "poll_schedule_timeout"),
            P(ROOT, 1, "bash", "S", 0, "poll_schedule_timeout.constprop.0")]


def mk_run(sid, phases, extra=None, sockets=None, pty=(), lifecycle=(), drop=None, net=None, interval=1,
           compressed=False):
    """phases: [(name, label, seconds)]. extra(t) -> more process rows; sockets(t) -> ss rows; net(t) -> bytes/s."""
    truth, t = [], T0
    for name, label, secs in phases:
        truth.append({"scenario": sid, "phase": name, "label": label, "start": t, "end": t + secs})
        t += secs
    end, samples, rx, tick = t, [], 0, 0
    now = T0 - 2 * interval
    while now <= end + interval:
        if not (drop and drop(now)):
            procs = base_procs(now) + (extra(now) if extra else [])
            rx += int((net(now) if net else 0) * interval)
            samples.append({"type": "s", "t": now, "tick": tick, "roots": [ROOT], "procs": procs,
                            "sockets": sockets(now) if sockets else [], "net_rx": rx, "net_tx": 0,
                            "cg_cpu_usec": 0})
        now += interval
        tick += 1
    meta = {"scenario": sid, "scale": 1.0, "compressed": compressed, "mode": "detached"}
    return A.Run(meta, {"interval": float(interval), "pid": SAMPLER}, samples, list(pty), list(lifecycle), truth,
                 key="%s-synth" % sid)


def ticks_of(t, start, rate=100):
    return int(max(0, t - start) * rate)


def estab(pid, name, age_s):
    ms = int(age_s * 1000)
    return ["ESTAB", "10.0.0.2:1", "10.0.0.3:9000", 0, 0, [[name, pid]], ms, ms, ms]


def cfg(policy="P4", **kw):
    base = dict(cpu=0.05, pty=30.0, net=None, wait="agnostic", age=None, grace=0.0, window=0, interval=1)
    base.update(kw)
    return A.Config(policy, **base)


def evaluate(run, c, window_s=30.0, d3=False):
    feats = A.features(A.Stream(run, c.interval), c.exclusions)
    v = A.verdict_series(c, feats, window_s if c.policy in A.HYSTERESIS_POLICIES else 0.0)
    idle_window = window_s if c.policy in A.HYSTERESIS_POLICIES else 0.0
    return gates.evaluate(v, run.intervals(), c.interval, idle_window, d3_fallback=d3), v


BUILD = [("quiet", IDLE, 120), ("build", BUSY, 80), ("post", IDLE, 90)]


def build_extra(t):
    if T0 + 120 <= t < T0 + 200:
        return [P(80, ROOT, "make", "S", ticks_of(t, T0 + 120), "do_wait"),
                P(81, 80, "cc1", "R", ticks_of(t, T0 + 120, 200))]
    return []


class Replay(unittest.TestCase):
    def test_stream_carries_no_truth_and_replays_at_the_policys_cadence(self):
        run = mk_run("1", [("idle", IDLE, 40)])
        s = A.Stream(run, 2.0)
        self.assertFalse(any("truth" in name or "label" in name for name in vars(s)))
        self.assertTrue(all(x["tick"] % 2 == 0 for x in s.samples))
        self.assertTrue(s.downsampled)
        with self.assertRaises(ValueError):
            A.Stream(run, 1.5)  # not a multiple of the recorded cadence

    def test_scale_guard_refuses_scaled_runs_unless_pipeline_check(self):
        run = mk_run("1", [("idle", IDLE, 40)])
        run.scale = 0.05
        with self.assertRaises(SystemExit):
            A.check_scale([run], pipeline_check=False)
        A.check_scale([run], pipeline_check=True)


class Votes(unittest.TestCase):
    def votes(self, run, c):
        return [A.vote(c, f) for f in A.features(A.Stream(run, c.interval), c.exclusions)]

    def test_the_classifiers_own_activity_never_votes_busy_and_the_red_check(self):
        run = mk_run("16", [("idle", IDLE, 60)])  # only the driver, the sampler, its `ss` child, an idle shell
        self.assertFalse(any(self.votes(run, cfg("P3"))))
        # RED: without the exclusion list the sampler's own R state and CPU sustain BUSY (F7).
        self.assertTrue(any(self.votes(run, cfg("P3")._replace(exclusions=False))))
        # ... and the gate that protects it goes red
        ok, _ = evaluate(run, cfg("P4"))
        red, _ = evaluate(run, cfg("P4")._replace(exclusions=False))
        self.assertEqual(ok["no_busy_forever"][0], gates.PASS)
        self.assertEqual(red["no_busy_forever"][0], gates.FAIL)

    def test_idle_tui_is_idle_and_a_sleepy_job_is_busy(self):
        vim = mk_run("2a", [("idle", IDLE, 60)],
                     extra=lambda t: [P(60, ROOT, "vim", "S", 5, "poll_schedule_timeout.constprop.0")])
        sleepy = mk_run("2a", [("idle", IDLE, 60)],
                        extra=lambda t: [P(61, ROOT, "sleep", "S", 0, "hrtimer_nanosleep")])
        self.assertFalse(any(self.votes(vim, cfg("P3"))))
        self.assertTrue(all(self.votes(sleepy, cfg("P3"))))

    def test_wait_rules_separate_3b_from_4b_only_when_the_agent_blocks_on_the_tty(self):
        def agent(wchan, age):
            run = mk_run("3b", [("idle", IDLE, 60)],
                         extra=lambda t: [P(70, ROOT, "2.1.232", "S", 9, wchan)],
                         sockets=lambda t: [estab(70, "2.1.232", age)])
            return run
        idle_agent, waiting = agent("wait_woken", 500), agent("poll_schedule_timeout.constprop.0", 500)
        # agent-agnostic: any owned ESTAB socket is busy, so the idle keepalive (3b) is BUSY forever ...
        self.assertTrue(all(self.votes(idle_agent, cfg("P3", wait="agnostic"))))
        # ... tty-aware separates it, because the synthetic agent blocks in a tty read
        self.assertFalse(any(self.votes(idle_agent, cfg("P3", wait="tty-aware"))))
        self.assertTrue(all(self.votes(waiting, cfg("P3", wait="tty-aware"))))
        # socket age (S6b) cannot rescue a SILENT wait: the 4b socket looks like an idle keepalive
        self.assertFalse(any(self.votes(waiting, cfg("P3", age=30.0))))

    def test_cpu_pty_net_and_grace_votes(self):
        cpu = mk_run("5", BUILD, extra=build_extra)
        v = self.votes(cpu, cfg("P3"))
        self.assertTrue(any(v))
        self.assertFalse(any(self.votes(cpu, cfg("P3", cpu=1e9, pty=1e9))))  # the CPU vote is what fires here
        spinner = [{"t": T0 + i * 0.1, "d": "out", "n": 20} for i in range(600)]      # 200 B/s
        clock = [{"t": T0 + i * 15.0, "d": "out", "n": 100} for i in range(4)]        # tmux: ~7 B/s
        quiet = [("idle", IDLE, 60)]
        self.assertTrue(any(self.votes(mk_run("4a", quiet, pty=spinner), cfg("P3"))))
        self.assertFalse(any(self.votes(mk_run("2c", quiet, pty=clock), cfg("P3"))))
        traffic = mk_run("9", quiet, net=lambda t: 2000.0 if int(t) % 2 == 0 else 0.0)
        self.assertTrue(any(self.votes(traffic, cfg("P3", net=500.0))))
        self.assertFalse(any(self.votes(traffic, cfg("P3", net=None))))
        typing = [{"t": T0 + 10, "d": "in", "n": 1}]
        run = mk_run("14", quiet, pty=typing)
        graced = [f["t"] for f, x in zip(A.features(A.Stream(run, 1)), self.votes(run, cfg("P4", grace=30.0))) if x]
        self.assertTrue(graced and max(graced) <= T0 + 40 and min(graced) >= T0 + 10)
        self.assertFalse(any(self.votes(run, cfg("P4", grace=0.0))))


class GatesGoRed(unittest.TestCase):
    """Each protection, disabled at the source, must turn its gate red."""

    def test_cpu_vote_protects_false_idle(self):
        run = mk_run("5", BUILD, extra=lambda t: [P(81, ROOT, "cc1", "R", ticks_of(t, T0 + 120, 200))]
                     if T0 + 120 <= t < T0 + 200 else [])
        ok, _ = evaluate(run, cfg("P4"))
        red, _ = evaluate(run, cfg("P4", cpu=1e9))  # the CPU vote disabled
        self.assertEqual(ok["false_idle"][0], gates.PASS)
        self.assertEqual(red["false_idle"][0], gates.FAIL)

    def test_liveness_alone_misses_a_setsid_escapee_and_the_cgroup_view_finds_it(self):
        # scenario 10: the job's parent is the driver (pid 1), not the shell, so the tree walk cannot see it
        run = mk_run("10", BUILD, extra=lambda t: [P(90, 1, "python3", "R", ticks_of(t, T0 + 120))]
                     if T0 + 120 <= t < T0 + 200 else [])
        p1, _ = evaluate(run, cfg("P1"))
        p1b, _ = evaluate(run, cfg("P1b"))
        self.assertEqual(p1["false_idle"][0], gates.FAIL)
        self.assertEqual(p1b["false_idle"][0], gates.PASS)

    def test_hysteresis_window_bounds_time_to_idle(self):
        run = mk_run("5", BUILD, extra=build_extra)
        ok, v = evaluate(run, cfg("P4"), window_s=30.0)
        self.assertEqual(ok["time_to_idle"][0], gates.PASS)
        self.assertEqual(ok["time_to_idle"][1] >= 30.0 - 1.5, True)  # the tail really was held
        red, _ = evaluate(run, cfg("P4"), window_s=1e9)              # a window that never lets go
        self.assertEqual(red["time_to_idle"][0], gates.FAIL)

    def test_staleness_rule_protects_work_that_starts_in_a_gap(self):
        gap = (T0 + 100, T0 + 120)
        phases = [("quiet", IDLE, 110), ("work", BUSY, 90), ("post", IDLE, 90)]
        run = mk_run("18", phases, extra=lambda t: [P(81, ROOT, "cc1", "R", ticks_of(t, T0 + 105))]
                     if t >= T0 + 105 and t < T0 + 200 else [], drop=lambda t: gap[0] <= t < gap[1])
        run.truth.append({"scenario": "18", "phase": "gap", "label": STALE, "start": gap[0], "end": gap[1]})
        ok, _ = evaluate(run, cfg("P4"))
        red, _ = evaluate(run, cfg("P4")._replace(staleness=False))
        self.assertEqual(ok["staleness"][0], gates.PASS)
        self.assertEqual(red["staleness"][0], gates.FAIL)

    def test_lifecycle_protects_an_exec_with_no_visible_process(self):
        phases = [("quiet", IDLE, 120), ("exec", BUSY, 40), ("post", IDLE, 90)]
        span = [{"t": T0 + 120, "event": "start", "name": "git"}, {"t": T0 + 160, "event": "end", "name": "git"}]
        run = mk_run("11", phases, lifecycle=span)
        p5, _ = evaluate(run, cfg("P5"))
        p4, _ = evaluate(run, cfg("P4"))
        off, _ = evaluate(run, cfg("P5")._replace(lifecycle=False))
        self.assertEqual(p5["false_idle"][0], gates.PASS)
        self.assertEqual(p4["false_idle"][0], gates.FAIL)   # P4 has no lifecycle source
        self.assertEqual(off["false_idle"][0], gates.FAIL)  # RED: P5 with the lifecycle vote disabled

    def test_exclusion_list_protects_the_noisy_idle_box(self):
        def noisy(t):  # cron sleeping, a housekeeping job under cron burning CPU every 60 s, an idle sshd
            rows = [P(30, 1, "cron", "S", 0, "hrtimer_nanosleep"), P(31, 1, "sshd", "S", 0, "poll_schedule_timeout")]
            if int(t - T0) % 60 < 3:
                rows += [P(32, 30, "python3", "R", ticks_of(t, T0 + int(t - T0) // 60 * 60))]
            return rows
        run = mk_run("16", [("idle", IDLE, 600)], extra=noisy)
        ok, _ = evaluate(run, cfg("P4"))
        red, _ = evaluate(run, cfg("P4")._replace(exclusions=False))
        self.assertEqual(ok["no_busy_forever"][0], gates.PASS)
        self.assertEqual(red["no_busy_forever"][0], gates.FAIL)


class D3AndSelection(unittest.TestCase):
    def runs(self):
        idle = [("idle", IDLE, 120)]
        three = mk_run("3b", idle, extra=lambda t: [P(70, ROOT, "2.1.232", "S", 9, "wait_woken")],
                       sockets=lambda t: [estab(70, "2.1.232", 500)])
        phases = [("quiet", IDLE, 110), ("turn", BUSY, 150), ("post", IDLE, 90)]
        four = mk_run("4b", phases,
                      extra=lambda t: [P(70, ROOT, "2.1.232", "S", 9, "poll_schedule_timeout.constprop.0")]
                      if T0 + 110 <= t < T0 + 260 else [],
                      sockets=lambda t: [estab(70, "2.1.232", t - (T0 + 110))] if T0 + 110 <= t < T0 + 260 else [])
        three.key, four.key = "3b", "4b"
        return [three, four]

    def test_d3_is_decided_over_the_whole_agnostic_grid_then_applied(self):
        configs = [cfg("P4", age=None), cfg("P4", age=30.0)]
        summaries, d3 = A.evaluate_all(self.runs(), configs, A.load_cost_matrix())
        by_age = {s["config"].age: s for s in summaries}
        # no-age policy: 4b fine, 3b busy forever. age-30 policy: 3b fine, 4b false-idle. Neither achieves both.
        self.assertTrue(d3)
        self.assertTrue(by_age[None]["passes_all"])        # 3b exempt, accepted cost
        self.assertFalse(by_age[30.0]["passes_all"])       # the exemption never rescues a false-idle
        self.assertIn("false_idle", by_age[30.0]["failures"])

    def test_d3_does_not_fire_when_some_agnostic_policy_achieves_both(self):
        rows = [{"four_b_false_idle_zero": True, "three_b_no_busy_forever": True}]
        self.assertFalse(gates.d3_fallback_fires(rows))

    def rows(self, *specs):
        return [dict(config=cfg(**kw), passes_all=ok, false_busy=fb, cost=cost, flaps=0.0, signals=n)
                for kw, ok, fb, cost, n in specs]

    def test_selection_rule(self):
        rows = self.rows(({}, True, 0.03, 0.002, 4),
                         ({"cpu": 0.2}, True, 0.01, 0.009, 4),                  # least false-busy: wins
                         ({"wait": "tty-aware"}, True, 0.0, 0.001, 3),          # never selected (conditional)
                         ({"pty": 200.0}, False, 0.0, 0.0, 1))                  # fails a gate: ineligible
        self.assertEqual(A.select_winner(rows)["config"].cpu, 0.2)
        self.assertIsNone(A.select_winner(self.rows(({"wait": "tty-aware"}, True, 0.0, 0.0, 1),
                                                    ({}, False, 0.0, 0.0, 1))))
        tie = self.rows(({"window": 3}, True, 0.01, 0.002, 4), ({"window": 1}, True, 0.01, 0.002, 4))
        self.assertEqual(A.select_winner(tie)["config"].window, 1)             # shorter window on a tie

    def test_ceiling_report_only_reports(self):
        work = gates.Interval("17", "work", BUSY, 0.0, 5400.0)
        report, longest = A.ceiling_report([(0.0, BUSY)], work)
        self.assertEqual(report["3600"]["force-sleep"], "kills the job")
        self.assertEqual(report["14400"]["force-sleep"], "ok")
        self.assertEqual(report["3600"]["advisory"], "ok")


class ClosedLoop(unittest.TestCase):
    def test_the_live_classifier_matches_a_replay_of_its_own_trace(self):
        """live.py must not drift from the code the gates were scored with: fed the same samples and the same
        counters, its verdicts equal the replay's, tick for tick."""
        import json
        import tempfile
        import live
        spinner = [{"t": T0 + 130 + i * 0.1, "d": "out", "n": 20} for i in range(200)]
        typing = [{"t": T0 + 20.0, "d": "in", "n": 3}]
        span = [{"t": T0 + 60.0, "event": "start", "name": "git"}, {"t": T0 + 75.0, "event": "end", "name": "git"}]
        run = mk_run("5", BUILD, extra=build_extra, pty=spinner + typing, lifecycle=span)
        c = cfg("P5", grace=15.0, pty=30.0)
        window = 20.0
        expected = A.verdict_series(c, A.features(A.Stream(run, 1), True), window)
        with tempfile.TemporaryDirectory() as d:
            counters = os.path.join(d, "counters.json")
            clf = live.Classifier(c, window, counters, os.path.join(d, "v.jsonl"), os.path.join(d, "verdict"), 1,
                                  SAMPLER)
            for smp in run.samples:
                t = smp["t"]
                out = sum(e["n"] for e in run.pty if e["d"] == "out" and e["t"] <= t)
                ins = [e["t"] for e in run.pty if e["d"] == "in" and e["t"] <= t]
                starts = sum(1 for e in span if e["event"] == "start" and e["t"] <= t)
                ends = sum(1 for e in span if e["event"] == "end" and e["t"] <= t)
                with open(counters, "w") as f:
                    json.dump({"out": out, "last_in": ins[-1] if ins else None, "starts": starts,
                               "open": starts - ends}, f)
                clf.feed(smp)
            clf.close()
            got = A.live_verdicts(os.path.join(d, "v.jsonl"))
        self.assertTrue(any(v == BUSY for _, v in got))
        self.assertEqual(got, expected)

    def test_closed_loop_gate_goes_red_when_the_classifier_can_see_itself(self):
        run = mk_run("16", [("idle", IDLE, 120)])
        c = cfg("P4")
        ok = A.verdict_series(c, A.features(A.Stream(run, 1), True), 10.0)
        seen = A.verdict_series(c._replace(exclusions=False), A.features(A.Stream(run, 1), False), 10.0)
        self.assertEqual(gates.evaluate(ok, run.intervals(), 1, 10.0)["no_busy_forever"][0], gates.PASS)
        self.assertEqual(gates.evaluate(seen, run.intervals(), 1, 10.0)["no_busy_forever"][0], gates.FAIL)

    def test_the_wake_shim_is_on_the_exclusion_list(self):
        self.assertIn("wr-wakeshim", A.EXCLUDED_COMMS)


class Report(unittest.TestCase):
    def test_every_section_of_the_report_renders_for_a_winner(self):
        """The winner branch is the one nothing else exercises: a bug there would only show at the end of a
        multi-hour recording."""
        def tagged(run, key, mode="detached", role="parallel", variant=""):
            run.key, run.mode, run.variant = key, mode, variant
            run.tags = {"role": role, "rep": 0}
            return run
        idle = [("idle", IDLE, 120)]
        long_work = [("quiet", IDLE, 110), ("work", BUSY, 400), ("post", IDLE, 90)]
        runs = [
            tagged(mk_run("5", BUILD, extra=build_extra), "5-detached-full-r0"),
            tagged(mk_run("5", BUILD, extra=build_extra), "5-detached-full-r0-serial", role="serial-control"),
            tagged(mk_run("5", BUILD, extra=build_extra), "5-attached-full-r0", mode="attached"),
            tagged(mk_run("5", BUILD, extra=build_extra), "5-detached-full-500proc-r0", variant="500proc"),
            tagged(mk_run("1", idle), "1-detached-full-r0"),
            tagged(mk_run("3b", idle), "3b-detached-full-r0"),
            tagged(mk_run("17", long_work, extra=lambda t: [P(81, ROOT, "cc1", "R", ticks_of(t, T0 + 110, 30))]
                          if T0 + 110 <= t < T0 + 510 else []), "17-detached-full-r0"),
        ]
        configs = [cfg("P4", window=0), cfg("P5", window=0)]
        summaries, d3 = A.evaluate_all(runs, configs, A.load_cost_matrix())
        winner = summaries[0]
        winner["passes_all"] = True  # force the winner branch: this test is about rendering, not about scoring
        text = A.report(runs, [("x-run", "check_trace failed")], summaries, d3, winner, A.load_cost_matrix(), True, "abc")
        for heading in ("## D3", "## The ladder", "## Winner", "What an idle box costs", "Serial control (D7)",
                        "Scenario 17 and the awake ceiling", "Attached vs detached", "PREDICTION", "500-process build",
                        "PIPELINE CHECK ONLY"):
            self.assertIn(heading, text)
        self.assertIn("5-detached-full-r0-serial", text)   # the control was paired with its twin
        self.assertIn("excluded `x-run`", text)
        # the serial control and the attached and 500-process runs are never scored
        self.assertEqual(sum(1 for s in summaries for _ in [0] if s["runs"] != 4), 0)


if __name__ == "__main__":
    unittest.main()
