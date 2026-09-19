"""OQ19 acceptance gates and metrics.

PRE-REGISTERED. Committed before any trace is recorded, reviewed by an agent that did not write it, then
frozen (plan decision D6). Editing this file after traces exist voids the run: re-register and re-record.
A gate the results embarrass is a finding, not a bug to fix here.

Contract (all times are CLOCK_MONOTONIC seconds, floats):

* A VERDICT SERIES is a time-sorted list of `(t, "BUSY" | "IDLE")`. Each verdict holds until the next. Time
  before the first verdict counts as IDLE (the conservative reading for a busy interval).
* A TRUTH INTERVAL is what the scenario driver did, from its own timeline: `Interval(scenario, phase,
  label, start, end)`. Truth never comes from a signal.
* Every gate is a pure function of those two. `evaluate` applies all of them to one run.

Gate definitions match the approved plan (`OQ19 measurement plan`, decisions D1 to D12 and F1 to F8).
"""

import math
from collections import namedtuple

from labels import BUSY, IDLE, DEADLINE_HEADROOM_S, PROVIDER_TIMEOUT_S

Interval = namedtuple("Interval", "scenario phase label start end")

# ---- thresholds (fixed here, before any result exists) -------------------------------------------------

ONSET_MARGIN_S = 2.0            # D12: onset allowance = the policy's sampling interval + this
NO_BUSY_FOREVER_TAIL_S = 10.0   # an idle interval may stay BUSY for its hysteresis tail + this
FALSE_BUSY_MAX_FRACTION = 0.05  # total BUSY verdict time / total IDLE time, across idle intervals
TIME_TO_IDLE_MARGIN_S = 10.0    # after work ends: idle window + this
FLAP_MAX_PER_HOUR = 6.0         # scenario 12 only
SAMPLER_CPU_MAX = 0.005         # fraction of one core, sampler + shim, while detached
CONFIDENCE = 0.95               # one-sided, for the upper bound on the miss rate

# Grids the policies are tuned over (analyze.py); recorded here so they are part of the registration.
INTERVAL_GRID_S = (1, 2, 5)
WINDOW_GRID_S = (30, 60, 120, 300, 600)

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
    excused hysteresis tail is at most 5% of idle time.

    A BUSY run that begins at the interval's start is the policy's hysteresis tail after work ended and may
    last `tails[interval]` + 10 s (`tails` maps interval -> tail seconds, 0 for a pure-idle scenario); any
    BUSY run that begins later has no such excuse and may last 10 s. The excused part of that opening tail
    is left out of the 5% fraction, so a policy is not failed twice for the window it was tuned with.
    `exempt` holds scenarios excused by the pre-registered D3 fallback (3b)."""
    scored = [i for i in idle_intervals if i.scenario not in exempt]
    unexcused = 0.0
    for i in scored:
        tail_allowance = NO_BUSY_FOREVER_TAIL_S + tails.get(i, 0.0)
        opening = 0.0
        for a, b in busy_runs(verdicts, i):
            starts_at_open = abs(a - i.start) < 1e-9
            if b - a > (tail_allowance if starts_at_open else NO_BUSY_FOREVER_TAIL_S):
                return FAIL, b - a
            if starts_at_open:
                opening = b - a
        unexcused += false_busy_seconds(verdicts, i) - min(opening, tails.get(i, 0.0))
    idle_total = sum(i.end - i.start for i in scored)
    fraction = unexcused / idle_total if idle_total else 0.0
    return (PASS if fraction <= FALSE_BUSY_MAX_FRACTION else FAIL), fraction


def gate_time_to_idle(verdicts, post_intervals, idle_window_s):
    worst = 0.0
    for i in post_intervals:
        tti = time_to_idle(verdicts, i)
        if tti is None or tti > idle_window_s + TIME_TO_IDLE_MARGIN_S:
            return FAIL, tti
        worst = max(worst, tti)
    return PASS, worst


def gate_flapping(verdicts, start, end):
    rate = flaps_per_hour(verdicts, start, end)
    return (PASS if rate <= FLAP_MAX_PER_HOUR else FAIL), rate


def gate_sampler_cost(cpu_fraction):
    return (PASS if cpu_fraction <= SAMPLER_CPU_MAX else FAIL), cpu_fraction


def d3_fallback_fires(policy_results):
    """The D3 rule, mechanised so no one decides it after seeing results. `policy_results` is an iterable
    of dicts with `four_b_false_idle_zero` and `three_b_no_busy_forever` (booleans). The fallback fires iff
    NO candidate policy in the grid achieves both: 3b and 4b are then inseparable and the policy must treat
    both as BUSY (never-idle wins), 3b being excused from the no-busy-forever gate as an accepted cost."""
    return not any(r["four_b_false_idle_zero"] and r["three_b_no_busy_forever"] for r in policy_results)


def evaluate(verdicts, intervals, interval_s, idle_window_s, tails=None, exempt=(), sampler_cpu=None):
    """All per-run gates for one run of one policy. Scenario 12 (flapping) is passed via `bursty` intervals
    named scenario "12"; ungated scenarios (13, 17) are reported by analyze.py, never here."""
    busy = [i for i in intervals if i.label == BUSY and i.scenario != "12"]
    idle = [i for i in intervals if i.label == IDLE and i.scenario != "13"]
    post = [i for i in idle if i.phase == "post"]
    # A policy's hysteresis tail IS its idle window: it keeps saying BUSY that long after work ends.
    tails = tails or {i: idle_window_s for i in post}
    out = {
        "false_idle": gate_false_idle(verdicts, busy, interval_s),
        "provider_deadline": gate_provider_deadline(verdicts, busy),
        "no_busy_forever": gate_no_busy_forever(verdicts, idle, tails, exempt),
        "time_to_idle": gate_time_to_idle(verdicts, post, idle_window_s),
    }
    bursty = [i for i in intervals if i.scenario == "12"]
    if bursty:
        out["flapping"] = gate_flapping(verdicts, min(i.start for i in bursty), max(i.end for i in bursty))
    if sampler_cpu is not None:
        out["sampler_cost"] = gate_sampler_cost(sampler_cpu)
    return out


def final_claim(runs):
    """D5 + F6. `runs` is an iterable of dicts {set: "tuning"|"holdout", scale: "full"|"compressed",
    scenario, critical, false_idle_failed: bool}. Returns, per (set, scale), the failures, the run count and
    the 95% upper bound on the miss rate; never pooled across sets or scales. The claim (PASS) requires the
    HOLD-OUT set at BOTH scales to have zero false-idle failures; tuning results are reported but never
    carry the claim."""
    groups = {}
    for r in runs:
        key = (r["set"], r["scale"])
        n, f = groups.get(key, (0, 0))
        groups[key] = (n + 1, f + (1 if r["false_idle_failed"] else 0))
    table = {k: {"runs": n, "failures": f, "upper_bound": upper_bound(f, n)} for k, (n, f) in groups.items()}
    holdout = [table.get(("holdout", "full")), table.get(("holdout", "compressed"))]
    ok = all(h is not None and h["failures"] == 0 for h in holdout)
    return (PASS if ok else FAIL), table
