"""OQ19 scenario labels — the ground truth every policy is scored against.

PRE-REGISTERED. This file and `gates.py` are committed before any trace is recorded, reviewed by an agent
that did not write them, and then frozen (plan decision D6). Editing either after traces exist voids the
run: re-register and re-record.

A scenario is a sequence of phases. Each phase carries a ground-truth label, BUSY or IDLE, that comes from
what the scenario driver *did*, never from what any signal *reads*. The driver stamps the real phase
boundaries (CLOCK_MONOTONIC) into a truth log at run time; this table is the contract for which phases
exist and what they are labelled.

Rules behind the labels (design doc: remote-workrooms.md, busy/idle at :812-836, OQ19 at :1785):

* Work a user would be upset to see interrupted is BUSY: a build, a test run, a job that outlives its shell,
  a request in flight, an agent mid-turn (with or without a spinner), an agent-owned command.
* A box nobody is using is IDLE: a shell or full-screen TUI at its prompt, an agent at its prompt (even with
  a keepalive connection or a status-bar clock), a server listening with no traffic (owner decision).
* Every scenario that has a BUSY phase starts it after QUIET_BEFORE_S of idleness, the WORST POINT of the
  provider's idle timer (PROVIDER_TIMEOUT_S - DEADLINE_HEADROOM_S), so a slow verdict is the one that hurts.
"""

from collections import namedtuple

BUSY = "BUSY"
IDLE = "IDLE"
STALE = "STALE"  # a truth interval marking a sampler gap (scenario 18); scored by the staleness gate

# Provider model: boxd's shortest idle timer (Phase 0 item 5). The wake shim must assert BUSY before the
# provider's idle clock reaches PROVIDER_TIMEOUT_S; work is started when it stands at QUIET_BEFORE_S.
PROVIDER_TIMEOUT_S = 120
DEADLINE_HEADROOM_S = 10
QUIET_BEFORE_S = PROVIDER_TIMEOUT_S - DEADLINE_HEADROOM_S  # 110

# Long enough to outlast every idle window in the grid plus the provider timeout (D11): 10 min + 120 s
# = 12 min, rounded up to 15.
LONG_WAIT_S = 900
# After work ends the verdict may lag by the policy's window; the post phase must outlast the largest
# window (600) + the time-to-idle margin (10) + the largest sampling interval (5), with slack, or no
# policy at the top of the grid could ever pass (review finding). Checked by tests against gates.py.
POST_IDLE_S = 640

# COMPRESSED repeats (D5). What is compressed is the POLICY's timescale: the idle windows (gates.py:
# WINDOW_GRID_COMPRESSED_S), the long waits and the post phase. What is NOT compressed is the provider's
# real timing: the quiet phase stays QUIET_BEFORE_S and the provider-deadline gate is scored against the
# real 120 s, because that deadline is a property of the sampler's latency and cannot be shrunk (a 1 s
# headroom is unattainable with a 1 s sampling interval). Each compressed value keeps the D11 rule: a long
# wait outlasts the (compressed) largest window plus the REAL provider timeout.
LONG_WAIT_COMPRESSED_S = 200      # > 60 (largest compressed window) + 120 (provider timeout) + margin
POST_IDLE_COMPRESSED_S = 90       # >= 60 + 10 (time-to-idle margin) + 5 (largest interval) + slack

Phase = namedtuple("Phase", "name label seconds note compressed", defaults=(None,))
Scenario = namedtuple("Scenario", "id name gated critical phases note")


def _p(name, label, seconds, note="", compressed=None):
    return Phase(name, label, seconds, note, compressed)


def seconds(phase, compressed=False):
    """A phase's duration in a full-length or compressed run."""
    if compressed and phase.compressed is not None:
        return phase.compressed
    return phase.seconds


def _quiet():
    return _p("quiet", IDLE, QUIET_BEFORE_S, "idle box; the provider idle clock is at its worst point",
              compressed=QUIET_BEFORE_S)


def _post():
    return _p("post", IDLE, POST_IDLE_S, "work has ended; verdict may lag by the policy's hysteresis tail",
              compressed=POST_IDLE_COMPRESSED_S)


SCENARIOS = [
    Scenario("1", "idle-shell", True, False, [_p("idle", IDLE, 300)], "bash at its prompt"),
    Scenario("2a", "idle-vim", True, False, [_p("idle", IDLE, 300)], "vim open, untouched"),
    Scenario("2b", "idle-less", True, False, [_p("idle", IDLE, 300)], "less open, untouched"),
    Scenario(
        "2c", "idle-tmux-clock", True, False, [_p("idle", IDLE, 300)],
        "tmux with its default status clock: writes to the pty every 15 s while idle (adversarial for pty output rate)",
    ),
    Scenario(
        "3a", "idle-agent", True, False, [_p("idle", IDLE, 300)],
        "synthetic agent TUI at its prompt: alt screen, rewrites its own process title, blocked on the tty",
    ),
    Scenario(
        "3b", "idle-agent-keepalive", True, False, [_p("idle", IDLE, 300)],
        "as 3a, plus an idle keepalive TCP connection. EXEMPT from no-busy-forever iff the D3 fallback fires",
    ),
    Scenario(
        "4a", "agent-turn-spinner", True, False,
        [_quiet(), _p("turn", BUSY, 240, "spinner at 10 Hz, connection awaiting a slow server, token streaming"), _post()],
        "agent mid-turn, visibly working",
    ),
    Scenario(
        "4b", "agent-turn-silent", True, True,
        [_quiet(), _p("turn", BUSY, LONG_WAIT_S, "NO pty output; blocked on a slow server for the whole wait",
            compressed=LONG_WAIT_COMPRESSED_S), _post()],
        "the hardest case: indistinguishable from 3b on CPU. The wait outlasts every window (D11)",
    ),
    Scenario(
        "5", "bg-cpu-build", True, False,
        [_quiet(), _p("build", BUSY, 300, "make -j-shaped CPU job, shell back at its prompt"), _post()],
        "includes a 500-process variant for sampler cost",
    ),
    Scenario(
        "6", "bg-io-job", True, False,
        [_quiet(), _p("job", BUSY, 300, "disk-bound, low CPU"), _post()], "background I/O-bound job",
    ),
    Scenario(
        "7", "sleepy-job", True, True,
        [_quiet(), _p("sleep", BUSY, LONG_WAIT_S, "alive, no CPU, no I/O, nanosleep", compressed=LONG_WAIT_COMPRESSED_S), _post()],
        "the hard twin of an idle TUI on CPU alone (D11)",
    ),
    Scenario("8", "detached-server-idle", True, False, [_p("idle", IDLE, 300)], "listening, no CPU, no traffic: IDLE by owner decision"),
    Scenario(
        "9", "detached-server-active", True, False,
        [_quiet(), _p("traffic", BUSY, 300, "requests every 2 s from outside"), _post()], "same server, in use",
    ),
    Scenario(
        "10", "setsid-cpu-job", True, True,
        [_quiet(), _p("job", BUSY, 300, "setsid'd CPU job; its shell has exited"), _post()],
        "escapes the session and process-group tree",
    ),
    Scenario(
        "11", "exec-no-pty", True, False,
        [_quiet(), _p("exec", BUSY, 60, "agent-owned exec command, no pty (git fetch-shaped)"), _post()],
        "scored through the exec lifecycle (F8)",
    ),
    Scenario(
        "12", "bursty-job", False, False,
        [_p("bursts", BUSY, 1800, "5 s of CPU every 60 s")],
        "REPORTED as a trade-off curve, not gated (flaps/hour is a metric, not a gate: an always-BUSY policy "
        "would win it): the label depends on the hysteresis window under test",
    ),
    Scenario("13", "watch-top", False, False, [_p("watching", IDLE, 300)], "REPORTED, not gated: a human is looking; the label is ambiguous by intent"),
    Scenario(
        "14", "keystroke-activity", True, False,
        [_quiet(), _p("typing", BUSY, 60, "a keystroke every 2 s into an idle TUI"), _post()],
        "explicit activity; the grace window after typing is the parameter under test",
    ),
    Scenario(
        "16", "idle-noisy-box", True, False,
        [_p("idle", IDLE, 600, "sshd, cron, apt timers, the sampler and the shim at their real cadence")],
        "D9: an idle box that is NOT quiet. Also the closed-loop check that the classifier's own activity never sustains BUSY (F7)",
    ),
    Scenario(
        "17", "spans-ceiling", False, False,
        [_quiet(), _p("work", BUSY, 5400, "legitimate work longer than the proposed awake ceilings"), _post()],
        "REPORTED (OQ22): what each ceiling semantics would do to a long legitimate job",
    ),
    Scenario(
        "18", "gap-injection", True, False,
        [_quiet(), _p("work", BUSY, 300, "starts 5 s into a 15 s SIGSTOP of the sampler"), _post()],
        "D10: work that starts while the sampler is blind must still be protected. The driver also emits a "
        "STALE truth interval for the 15 s SIGSTOP; the staleness gate requires BUSY inside it",
    ),
]

BY_ID = {s.id: s for s in SCENARIOS}
GATED = [s for s in SCENARIOS if s.gated]
CRITICAL = [s for s in SCENARIOS if s.critical]  # 4b, 7, 10 (D5): a miss here loses real work
