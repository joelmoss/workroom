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
from labels import BUSY, IDLE, STALE

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
                  "unattended-upgr", "apt.systemd.dai", "wr-agent")
OWN_PIDS = (1,)                    # container init: the driver in the harness, systemd in production
CEILINGS_S = (1800, 3600, 14400)   # OQ22: candidate awake ceilings, reported for scenario 17 only

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


def features(stream, exclusions=True):
    """Everything a vote needs, per tick, computed once per (stream, exclusions) and reused across the grid."""
    out, prev = [], None
    pid_sampler = stream.header["pid"]
    for s in stream.samples:
        procs = s.get("procs") or []
        kids = collections.defaultdict(list)
        for p in procs:
            kids[p[1]].append(p[0])
        roots = set(s.get("roots") or [])
        excluded = set()
        if exclusions:
            excluded = set(OWN_PIDS) | {pid_sampler} | _closure([pid_sampler], kids)
            named = [p[0] for p in procs if p[4] in EXCLUDED_COMMS]
            excluded |= set(named) | _closure(named, kids)
        cand = [p for p in procs if p[0] not in excluded and p[0] not in roots and p[6] != "Z"]
        wchan = {p[0]: p[9] for p in procs}
        dt = (s["t"] - prev["t"]) if prev else stream.interval_s
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
        prev_t = prev["t"] if prev else s["t"] - stream.interval_s
        last_in = stream.last_input_before(s["t"])
        open_ops, started = stream.lifecycle_open(prev_t, s["t"])
        out.append({
            "t": s["t"],
            "fg_wait": any(wchan.get(r, "").startswith("do_wait") for r in roots),
            "tree_live": any(p[0] in tree and p[6] != "Z" for p in procs),
            "cand_live": bool(cand),
            "cpu": cpu,
            "d_state": any(p[6] == "D" for p in cand),
            "timer": any(p[9].startswith(TIMER_WCHAN) for p in cand),
            "age_agnostic": age_agn, "age_tty_aware": age_tty,
            "pty_rate": stream.pty_out_between(s["t"] - PTY_WINDOW_S, s["t"]) / PTY_WINDOW_S,
            "since_input": (s["t"] - last_in) if last_in is not None else float("inf"),
            "net": ((s["net_rx"] + s["net_tx"] - prev["net_rx"] - prev["net_tx"]) / dt) if prev else 0.0,
            "lifecycle": open_ops > 0 or started > 0,
        })
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
    scored = [r for r in runs if r.mode == "detached" and not r.variant]
    cache = {}

    def feats_for(run, c):
        key = (run.key, c.interval, c.exclusions)
        if key not in cache:
            cache[key] = features(Stream(run, c.interval), c.exclusions)
        return cache[key]

    pass1 = {}
    for n, c in enumerate(configs):
        pass1[config_key(c)] = {r.key: score_run(c, r, feats_for(r, c))[0] for r in scored}
        if progress and n % 200 == 0:
            progress("pass 1: %d/%d configs" % (n, len(configs)))
    family = [c for c in configs if c.wait == "agnostic" and c.policy in HYSTERESIS_POLICIES]
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


def load_tuning(root, pipeline_check=False):
    rows = load_jsonl(os.path.join(root, "manifest.jsonl"))
    runs, excluded = [], []
    for row in rows:
        if row["status"] != "recorded" or not (row.get("check") or {}).get("ok"):
            excluded.append((row["key"], row["status"] if row["status"] != "recorded" else "check_trace failed"))
            continue
        runs.append(Run.load(os.path.join(root, row["dir"]), row["key"], {"role": row["role"], "rep": row["rep"]}))
    check_scale(runs, pipeline_check)
    return runs, excluded


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("set", choices=("tuning",))
    ap.add_argument("--root", default=os.path.join(HERE, "traces", "tuning"))
    ap.add_argument("--pipeline-check", action="store_true", help="allow scaled runs; output is stamped, not a result")
    args = ap.parse_args()
    runs, excluded = load_tuning(args.root, args.pipeline_check)
    summaries, d3 = evaluate_all(runs, all_configs(), load_cost_matrix(), progress=print)
    winner = select_winner([s for s in summaries])
    print("runs scored: %d, excluded: %d, D3 fallback fires: %s" % (len(runs), len(excluded), d3))
    print("winner: %s" % (config_key(winner["config"]) if winner else "NONE (a FAIL finding)"))
    if args.pipeline_check:
        print("PIPELINE CHECK ONLY: not a result")


if __name__ == "__main__":
    main()
