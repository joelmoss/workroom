"""OQ19 acceptance gates and metrics.

PRE-REGISTERED. Committed before any trace is recorded, reviewed by an agent that did not write it, then
frozen (plan decision D6). Editing this file after traces exist voids the run: re-register and re-record.
A gate the results embarrass is a finding, not a bug to fix here.

Contract (all times are CLOCK_MONOTONIC seconds, floats):

* A VERDICT SERIES is a time-sorted list of `(t, "BUSY" | "IDLE")`. Each verdict holds until the next. Time
  before the first verdict counts as IDLE (the conservative reading for a busy interval).
* A TRUTH INTERVAL is what the scenario driver did, from its own timeline: `Interval(scenario, phase,
  label, start, end)`. Truth never comes from a signal.
* Every gate is a pure function of those two. `evaluate` applies all of them to one run. NOTHING a gate
  excuses (hysteresis tails, the D3 exemption) is taken from the policy under test: `evaluate` derives the
  tails from the idle window the policy is configured with, and the exemption only from `d3_fallback`.

Gate definitions match the approved plan (`OQ19 measurement plan`, decisions D1 to D12 and F1 to F8).
"""

import math
from collections import namedtuple

import labels
from labels import BUSY, IDLE, STALE, DEADLINE_HEADROOM_S, PROVIDER_TIMEOUT_S

Interval = namedtuple("Interval", "scenario phase label start end")

# ---- thresholds (fixed here, before any result exists) -------------------------------------------------

ONSET_MARGIN_S = 2.0            # D12: onset allowance = the policy's sampling interval + this
NO_BUSY_FOREVER_TAIL_S = 10.0   # an idle interval may stay BUSY for its hysteresis tail + this
FALSE_BUSY_MAX_FRACTION = 0.05  # total BUSY verdict time / total IDLE time, across idle intervals
TIME_TO_IDLE_MARGIN_S = 10.0    # after work ends: idle window + this
FLAP_REFERENCE_PER_HOUR = 6.0   # scenario 12: a REFERENCE LINE reported beside the flap metric, NOT a gate
SAMPLER_CPU_MAX = 0.005         # fraction of one core, sampler + shim, while detached
CONFIDENCE = 0.95               # one-sided, for the upper bound on the miss rate

# Grids the policies are tuned over (analyze.py); recorded here so they are part of the registration.
INTERVAL_GRID_S = (1, 2, 5)
WINDOW_GRID_S = (30, 60, 120, 300, 600)
WINDOW_GRID_COMPRESSED_S = (3, 6, 12, 30, 60)  # compressed runs scale the POLICY's windows, not the provider
STALENESS_FACTOR = 2  # D10: a sample older than this many sampling intervals means the verdict is BUSY

# Repeats (D5, F6). Tuning traces are used to choose parameters. The hold-out set is recorded AFTER the
# parameters are frozen and is what the final claim rests on. Compressed and full-length are never pooled.
TUNING_REPEATS = 5
COMPRESSED_CRITICAL_REPEATS = 20
HOLDOUT_REPEATS_FULL = 5
HOLDOUT_REPEATS_COMPRESSED_CRITICAL = 20
MODES = ("detached", "attached")  # scenario 15: the poll loop must run while detached

PASS = "PASS"
FAIL = "FAIL"
NA = "N/A"


# ---- verdict series ------------------------------------------------------------------------------------

def check_sorted(verdicts):
    """`verdict_at` assumes a time-sorted series and would silently misread an unsorted one."""
    if not all(a[0] <= b[0] for a, b in zip(verdicts, verdicts[1:])):
        raise ValueError("verdicts must be time-sorted")  # not an assert: `python3 -O` would strip it


def verdict_at(verdicts, t):
    """The verdict in force at time t (IDLE before the first one)."""
    current = IDLE
    for when, verdict in verdicts:
        if when > t:
            break
        current = verdict
    return current


def _segments(verdicts, start, end):
    """Split [start, end) into (a, b, verdict) pieces where the verdict is constant."""
    points = sorted({start, end, *[t for t, _ in verdicts if start < t < end]})
    return [(a, b, verdict_at(verdicts, a)) for a, b in zip(points, points[1:])]


def _seconds(verdicts, start, end, verdict):
    return sum(b - a for a, b, v in _segments(verdicts, start, end) if v == verdict)


# ---- metrics -------------------------------------------------------------------------------------------

def onset_allowance(interval_s):
    return interval_s + ONSET_MARGIN_S


def false_idle_seconds(verdicts, busy, allowance):
    """Seconds declared IDLE inside a BUSY interval, after its onset allowance."""
    return _seconds(verdicts, min(busy.start + allowance, busy.end), busy.end, IDLE)


def time_to_busy(verdicts, busy):
    """Seconds from a BUSY interval's start to the first BUSY verdict at or after it; None if never."""
    if verdict_at(verdicts, busy.start) == BUSY:
        return 0.0
    for when, verdict in verdicts:
        if busy.start < when < busy.end and verdict == BUSY:
            return when - busy.start
    return None


def provider_deadline_ok(ttb, idle_elapsed_s=PROVIDER_TIMEOUT_S - DEADLINE_HEADROOM_S,
                         provider_timeout_s=PROVIDER_TIMEOUT_S):
    """D12: the delay from work start to a BUSY verdict must never cross the provider deadline that is
    already running. `idle_elapsed_s` is how long the provider's idle clock had run when the work started
    (labels.QUIET_BEFORE_S, the worst point). ttb None (never detected) is a failure."""
    return ttb is not None and idle_elapsed_s + ttb < provider_timeout_s


def busy_runs(verdicts, idle):
    """Contiguous stretches of BUSY verdict inside an idle interval, as (start, end) pairs."""
    runs = []
    for a, b, verdict in _segments(verdicts, idle.start, idle.end):
        if verdict != BUSY:
            continue
        if runs and abs(runs[-1][1] - a) < 1e-9:
            runs[-1] = (runs[-1][0], b)
        else:
            runs.append((a, b))
    return runs


def false_busy_seconds(verdicts, idle):
    return _seconds(verdicts, idle.start, idle.end, BUSY)


def time_to_idle(verdicts, idle):
    """Seconds from an IDLE interval's start (work just ended) to the first IDLE verdict; None if never."""
    if verdict_at(verdicts, idle.start) == IDLE:
        return 0.0
    for when, verdict in verdicts:
        if idle.start < when < idle.end and verdict == IDLE:
            return when - idle.start
    return None


def flaps_per_hour(verdicts, start, end):
    changes = 0
    previous = verdict_at(verdicts, start)
    for when, verdict in verdicts:
        if start < when < end:
            if verdict != previous:
                changes += 1
            previous = verdict
    return changes / ((end - start) / 3600.0)


def upper_bound(failures, runs, confidence=CONFIDENCE):
    """Exact one-sided (Clopper-Pearson) upper bound on the true miss rate after `failures` in `runs`.
    0 failures in 5 runs only bounds it near 45%; 0 in 25 near 12% (plan decision D5)."""
    if runs <= 0:
        return 1.0
    if failures >= runs:
        return 1.0
    lo, hi = failures / runs, 1.0
    for _ in range(100):
        mid = (lo + hi) / 2
        # P(X <= failures | p = mid): if it is still >= 1 - confidence, mid may be too small.
        cdf = sum(math.comb(runs, k) * mid**k * (1 - mid) ** (runs - k) for k in range(failures + 1))
        if cdf > 1 - confidence:
            lo = mid
        else:
            hi = mid
    return hi


# ---- gates ---------------------------------------------------------------------------------------------

def gate_false_idle(verdicts, busy_intervals, interval_s):
    """False-idle = 0 across every gated BUSY interval, after each interval's onset allowance."""
    allowance = onset_allowance(interval_s)
    worst = max((false_idle_seconds(verdicts, b, allowance) for b in busy_intervals), default=0.0)
    return (PASS if worst == 0 else FAIL), worst


def gate_provider_deadline(verdicts, busy_intervals):
    """D12: time-to-busy never crosses the provider deadline already running (work starts at the worst
    point of the provider's idle timer)."""
    worst = None
    for b in busy_intervals:
        ttb = time_to_busy(verdicts, b)
        if not provider_deadline_ok(ttb):
            return FAIL, ttb
        worst = ttb if worst is None else max(worst, ttb)
    return PASS, worst


def gate_no_busy_forever(verdicts, idle_intervals, tails, exempt=()):
    """No idle-labelled interval is declared BUSY for longer than allowed, and the BUSY time that is NOT an
    excused hysteresis tail is at most 5% of the idle time that is not an excused tail.

    A BUSY run that begins at the interval's start is the policy's hysteresis tail after work ended and may
    last `tails[interval]` + 10 s (`tails` maps interval -> tail seconds, 0 for a pure-idle scenario); any
    BUSY run that begins later has no such excuse and may last 10 s. The excused tail is left out of BOTH
    the numerator and the denominator of the 5% fraction, so a policy is neither failed twice for the window
    it was tuned with nor helped by the idle time that window covers. `exempt` may hold only the D3
    scenario (3b): excusing anything else would let a policy excuse itself."""
    if not set(exempt) <= {"3b"}:
        raise ValueError("only the pre-registered D3 scenario may be exempt")
    scored = [i for i in idle_intervals if i.scenario not in exempt]
    unexcused = 0.0
    idle_total = 0.0
    for i in scored:
        tail = tails.get(i, 0.0)
        opening = 0.0
        for a, b in busy_runs(verdicts, i):
            starts_at_open = abs(a - i.start) < 1e-9
            if b - a > (NO_BUSY_FOREVER_TAIL_S + tail if starts_at_open else NO_BUSY_FOREVER_TAIL_S):
                return FAIL, b - a
            if starts_at_open:
                opening = b - a
        excused = min(opening, tail)
        unexcused += false_busy_seconds(verdicts, i) - excused
        idle_total += (i.end - i.start) - min(tail, i.end - i.start)
    fraction = unexcused / idle_total if idle_total > 0 else 0.0
    return (PASS if fraction <= FALSE_BUSY_MAX_FRACTION else FAIL), fraction


def gate_time_to_idle(verdicts, post_intervals, idle_window_s):
    worst = 0.0
    for i in post_intervals:
        tti = time_to_idle(verdicts, i)
        if tti is None or tti > idle_window_s + TIME_TO_IDLE_MARGIN_S:
            return FAIL, tti
        worst = max(worst, tti)
    return PASS, worst


def gate_staleness(verdicts, gaps, interval_s):
    """D10: while the sampler is blind (a STALE truth interval, scenario 18) the policy must fail safe to
    BUSY. From STALENESS_FACTOR sampling intervals (+ the onset margin) after the gap begins until it ends,
    the verdict must be BUSY. A gap too short to test that window fails rather than passing vacuously."""
    worst = 0.0
    for g in gaps:
        start = g.start + STALENESS_FACTOR * interval_s + ONSET_MARGIN_S
        if start >= g.end:
            return FAIL, None
        worst = max(worst, _seconds(verdicts, start, g.end, IDLE))
    return (PASS if worst == 0 else FAIL), worst


def gate_sampler_cost(cpu_fraction):
    return (PASS if cpu_fraction <= SAMPLER_CPU_MAX else FAIL), cpu_fraction


def d3_fallback_fires(policy_results):
    """The D3 rule, mechanised so no one decides it after seeing results. `policy_results` is an iterable
    of dicts with `four_b_false_idle_zero` and `three_b_no_busy_forever` (booleans). The fallback fires iff
    NO candidate policy in the grid achieves both: 3b and 4b are then inseparable and the policy must treat
    both as BUSY (never-idle wins), 3b being excused from the no-busy-forever gate as an accepted cost."""
    return not any(r["four_b_false_idle_zero"] and r["three_b_no_busy_forever"] for r in policy_results)


def evaluate(verdicts, intervals, interval_s, idle_window_s, d3_fallback=False, sampler_cpu=None):
    """All per-run GATES for one run of one policy. Nothing is excused by the caller's say-so: the hysteresis
    tail of each post-work interval is the idle window the policy is configured with, and scenario 3b is
    exempt only when `d3_fallback` is True (which must come from `d3_fallback_fires`). Scenarios 12 (flaps),
    13 and 17 (OQ22) are ungated in the labels: they are metrics, reported by analyze.py, never gated here."""
    check_sorted(verdicts)
    # Gated-ness comes from the labels, so 12, 13 and 17 (reported, never gated) drop out without ids
    # hard-coded here.
    gated = [i for i in intervals if i.label == STALE or labels.BY_ID[i.scenario].gated]
    busy = [i for i in gated if i.label == BUSY]
    idle = [i for i in gated if i.label == IDLE]
    gaps = [i for i in gated if i.label == STALE]
    if any(i.scenario == "18" for i in gated) and not gaps:
        raise ValueError("scenario 18 requires its STALE gap interval; a missing one must not skip the gate")
    post = [i for i in idle if i.phase == "post"]
    tails = {i: idle_window_s for i in post}
    out = {
        "false_idle": gate_false_idle(verdicts, busy, interval_s),
        "provider_deadline": gate_provider_deadline(verdicts, busy),
        "no_busy_forever": gate_no_busy_forever(verdicts, idle, tails, ("3b",) if d3_fallback else ()),
        "time_to_idle": gate_time_to_idle(verdicts, post, idle_window_s),
    }
    if gaps:
        out["staleness"] = gate_staleness(verdicts, gaps, interval_s)
    if sampler_cpu is not None:
        out["sampler_cost"] = gate_sampler_cost(sampler_cpu)
    return out


def flap_metric(verdicts, intervals):
    """Scenario 12 flaps per hour: REPORTED (the trade-off curve), never a gate."""
    bursty = [i for i in intervals if i.scenario == "12"]
    if not bursty:
        return None
    return flaps_per_hour(verdicts, min(i.start for i in bursty), max(i.end for i in bursty))


def _can_fail_false_idle(scenario):
    s = labels.BY_ID[scenario]
    return s.gated and any(p.label == BUSY for p in s.phases)


def final_claim(runs):
    """D5 + F6. `runs` is an iterable of dicts {set: "tuning"|"holdout", scale: "full"|"compressed",
    mode: "detached"|"attached", scenario: "4b", failed_gates: [gate names that FAILED]}.

    Per (set, scale, mode) the table reports, never pooled across those keys:
      runs           gated runs
      busy_runs      runs that contain a gated BUSY interval (the only ones that CAN fail false-idle, so the
                     only honest denominator for its bound)
      failures_any   runs failing ANY gate
      bound_false_idle / bound_any   95% upper bounds on the miss rate
      critical       the same for scenarios 4b, 7, 10 alone
      by_scenario    (runs, failures) per scenario
    The claim is PASS iff the HOLD-OUT set, DETACHED (the mode the feature exists for), at BOTH scales, has
    zero failures on ALL gates AND meets its pre-registered sample size (`sample_size_ok`): every gated
    scenario at least HOLDOUT_REPEATS_FULL runs at full length, every critical scenario at least
    HOLDOUT_REPEATS_COMPRESSED_CRITICAL compressed. Tuning results and attached-mode results are reported
    but never carry it, and how much hold-out is enough cannot be decided after the traces exist."""
    groups = {}
    for r in runs:
        if not labels.BY_ID[r["scenario"]].gated:
            continue
        g = groups.setdefault((r["set"], r["scale"], r["mode"]), {
            "runs": 0, "busy_runs": 0, "failures_any": 0, "failures_false_idle": 0,
            "critical_runs": 0, "critical_failures": 0, "by_scenario": {}})
        failed = list(r["failed_gates"])
        g["runs"] += 1
        g["failures_any"] += 1 if failed else 0
        if _can_fail_false_idle(r["scenario"]):
            g["busy_runs"] += 1
            g["failures_false_idle"] += 1 if "false_idle" in failed else 0
        if labels.BY_ID[r["scenario"]].critical:
            g["critical_runs"] += 1
            g["critical_failures"] += 1 if failed else 0
        n, f = g["by_scenario"].get(r["scenario"], (0, 0))
        g["by_scenario"][r["scenario"]] = (n + 1, f + (1 if failed else 0))
    table = {}
    for key, g in groups.items():
        if key[1] == "full":
            enough = all(g["by_scenario"].get(s.id, (0, 0))[0] >= HOLDOUT_REPEATS_FULL for s in labels.GATED)
        else:
            enough = all(g["by_scenario"].get(s.id, (0, 0))[0] >= HOLDOUT_REPEATS_COMPRESSED_CRITICAL
                         for s in labels.CRITICAL)
        table[key] = dict(
            g,
            sample_size_ok=enough,
            bound_false_idle=upper_bound(g["failures_false_idle"], g["busy_runs"]),
            bound_any=upper_bound(g["failures_any"], g["runs"]),
            critical_bound=upper_bound(g["critical_failures"], g["critical_runs"]),
        )
    needed = [table.get(("holdout", "full", "detached")), table.get(("holdout", "compressed", "detached"))]
    ok = all(n is not None and n["failures_any"] == 0 and n["sample_size_ok"] for n in needed)
    return (PASS if ok else FAIL), table
