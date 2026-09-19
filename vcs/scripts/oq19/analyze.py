#!/usr/bin/env python3
"""OQ19 analysis (plan step 3, T5): replays recorded runs through candidate policies P0 to P5 and scores them
with the pre-registered gates. It never edits `labels.py` or `gates.py`; it only calls them.

  analyze.py tuning [--root DIR] [--out DIR] [--pipeline-check]

WRITTEN BEFORE ANY TUNING TRACE EXISTED. The candidate grid and the winner-selection rule (`select_winner`) are
fixed in this file and committed before the recording finishes, so "choose and freeze parameters" cannot be
decided after the table has been seen.

How the replay is kept honest
* A policy sees only a `Stream`: observations at ITS OWN cadence. The stream has no access to the truth log, so a
  policy cannot read a label, and truth goes only to `gates.evaluate`.
* pty and lifecycle events are bucketed into the policy's ticks (bytes since the last tick); production sees
  counters at ticks, not event timestamps.
* Staleness is driven by the observed gap between samples, never by the STALE truth interval. (A CPU-bound
  container's sampler is throttled and goes silent with no injected fault: the rule fires on real runs.)
* Interval grid vs F7: the tuning set is recorded at 1 s. A 2 s or 5 s policy is REPLAYED by taking every 2nd
  or 5th tick of that trace (`downsampled` is stamped on the result). That is legitimate for narrowing the grid
  on the tuning set and for nothing else: the claim-bearing hold-out (T6) is recorded at the winner's real
  cadence, and the sampler's own cost is charged from the measured matrix, not from the downsampled trace.
* Scored tables need scale 1.0. A run at another scale is refused unless `--pipeline-check`, which is stamped on
  the output: a 15 s trace cannot exercise a 600 s window and must never reach a results table.

Known limits, stated here so they travel with the code
* S0 (`tcgetpgrp`) was not recorded. P0 reconstructs it from the shell's wait state: bash is blocked in
  `do_wait` exactly while a foreground job holds the terminal.
* The synthetic agent blocks in a tty read at its prompt (wchan `wait_woken`); the real one is an event loop.
  So the `tty-aware` wait rule is CONDITIONAL on that, and the D3 test is run over the `agnostic` family only.
"""

import argparse
import bisect
import collections
import itertools
import json
import os
import sys

import gates
import labels
from labels import BUSY, IDLE

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- the pre-registered candidate grid ------------------------------------------------------------------
CPU_GRID = (0.05, 0.20)            # cores of non-excluded process CPU that count as activity
PTY_RATE_GRID = (30.0, 200.0)      # pty output bytes/s over PTY_WINDOW_S (tmux's clock is ~10, a spinner ~200)
PTY_WINDOW_S = 10.0
NET_GRID = (None, 500.0)           # eth0 rx+tx bytes/s that count as activity (None = signal not used)
WAIT_RULES = ("agnostic", "tty-aware")
SOCKET_AGE_GRID = (None, 30.0)     # an ESTAB socket counts only if its last send/receive is this recent (S6b)
GRACE_GRID = (0.0, 30.0)           # seconds after the last pty input that still count as activity (S5)
INTERVALS = gates.INTERVAL_GRID_S
WINDOWS = tuple(range(len(gates.WINDOW_GRID_S)))  # index into the full or the compressed grid
POLICIES = ("P0", "P1", "P1b", "P2", "P3", "P4", "P5")
HYSTERESIS_POLICIES = ("P4", "P5")
CLK_TCK = 100.0

TIMER_WCHAN = ("hrtimer_nanosleep", "do_nanosleep", "common_nsleep")
TTY_WCHAN = ("wait_woken", "n_tty_read")
# The production exclusion list (boundary.md), applied by process name and, for the sampler, by pid. A match
# excludes the process AND its descendants (cron's children are cron's housekeeping).
EXCLUDED_COMMS = ("sshd", "cron", "systemd", "systemd-journal", "systemd-logind", "dbus-daemon", "rsyslogd",
                  "unattended-upgr", "apt.systemd.dai", "wr-agent", "wr-wakeshim")
OWN_PIDS = (1,)                    # container init: the driver in the harness, systemd in production
CEILINGS_S = (1800, 3600, 14400)   # OQ22: candidate awake ceilings, reported for scenario 17 only
CONTROL_MAX_MISMATCH = 0.02        # D7: a serial control may differ from its parallel twin in at most this share of seconds
CLOSED_LOOP_MAX_MISMATCH = 0.02    # F7: the live verdicts may differ from a replay of their own trace in at most this share

# Signal groups each policy needs (sampler.py GROUPS), for charging the measured cost matrix.
NEEDS = {"P0": "box", "P1": "box+procs", "P1b": "box+procs", "P2": "box+procs",
         "P3": "box+procs+sockets", "P4": "box+procs+sockets", "P5": "box+procs+sockets"}
COST_LIMIT = gates.SAMPLER_CPU_MAX

Config = collections.namedtuple(
    "Config", "policy cpu pty net wait age grace window interval staleness exclusions lifecycle",
    defaults=(None, None, None, "agnostic", None, 0.0, None, 1, True, True, True))


def config_key(c):
    return "|".join(str(x) for x in c)


def signals_used(c):
    return sum(1 for x in (c.cpu, c.pty, c.net, c.age, c.grace or None) if x is not None)


def all_configs():
    out = []
    for i in INTERVALS:
        out += [Config("P0", interval=i), Config("P1", interval=i), Config("P1b", interval=i)]
        out += [Config("P2", cpu=c, interval=i) for c in CPU_GRID]
        votes = list(itertools.product(CPU_GRID, PTY_RATE_GRID, NET_GRID, WAIT_RULES, SOCKET_AGE_GRID))
        out += [Config("P3", c, p, n, w, a, 0.0, None, i) for c, p, n, w, a in votes]
        for pol in HYSTERESIS_POLICIES:
            for (c, p, n, w, a), g, win in itertools.product(votes, GRACE_GRID, WINDOWS):
                out.append(Config(pol, c, p, n, w, a, g, win, i))
    return out


# ---- a run, and the stream a policy sees ----------------------------------------------------------------

Interval = gates.Interval


def load_jsonl(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


class Run:
    """One recorded run. `truth` is used only to build gate intervals; policies get a Stream."""

    def __init__(self, meta, header, samples, pty, lifecycle, truth, footer=None, key="", tags=None):
        self.meta, self.header, self.samples, self.pty = meta, header, samples, pty
        self.lifecycle, self.truth, self.footer, self.key = lifecycle, truth, footer, key
        self.scenario = meta["scenario"]
        self.scale = meta.get("scale", 1.0)
        self.compressed = bool(meta.get("compressed"))
        self.mode = meta.get("mode", "detached")
        self.variant = meta.get("variant") or ""
        self.tags = tags or {}
        self._feats = {}
        gaps = [b["t"] - a["t"] for a, b in zip(samples, samples[1:])]
        self.n_samples, self.gap_max = len(samples), max(gaps or [0.0])

    def feats(self, interval_s, exclusions=True):
        """Per-tick features at a policy cadence, computed once and shared by scoring and the report."""
        key = (interval_s, exclusions)
        if key not in self._feats:
            if self.samples is None:
                raise RuntimeError("raw samples were released; %s was only prepared for the default grid" % (key,))
            self._feats[key] = features(Stream(self, interval_s), exclusions)
        return self._feats[key]

    def release_raw(self):
        """Keep the features for the grid and drop the raw trace: the tuning set is ~150 runs of up to 6150
        samples, and holding every raw sample at once is the memory bill nobody wants."""
        for interval in INTERVALS:
            self.feats(interval)
        self.samples = self.pty = self.lifecycle = None

    @classmethod
    def load(cls, d, key="", tags=None):
        with open(os.path.join(d, "meta.json")) as f:
            meta = json.load(f)
        trace = load_jsonl(os.path.join(d, "trace.jsonl"))
        return cls(meta, next(r for r in trace if r["type"] == "header"), [r for r in trace if r["type"] == "s"],
                   load_jsonl(os.path.join(d, "pty.jsonl")), load_jsonl(os.path.join(d, "lifecycle.jsonl")),
                   load_jsonl(os.path.join(d, "truth.jsonl")),
                   next((r for r in trace if r["type"] == "footer"), None), key, tags)

    def intervals(self):
        return [Interval(t["scenario"], t["phase"], t["label"], t["start"], t["end"]) for t in self.truth]


class Stream:
    """What a policy may look at: samples at the policy's cadence plus counters bucketed into those ticks."""

    def __init__(self, run, interval_s):
        rec = run.header["interval"]
        k = round(interval_s / rec)
        if k < 1 or abs(k * rec - interval_s) > 1e-6:
            raise ValueError("cannot replay %.1f s from a trace recorded at %.1f s" % (interval_s, rec))
        self.interval_s, self.k, self.downsampled = interval_s, k, k > 1
        self.samples = [s for s in run.samples if s["tick"] % k == 0]  # a k-second sampler's own ticks
        self.header = run.header
        self.t = [s["t"] for s in self.samples]
        pty = sorted(run.pty, key=lambda e: e["t"])
        self._pty_t = [e["t"] for e in pty]
        self._out, self._in = [0], [0]
        self._in_t = []
        for e in pty:
            self._out.append(self._out[-1] + (e["n"] if e["d"] == "out" else 0))
            self._in.append(self._in[-1] + (e["n"] if e["d"] == "in" else 0))
            if e["d"] == "in":
                self._in_t.append(e["t"])
        self._spans = sorted((e["t"], e["event"]) for e in run.lifecycle)

    def pty_out_between(self, a, b):
        i, j = bisect.bisect_right(self._pty_t, a), bisect.bisect_right(self._pty_t, b)
        return self._out[j] - self._out[i]

    def last_input_before(self, t):
        i = bisect.bisect_right(self._in_t, t)
        return self._in_t[i - 1] if i else None

    def lifecycle_open(self, prev_t, t):
        """(operations open at t, operations started in (prev_t, t]) from the agent's own exec service."""
        depth = starts = 0
        for when, event in self._spans:
            if when > t:
                break
            depth += 1 if event == "start" else -1
            if event == "start" and when > prev_t:
                starts += 1
        return depth, starts


# ---- features and votes ----------------------------------------------------------------------------------

def _closure(roots, kids):
    seen, stack = set(), list(roots)
    while stack:
        p = stack.pop()
        for c in kids.get(p, ()):
            if c not in seen:
                seen.add(c)
                stack.append(c)
    return seen


def _min_age(a, b):
    vals = [x for x in (a, b) if x is not None]
    return min(vals) / 1000.0 if vals else 0.0  # unknown age counts as recent: the conservative reading


def tick_features(s, prev, interval_s, sampler_pid, exclusions, pty_rate, since_input, lifecycle):
    """One tick's features from a sample, the previous sample and the counters the caller owns (pty rate over
    PTY_WINDOW_S, seconds since the last pty input, whether an agent-owned operation is open or just started).
    Shared by the replay (`features`) and the live classifier (`live.py`), so the closed loop cannot drift from
    the code the gates were scored with."""
    procs = s.get("procs") or []
    kids = collections.defaultdict(list)
    for p in procs:
        kids[p[1]].append(p[0])
    roots = set(s.get("roots") or [])
    excluded = set()
    if exclusions:
        excluded = set(OWN_PIDS) | {sampler_pid} | _closure([sampler_pid], kids)
        named = [p[0] for p in procs if p[4] in EXCLUDED_COMMS]
        excluded |= set(named) | _closure(named, kids)
    cand = [p for p in procs if p[0] not in excluded and p[0] not in roots and p[6] != "Z"]
    wchan = {p[0]: p[9] for p in procs}
    dt = (s["t"] - prev["t"]) if prev else interval_s
    prev_ticks = {p[0]: p[7] for p in (prev.get("procs") or [])} if prev else {}
    cpu = 0.0
    for p in cand:
        # A process first seen now is credited at most one core for this interval: its earlier CPU is unknown.
        used = p[7] - prev_ticks[p[0]] if p[0] in prev_ticks else min(p[7], dt * CLK_TCK)
        cpu += max(0, used) / CLK_TCK
    cpu = cpu / dt if prev else 0.0
    tree = _closure(roots, kids)
    cand_pids = {p[0] for p in cand}
    age_agn = age_tty = None
    for row in s.get("sockets") or []:
        if row[0] != "ESTAB":
            continue
        owners = [pid for _, pid in (row[5] or []) if pid in cand_pids]
        if not owners:
            continue
        age = _min_age(row[6], row[7])
        age_agn = age if age_agn is None else min(age_agn, age)
        if any(not wchan.get(pid, "").startswith(TTY_WCHAN) for pid in owners):
            age_tty = age if age_tty is None else min(age_tty, age)
    return {
        "t": s["t"],
        "fg_wait": any(wchan.get(r, "").startswith("do_wait") for r in roots),
        "tree_live": any(p[0] in tree and p[6] != "Z" for p in procs),
        "cand_live": bool(cand),
        "cpu": cpu,
        "d_state": any(p[6] == "D" for p in cand),
        "timer": any(p[9].startswith(TIMER_WCHAN) for p in cand),
        "age_agnostic": age_agn, "age_tty_aware": age_tty,
        "pty_rate": pty_rate,
        "since_input": since_input,
        "net": ((s["net_rx"] + s["net_tx"] - prev["net_rx"] - prev["net_tx"]) / dt) if prev else 0.0,
        "lifecycle": lifecycle,
    }


def features(stream, exclusions=True):
    """Everything a vote needs, per tick, computed once per (stream, exclusions) and reused across the grid."""
    out, prev = [], None
    for s in stream.samples:
        prev_t = prev["t"] if prev else s["t"] - stream.interval_s
        last_in = stream.last_input_before(s["t"])
        open_ops, started = stream.lifecycle_open(prev_t, s["t"])
        out.append(tick_features(
            s, prev, stream.interval_s, stream.header["pid"], exclusions,
            stream.pty_out_between(s["t"] - PTY_WINDOW_S, s["t"]) / PTY_WINDOW_S,
            (s["t"] - last_in) if last_in is not None else float("inf"), open_ops > 0 or started > 0))
        prev = s
    return out


def vote(c, f):
    """One tick's instantaneous BUSY vote (True/False) for a config."""
    if c.policy == "P0":
        return f["fg_wait"]
    if c.policy == "P1":
        return f["tree_live"]
    if c.policy == "P1b":
        return f["cand_live"]
    busy = f["cpu"] >= c.cpu or f["d_state"]
    if c.policy == "P2":
        return busy
    age = f["age_agnostic" if c.wait == "agnostic" else "age_tty_aware"]
    sock = age is not None and (c.age is None or age <= c.age)
    busy = (busy or f["pty_rate"] >= c.pty or f["timer"] or sock
            or (c.net is not None and f["net"] >= c.net)
            or (c.grace > 0 and f["since_input"] <= c.grace))
    if c.policy == "P5" and c.lifecycle:
        busy = busy or f["lifecycle"]
    return busy


def verdict_series(c, feats, window_s):
    """Votes -> a change-point verdict series [(t, BUSY|IDLE)]. Hysteresis holds BUSY for `window_s` after the
    last BUSY vote; the staleness rule (D10) makes the verdict BUSY once the newest sample is older than
    STALENESS_FACTOR intervals, until fresh data arrives."""
    events, last_busy, current = [], None, None

    def put(t, verdict):
        nonlocal current
        if verdict != current:
            events.append((t, verdict))
            current = verdict

    for i, f in enumerate(feats):
        if c.staleness and c.policy in HYSTERESIS_POLICIES and i and f["t"] - feats[i - 1]["t"] > gates.STALENESS_FACTOR * c.interval:
            put(feats[i - 1]["t"] + gates.STALENESS_FACTOR * c.interval, BUSY)
        if vote(c, f):
            last_busy = f["t"]
        held = last_busy is not None and f["t"] - last_busy < window_s
        put(f["t"], BUSY if (last_busy == f["t"] or held) else IDLE)
    return events


def window_for(c, run):
    if c.window is None:
        return 0.0
    return (gates.WINDOW_GRID_COMPRESSED_S if run.compressed else gates.WINDOW_GRID_S)[c.window]


# ---- cost ------------------------------------------------------------------------------------------------

def load_cost_matrix(path=None):
    with open(path or os.path.join(HERE, "cost_matrix.json")) as f:
        return json.load(f)["cost"]


def charged_cost(c, matrix):
    """The measured Python-sampler cost of the signal set and interval this policy needs, on an idle box and
    under 500 processes. A 2 s policy is charged the 1 s cost (a conservative reading: only 1 s and 5 s were
    measured). Returns (idle, loaded); this is an UPPER BOUND on a native sampler, so the cost gate is
    provisional and never used to exclude a config."""
    row = matrix[NEEDS[c.policy]]["1" if c.interval < 5 else "5"]
    return row["0"], row["500"]


# ---- scoring ---------------------------------------------------------------------------------------------

def failed(results):
    return sorted(g for g, (verdict, _) in results.items() if verdict == gates.FAIL)


def score_run(c, run, feats, d3_fallback=False, cost=None):
    verdicts = verdict_series(c, feats, window_for(c, run))
    idle_window = window_for(c, run)
    return gates.evaluate(verdicts, run.intervals(), c.interval, idle_window, d3_fallback=d3_fallback,
                          sampler_cpu=cost), verdicts


def check_scale(runs, pipeline_check):
    bad = [r.key for r in runs if abs(r.scale - 1.0) > 1e-9]
    if bad and not pipeline_check:
        sys.exit("refusing to score %d run(s) at scale != 1.0 (e.g. %s): a scaled trace cannot exercise the "
                 "windows. Use --pipeline-check for plumbing only." % (len(bad), bad[0]))


def select_winner(rows):
    """THE SELECTION RULE (pre-registered; edit it and the run is void).

    `rows`: one dict per config with `config` (a Config), `passes_all` (zero failures on every scored tuning
    run, D3 fallback applied), `false_busy` (mean false-busy fraction over idle runs), `cost` (charged idle
    cost), `flaps` (mean scenario-12 flaps/hour) and `signals` (count of signals used).

    Eligible: passes_all AND the `agnostic` wait rule. `tty-aware` separates 3b from 4b only because the
    synthetic agent blocks in a tty read; it is reported as a conditional alternative, never selected.
    Among the eligible, minimise in order: false-busy fraction; charged sampler cost; number of signals; idle
    window; then prefer the LONGER sampling interval, then the fewer-signal policy order P0..P5, then the
    config key (a deterministic last resort). Returns None if nothing is eligible: that is a FAIL finding."""
    eligible = [r for r in rows if r["passes_all"] and r["config"].wait == "agnostic"]
    if not eligible:
        return None
    order = {p: i for i, p in enumerate(POLICIES)}
    return min(eligible, key=lambda r: (round(r["false_busy"], 6), r["cost"], r["signals"],
                                        r["config"].window if r["config"].window is not None else -1,
                                        -r["config"].interval, order[r["config"].policy], config_key(r["config"])))


def ceiling_report(verdicts, work):
    """OQ22 (never a gate): for scenario 17's BUSY work, what each ceiling semantics would do. `force-sleep`
    kills the job iff the policy's continuous BUSY stretch outlasts the ceiling."""
    longest = max((b - a for a, b in gates.busy_runs(verdicts, work)), default=0.0)
    return {str(cap): {"force-sleep": "kills the job" if longest > cap else "ok", "advisory": "ok",
                       "ask": "asks the user" if longest > cap else "ok"} for cap in CEILINGS_S}, longest


# ---- the analysis --------------------------------------------------------------------------------------

def evaluate_all(runs, configs, matrix, progress=None):
    """Pass 1 (no D3 exemption) over every config, then D3 mechanised over the `agnostic` grid, then pass 2 with
    the exemption where it fires. Returns (per-config summaries, d3_fallback)."""
    scored = [r for r in runs if r.mode == "detached" and not r.variant and r.tags.get("role") != "serial-control"]

    def feats_for(run, c):
        return run.feats(c.interval, c.exclusions)

    pass1 = {}
    for n, c in enumerate(configs):
        pass1[config_key(c)] = {r.key: score_run(c, r, feats_for(r, c))[0] for r in scored}
        if progress and n % 200 == 0:
            progress("pass 1: %d/%d configs" % (n, len(configs)))
    family = [c for c in configs if c.wait == "agnostic"]  # the whole grid, as gates.d3_fallback_fires says
    d3_rows = []
    for c in family:
        res = pass1[config_key(c)]
        four = [res[r.key] for r in scored if r.scenario == "4b" and r.key in res]
        three = [res[r.key] for r in scored if r.scenario == "3b" and r.key in res]
        d3_rows.append({"four_b_false_idle_zero": all(g["false_idle"][0] == gates.PASS for g in four),
                        "three_b_no_busy_forever": all(g["no_busy_forever"][0] == gates.PASS for g in three)})
    d3 = gates.d3_fallback_fires(d3_rows)
    summaries = []
    for c in configs:
        res = pass1[config_key(c)]
        if d3:
            res = {r.key: (score_run(c, r, feats_for(r, c), True)[0] if r.scenario == "3b" else res[r.key])
                   for r in scored}
        # The gate's value is a fraction only when it PASSED (on FAIL it is the offending run's length).
        idle_fb = [g["no_busy_forever"][1] for g in res.values() if g["no_busy_forever"][0] == gates.PASS]
        flaps = [gates.flap_metric(score_run(c, r, feats_for(r, c))[1], r.intervals())
                 for r in scored if r.scenario == "12"]
        flaps = [x for x in flaps if x is not None]
        summaries.append({
            "config": c, "key": config_key(c), "runs": len(scored),
            "failed_runs": sum(1 for r in scored if failed(res[r.key])),
            "passes_all": all(not failed(res[r.key]) for r in scored),
            "failures": collections.Counter(g for r in scored for g in failed(res[r.key])),
            "false_busy": sum(idle_fb) / len(idle_fb) if idle_fb else 0.0,
            "cost": charged_cost(c, matrix)[0], "cost_loaded": charged_cost(c, matrix)[1],
            "signals": signals_used(c), "flaps": sum(flaps) / len(flaps) if flaps else 0.0,
            "downsampled": c.interval > 1, "per_run": res,
        })
    return summaries, d3


def verdicts_for(c, run):
    return verdict_series(c, run.feats(c.interval, c.exclusions), window_for(c, run))


def mismatch(a, b, start_a, start_b, length):
    """Share of the 1 s grid over `length` seconds, aligned at each run's first phase, where verdicts differ."""
    n = int(length)
    return sum(1 for k in range(n) if gates.verdict_at(a, start_a + k) != gates.verdict_at(b, start_b + k)) / max(1, n)


def control_report(c, runs):
    """D7: each serial control against its parallel twin (same seed, same config, only the scheduling differs)."""
    by_key = {r.key: r for r in runs}
    out = []
    for r in runs:
        if r.tags.get("role") != "serial-control":
            continue
        twin = by_key.get(r.key[: -len("-serial")])
        if twin is None:
            continue
        va, vb = verdicts_for(c, twin), verdicts_for(c, r)
        length = min(twin.truth[-1]["end"] - twin.truth[0]["start"], r.truth[-1]["end"] - r.truth[0]["start"])
        m = mismatch(va, vb, twin.truth[0]["start"], r.truth[0]["start"], length)
        out.append({"twin": twin.key, "control": r.key, "mismatch": m, "ok": m <= CONTROL_MAX_MISMATCH})
    return out


def per_scenario(c, runs, d3):
    rows = {}
    for r in runs:
        res, v = score_run(c, r, r.feats(c.interval, c.exclusions), d3 and r.scenario == "3b")
        row = rows.setdefault((r.scenario, r.compressed), {"runs": 0, "failed": 0, "gates": collections.Counter(),
                                                            "ttb": [], "tti": []})
        row["runs"] += 1
        f = failed(res)
        row["failed"] += 1 if f else 0
        row["gates"].update(f)
        if res["provider_deadline"][1] is not None:
            row["ttb"].append(res["provider_deadline"][1])
        if res["time_to_idle"][1] is not None:
            row["tti"].append(res["time_to_idle"][1])
    return rows


def report(runs, excluded, summaries, d3, winner, matrix, pipeline_check, commit):
    scored = [r for r in runs if r.mode == "detached" and not r.variant and r.tags.get("role") != "serial-control"]
    L = []
    w = L.append
    w("# OQ19 tuning analysis")
    w("")
    w("**PIPELINE CHECK ONLY: NOT A RESULT.** Scaled runs; the windows cannot be exercised." if pipeline_check
      else "Scored tuning set (scale 1.0). Parameters are chosen here and frozen; the hold-out set (T6) carries the claim.")
    w("")
    w("Analysis code at `%s`. Runs scored: %d detached (full %d, compressed %d); attached %d; 500-process variant %d; "
      "serial controls %d; excluded %d." % (
          commit, len(scored), sum(1 for r in scored if not r.compressed), sum(1 for r in scored if r.compressed),
          sum(1 for r in runs if r.mode == "attached"), sum(1 for r in runs if r.variant),
          sum(1 for r in runs if r.tags.get("role") == "serial-control"), len(excluded)))
    for key, why in excluded:
        w("* excluded `%s`: %s (kept in the manifest; not scored)" % (key, why))
    w("")
    w("## D3 (3b vs 4b)")
    w("The fallback %s over the agent-agnostic grid: %s." % (
        "FIRES" if d3 else "does not fire",
        "no candidate had 4b false-idle = 0 AND 3b no-busy-forever, so 3b and 4b are treated as inseparable, both BUSY "
        "(never-idle wins), and 3b is exempt from no-busy-forever as an accepted cost (OQ7: an idle agent with a held "
        "connection keeps its box awake)" if d3 else "some candidate separated them without relying on the tty-read wait"))
    w("")
    w("## The ladder: best config per policy (fewest failed runs, then least false-busy)")
    w("| policy | best config | failed runs / runs | failing gates | downsampled |")
    w("|---|---|---|---|---|")
    for pol in POLICIES:
        rows = [s for s in summaries if s["config"].policy == pol]
        if not rows:
            continue
        b = min(rows, key=lambda s: (s["failed_runs"], s["false_busy"], s["key"]))
        w("| %s | `%s` | %d / %d | %s | %s |" % (pol, b["key"], b["failed_runs"], b["runs"],
                                                 ", ".join("%s x%d" % kv for kv in sorted(b["failures"].items())) or "none",
                                                 "yes" if b["downsampled"] else "no"))
    w("")
    w("## Winner (pre-registered rule, `select_winner`)")
    if winner is None:
        w("**NONE: no agent-agnostic config passes every gate on every tuning run. That is a FAIL finding, not a "
          "reason to loosen a gate.**")
    else:
        c = winner["config"]
        w("`%s`" % winner["key"])
        w("")
        w("* charged sampler cost (Python, upper bound): %.2f%% idle, %.2f%% at 500 processes, against the %.1f%% gate: "
          "**PROVISIONAL** (a native sampler has to be re-measured; never used to exclude a config)" % (
              100 * winner["cost"], 100 * winner["cost_loaded"], 100 * COST_LIMIT))
        w("* mean false-busy fraction on idle scenarios: %.4f; scenario 12 flaps/hour: %.1f (reference %.0f, a "
          "reference line, not a gate)" % (winner["false_busy"], winner["flaps"], gates.FLAP_REFERENCE_PER_HOUR))
        w("* interval %s s%s" % (c.interval, ": DOWNSAMPLED from the 1 s trace, so T6 must re-record at this cadence"
                                 if winner["downsampled"] else ""))
        w("")
        w("| scenario | scale | runs | failed | worst time-to-busy (s) | worst time-to-idle (s) |")
        w("|---|---|---|---|---|---|")
        for (sid, comp), row in sorted(per_scenario(c, scored, d3).items()):
            w("| %s | %s | %d | %d | %s | %s |" % (sid, "compressed" if comp else "full", row["runs"], row["failed"],
                                                   "%.1f" % max(row["ttb"]) if row["ttb"] else "-",
                                                   "%.1f" % max(row["tti"]) if row["tti"] else "-"))
        w("")
        claim_runs = []
        for r in scored:
            res, _ = score_run(c, r, r.feats(c.interval, c.exclusions), d3 and r.scenario == "3b")
            claim_runs.append({"set": "tuning", "scale": "compressed" if r.compressed else "full", "mode": r.mode,
                               "scenario": r.scenario, "failed_gates": failed(res)})
        _, table = gates.final_claim(claim_runs)  # the verdict half is FAIL by construction: no hold-out yet
        w("Per-group table (`gates.final_claim`; the tuning set never carries the claim, and its bounds are for the "
          "record): 0 failures in N runs only bounds the miss rate at the 95% upper bound shown.")
        w("")
        w("| set / scale / mode | runs | runs that can false-idle | failing runs | 95% bound, false-idle | "
          "critical scenarios (4b, 7, 10): runs / 95% bound |")
        w("|---|---|---|---|---|---|")
        for (kset, kscale, kmode), g in sorted(table.items()):
            w("| %s / %s / %s | %d | %d | %d | %.2f | %d / %.2f |" % (
                kset, kscale, kmode, g["runs"], g["busy_runs"], g["failures_any"], g["bound_false_idle"],
                g["critical_runs"], g["critical_bound"]))
        w("")
        w("### What an idle box costs (the OQ7 input): BUSY verdict time on the idle-only scenarios, winner config")
        w("| scenario | runs | mean BUSY fraction | awake hours per day if left like this |")
        w("|---|---|---|---|")
        for sid in ("1", "2a", "2b", "2c", "3a", "3b", "8", "16"):
            fr = []
            for r in scored:
                if r.scenario == sid and not r.compressed:
                    idle = next(i for i in r.intervals() if i.label == IDLE)
                    fr.append(gates.false_busy_seconds(verdicts_for(c, r), idle) / (idle.end - idle.start))
            if fr:
                w("| %s | %d | %.3f | %.1f |" % (sid, len(fr), sum(fr) / len(fr), 24 * sum(fr) / len(fr)))
        w("")
        w("### Serial control (D7)")
        ctl = control_report(c, runs)
        for x in ctl:
            w("* `%s` vs `%s`: %.1f%% of seconds differ: **%s**" % (
                x["twin"], x["control"], 100 * x["mismatch"], "match" if x["ok"] else "DIFFER"))
        if not ctl:
            w("* no control pair recorded")
        w("")
        w("### Scenario 17 and the awake ceiling (OQ22: reported, never gated)")
        for r in scored:
            if r.scenario == "17":
                work = next(i for i in r.intervals() if i.phase == "work")
                report_, longest = ceiling_report(verdicts_for(c, r), work)
                w("* `%s`: longest continuous BUSY %.0f s; %s" % (r.key, longest, "; ".join(
                    "ceiling %s s -> force-sleep %s" % (cap, v["force-sleep"]) for cap, v in report_.items())))
        w("")
        w("### Attached vs detached (scenario 15: reported, never scored)")
        w("PREDICTION, written before any attached trace was analysed: the harness's fake client resizes the window "
          "every 30 s, which redraws a full-screen TUI (several KB of pty output). That lands in the 10 s pty-rate "
          "window for a third of the time, above both grid values, so attached 2a/2c/3a will look false-busy. "
          "That is the harness's client, not a policy defect, and it does not enter the claim.")
        for r in runs:
            if r.mode == "attached" and labels.BY_ID[r.scenario].gated:
                res, _ = score_run(c, r, r.feats(c.interval, c.exclusions), d3 and r.scenario == "3b")
                w("* `%s`: %s" % (r.key, "all gates pass" if not failed(res) else "FAILS " + ", ".join(failed(res))))
    cond = [s for s in summaries if s["passes_all"] and s["config"].wait == "tty-aware"]
    w("")
    w("## Conditional alternative (tty-aware wait rule; requires an agent that blocks in a tty read)")
    w("%d passing tty-aware config(s). Not selectable until a real agent trace confirms the wait class." % len(cond))
    w("")
    w("## 500-process build (sampler starvation)")
    for r in runs:
        if r.variant:
            w("* `%s`: %d samples, longest silence %.1f s; sampler cost %.2f%% of a core (steady)" % (
                r.key, r.n_samples, r.gap_max, 100 * ((r.footer or {}).get("cpu_fraction_steady") or 0)))
    return "\n".join(L) + "\n"


def live_verdicts(path):
    """verdicts.jsonl (one line per tick) -> a change-point series."""
    events = []
    for row in load_jsonl(path):
        if not events or events[-1][1] != row["verdict"]:
            events.append((row["t"], row["verdict"]))
    return events


def closed_loop_check(run_dir, pipeline_check=False, d3_fallback=False):
    """F7: score a run made with the real classifier and shim in the box (driver `--closed-loop`).

    Three questions, none answerable by replay: (1) do the LIVE verdicts pass the gates, with the classifier's own
    activity in the box; (2) does the live classifier agree with a replay of its own trace (it runs the same
    code, so a disagreement means the counters or the loop are wrong); (3) what did sampler + classifier + shim
    cost (a Python upper bound: PROVISIONAL, reported, never a reason to excuse a gate)."""
    run = Run.load(run_dir, key=os.path.basename(os.path.normpath(run_dir)))
    check_scale([run], pipeline_check)
    cl = run.meta.get("closed_loop")
    if not cl:
        sys.exit("%s was not recorded with --closed-loop" % run_dir)
    c = Config(**cl["config"])
    window_s = cl["window_s"]
    live = live_verdicts(os.path.join(run_dir, "verdicts.jsonl"))
    replay = verdict_series(c, run.feats(c.interval, c.exclusions), window_s)
    start, end = run.truth[0]["start"], run.truth[-1]["end"]
    diff = mismatch(live, replay, start, start, end - start)
    footer = run.footer or {}
    cost = ((footer.get("cpu_s") or 0.0) + (run.meta.get("shim_cpu_s") or 0.0)) / max(footer.get("wall_s") or 1.0, 1e-9)
    results = gates.evaluate(live, run.intervals(), c.interval, window_s,
                             d3_fallback=d3_fallback and run.scenario == "3b")
    bad = failed(results)
    return {"run": run.key, "scenario": run.scenario, "config": config_key(c), "window_s": window_s,
            "gates": {g: v for g, (v, _) in results.items()}, "failed": bad,
            "live_vs_replay_mismatch": diff, "agrees_with_replay": diff <= CLOSED_LOOP_MAX_MISMATCH,
            "self_cost_fraction": cost, "self_cost_provisional_pass": cost <= COST_LIMIT,
            "busy_ticks": sum(1 for _, v in live if v == BUSY), "pipeline_check": pipeline_check,
            "compressed": run.compressed, "mode": run.mode,
            "passes": not bad and diff <= CLOSED_LOOP_MAX_MISMATCH}


def holdout_claim(results):
    """The final claim, from closed-loop results of the HOLD-OUT set: `gates.final_claim` over runs whose failed
    gates are the live gate failures plus `live_vs_replay` when the loop disagreed with its own replay."""
    runs = [{"set": "holdout", "scale": "compressed" if r["compressed"] else "full", "mode": r["mode"],
             "scenario": r["scenario"],
             "failed_gates": r["failed"] + ([] if r["agrees_with_replay"] else ["live_vs_replay"])}
            for r in results]
    return gates.final_claim(runs)


def run_holdout(root, frozen_path, pipeline_check, out_dir):
    with open(frozen_path) as f:
        frozen = json.load(f)
    rows = load_jsonl(os.path.join(root, "manifest.jsonl"))
    results, excluded = [], []
    for row in rows:
        if row["status"] != "recorded" or not (row.get("check") or {}).get("ok"):
            excluded.append((row["key"], row["status"] if row["status"] != "recorded" else "check_trace failed"))
            continue
        res = closed_loop_check(os.path.join(root, row["dir"]), pipeline_check, frozen.get("d3_fallback", False))
        recorded = json.loads(row["closed_loop"])["config"] if row.get("closed_loop") else None
        if recorded != frozen["config"]:
            sys.exit("%s was not recorded at the frozen configuration: the hold-out is void" % row["key"])
        results.append(res)
    verdict, table = holdout_claim(results)
    text = ["# OQ19 hold-out result", "",
            "**PIPELINE CHECK ONLY: NOT A RESULT.**" if pipeline_check else "Scored hold-out set (scale 1.0, closed loop).",
            "", "Frozen configuration `%s` (tuning commit `%s`, D3 fallback %s)." % (
                frozen.get("key"), frozen.get("tuning_commit"), "applied" if frozen.get("d3_fallback") else "not needed"),
            "", "## Claim: **%s**" % verdict, "",
            "PASS requires zero failures on all gates in the hold-out set, detached, at BOTH scales, and the "
            "pre-registered sample size (every gated scenario x5 full-length, every critical scenario x20 compressed).",
            "", "| set / scale / mode | runs | can false-idle | failing | 95% bound false-idle | sample size ok |",
            "|---|---|---|---|---|---|"]
    for (kset, kscale, kmode), g in sorted(table.items()):
        text.append("| %s / %s / %s | %d | %d | %d | %.2f | %s |" % (
            kset, kscale, kmode, g["runs"], g["busy_runs"], g["failures_any"], g["bound_false_idle"],
            g["sample_size_ok"]))
    bad = [r for r in results if not r["passes"]]
    text += ["", "## Failing runs (%d)" % len(bad)]
    text += ["* `%s`: %s%s" % (r["run"], ", ".join(r["failed"]) or "no gate", "" if r["agrees_with_replay"]
                              else "; the live verdicts disagree with a replay of the trace") for r in bad]
    costs = sorted(r["self_cost_fraction"] for r in results)
    if costs:
        text += ["", "## Classifier + sampler + shim cost (Python, an upper bound: PROVISIONAL)",
                 "median %.2f%%, worst %.2f%% of one core, against the %.1f%% gate; %d of %d runs at or under it." % (
                     100 * costs[len(costs) // 2], 100 * costs[-1], 100 * COST_LIMIT,
                     sum(1 for x in costs if x <= COST_LIMIT), len(costs))]
    for key, why in excluded:
        text.append("* excluded `%s`: %s (kept in the manifest)" % (key, why))
    os.makedirs(out_dir, exist_ok=True)
    stem = "holdout-pipeline-check" if pipeline_check else "holdout"
    with open(os.path.join(out_dir, stem + ".md"), "w") as f:
        f.write("\n".join(text) + "\n")
    with open(os.path.join(out_dir, stem + ".json"), "w") as f:
        json.dump({"claim": verdict, "pipeline_check": pipeline_check, "runs": len(results), "failing": len(bad),
                   "table": {"/".join(k): {a: b for a, b in v.items() if a != "by_scenario"} for k, v in table.items()}},
                  f, indent=1, default=str)
    print("\n".join(text))
    return verdict


def load_tuning(root, pipeline_check=False):
    rows = load_jsonl(os.path.join(root, "manifest.jsonl"))
    runs, excluded = [], []
    for row in rows:
        if row["status"] != "recorded" or not (row.get("check") or {}).get("ok"):
            excluded.append((row["key"], row["status"] if row["status"] != "recorded" else "check_trace failed"))
            continue
        run = Run.load(os.path.join(root, row["dir"]), row["key"], {"role": row["role"], "rep": row["rep"]})
        run.release_raw()
        runs.append(run)
    check_scale(runs, pipeline_check)
    return runs, excluded


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("set", choices=("tuning", "closed-loop", "holdout"))
    ap.add_argument("--frozen", default=os.path.join(HERE, "results", "frozen.json"))
    ap.add_argument("--freeze", action="store_true", help="tuning: write the winner to results/frozen.json")
    ap.add_argument("--run", help="closed-loop: the run directory to check")
    ap.add_argument("--root", default=None)
    ap.add_argument("--out", default=os.path.join(HERE, "results"))
    ap.add_argument("--pipeline-check", action="store_true", help="allow scaled runs; output is stamped, not a result")
    args = ap.parse_args()
    if args.set == "closed-loop":
        out = closed_loop_check(args.run, args.pipeline_check)
        print(json.dumps(out, indent=1))
        sys.exit(0 if out["passes"] else 1)
    if args.set == "holdout":
        sys.exit(0 if run_holdout(args.root or os.path.join(HERE, "traces", "holdout"), args.frozen,
                                  args.pipeline_check, args.out) == gates.PASS else 1)
    runs, excluded = load_tuning(args.root or os.path.join(HERE, "traces", "tuning"), args.pipeline_check)
    matrix = load_cost_matrix()
    summaries, d3 = evaluate_all(runs, all_configs(), matrix, progress=print)
    winner = select_winner(summaries)
    commit = os.popen("git -C %s rev-parse --short HEAD" % HERE).read().strip()
    text = report(runs, excluded, summaries, d3, winner, matrix, args.pipeline_check, commit)
    os.makedirs(args.out, exist_ok=True)
    stem = "tuning-pipeline-check" if args.pipeline_check else "tuning"
    with open(os.path.join(args.out, stem + ".md"), "w") as f:
        f.write(text)
    with open(os.path.join(args.out, stem + ".json"), "w") as f:
        json.dump({"pipeline_check": args.pipeline_check, "commit": commit, "d3_fallback": d3,
                   "winner": winner["key"] if winner else None,
                   "configs": [{k: (dict(v) if isinstance(v, collections.Counter) else v)
                                for k, v in s.items() if k not in ("config", "per_run")} for s in summaries]},
                  f, indent=1, default=str)
    print(text)
    if args.freeze:
        if winner is None or args.pipeline_check:
            sys.exit("nothing to freeze: %s" % ("a pipeline check is not a result" if args.pipeline_check
                                               else "no config passed every gate"))
        with open(args.frozen, "w") as f:
            json.dump({"config": winner["config"]._asdict(), "key": winner["key"], "d3_fallback": d3,
                       "tuning_commit": commit,
                       "note": "Frozen by `analyze.py tuning --freeze`. Commit this file BEFORE recording the "
                               "hold-out: record.py holdout refuses an uncommitted or modified file."}, f, indent=1)
        print("frozen -> %s (commit it before recording the hold-out)" % args.frozen)


if __name__ == "__main__":
    main()
