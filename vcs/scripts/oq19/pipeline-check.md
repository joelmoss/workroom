# OQ19 pipeline check (plan Sequence step 1)

Run 2026-09-19 inside the measurement image (`vcs/scripts/oq19/Dockerfile`: Debian bookworm-slim, Python
3.11.2) on Docker 29.8, aarch64, kernel `7.0.12-linuxkit`, container started with `--cpus=1 --memory=512m`.
The boxd VM has not been checked yet (T7): everything below is the CONTAINER, and `boundary.md` says the
permission rows are to be verified in both places.

This file records what was found. It does not edit the frozen contract (`labels.py`, `gates.py`,
`boundary.md`); where a finding corrects an assumption in `boundary.md`, it says so here.

## Signal availability

| Signal | Result | Note |
|---|---|---|
| cgroup v2 `cpu.stat` (`usage_usec`) | available | The container sees its own cgroup as the root (`/proc/self/cgroup` is `0::/`), so this is the container's total CPU, exited processes included. |
| cgroup `cgroup.procs`, `pids.current` | available | Includes pid 1 and the sampler itself. |
| `/proc/stat` aggregate CPU | available | Reports the whole linuxkit VM, not the container: only a fallback where there is no per-workroom cgroup. |
| `/proc/loadavg` | available | **Also VM-wide** (`0.37` on an idle container): reference only, as the plan expected. |
| `/proc/net/dev` | available | `eth0` counters; loopback must be excluded (`procfs.net_bytes` does). |
| `/proc/<pid>/stat`, `wchan`, `io`, `syscall` | all readable (as root) | `wchan` names the wait: `hrtimer_nanosleep` for `sleep`, `poll_schedule_timeout.constprop.0` for an idle `bash` on its pty. |
| `/proc/net/tcp` | available | No socket ages: `ss` is needed for those. |
| `ss -tinp` | available | Gives `lastsnd`/`lastrcv`/`lastack` in ms and, as root, the owning pid. Two idle connections held 3 s read `lastsnd`/`lastrcv` of about 3000: signal S6b works. |
| `/proc` mount | `rw,nosuid,nodev,noexec,relatime` | No `hidepid`. |
| tools | tmux, vim, less, make, gcc, setsid, ss, curl all present | |

## Corrections to assumptions in `boundary.md`

1. **`nice -n -5` fails even as root.** `boundary.md` says the container gets `CAP_SYS_NICE` because it runs
   as root. It does not: Docker drops the capability, and `nice: cannot set niceness: Permission denied`.
   `run.sh` therefore passes `--cap-add=SYS_NICE` (verified: the sampler then runs at nice -5, and its header
   records `nice_ok`). On a real box the same permission question applies to the agent's uid: still open,
   T7.
2. **A self-renamed process really does break a naive `/proc/<pid>/stat` parser.** A real process that set its
   own name to `evil) S 1 (x` produced `16 (evil) S 1 (x) R 1 1 1 ...`; reading fields by whitespace gives
   state `S` and ppid `1` where the truth is state `R`. Captured as a fixture and tested.
3. **The kernel truncates `comm` to 15 bytes**, so name-based exclusion (boundary.md) sees a truncated name for
   long process names; the sampler records the resolved `exe` path as well (read once per process), and the
   exclusion list should prefer it.
4. **Scenario 3b needs a server that HOLDS the connection.** Python's `http.server` speaks HTTP/1.0 and closes
   after the response, leaving the client in `CLOSE-WAIT`: not an idle keepalive. The fixture capture used a raw
   socket server that accepts and holds; scenario 3b must do the same.

## Sampler cost (the plan's gate: <= 0.5% of one core, `ss` children included)

Steady state (interpreter startup and the first tick excluded), 20 s per cell, percent of one core.
The sampler is Python, so these are an UPPER BOUND on a native implementation, and they show which signals
cost what; the gate still has to be re-measured against the shipped implementation.

| Signals read | 1 s, idle | 1 s, 500 procs | 5 s, idle | 5 s, 500 procs |
|---|---|---|---|---|
| box (cgroup `cpu.stat`, pids, `/proc/stat`, net, loadavg): O(1) | 0.17 | 0.22 | 0.05 | 0.08 |
| box + every process (`stat`, `wchan`): O(processes) | 0.28 | **2.52** | 0.07 | **0.58** |
| box + `ss -tinp` (one fork per tick) | **0.92** | **1.76** | 0.20 | 0.31 |
| all three | **0.82** | **2.83** | 0.18 | **0.66** |

Bold cells exceed the gate. What it says:

* **Box-level signals are effectively free** and pass everywhere, including under 500 processes.
* **The per-process walk is the cost that scales with the build**: about 50 microseconds per process per tick
  in Python. At 500 processes it fails the gate even at 5 s.
* **The `ss` fork costs about 0.75% of a core per tick per Hz.** It passes at 5 s and fails at 1 s.
* So for THIS sampler, a policy that needs per-process detail or socket ages is only affordable at a coarse
  interval or a small process count. That is a cost-model input to the policy choice, not something to
  design away: the analysis should charge each policy the cost of the signal set and interval it needs
  (`gates.gate_sampler_cost` takes the measured fraction, so this needs no change to the frozen gates).
* A native sampler should be cheaper by a large factor (no interpreter, tight parsing), but that is an
  estimate, not a measurement.

## End-to-end check

Scenario 1 (idle bash), `--scale 0.1` (a 30 s phase), 1 s interval: the truth log and the sampler share one
monotonic clock (phase start `302915.6` against sample times `302914.6`...), 33 samples with none overran
(max lateness 0.45 ms), the shell's pty produced exactly one output event (its prompt), and the sampler saw
the shell (state `S`, waiting on `poll_schedule_timeout`), itself at nice -5, and the driver.

## Open for later tasks

* The boxd VM: agent uid, `hidepid`, cgroup v2, `ss`, `nice -n -5` (T7, all listed in `boundary.md`).
* `--cap-add=SYS_NICE` is a Docker/podman flag; Apple's `container` runtime may not accept it, and `run.sh`
  currently passes the same flags to all three.
* Only scenario 1 has been run. Every BUSY scenario needs its action module (T3); the driver refuses to
  record a BUSY phase without one.

## T3: every scenario runs and does what its label says

All 21 scenario entries (18 scenarios; 2a/2b/2c, 3a/3b and 4a/4b are separate entries) ran end to end at
scale 0.05 and passed `check_trace.py`, which asserts from the SAMPLER'S trace that:

* the truth log matches `labels.py` phase for phase, contiguously and for the expected duration, with samples
  across the whole timeline and the sampler at nice -5;
* each scenario shows what it claims: vim, less or tmux running (2a to 2c); the self-renamed `2.1.232` agent
  (3a to 4b), with an established peer connection where the label needs one; a spinner's pty output in 4a and
  NONE in 4b's wait; a saturating build (5); `dd` (6); a live `sleep` with no CPU (7); the listening server (8)
  and inbound bytes on `eth0` only when it is hit from outside (9); a job that outlives its shell in another
  session (10); exactly one exec lifecycle span matching the BUSY phase and no pty activity (11); CPU bursts
  (12); `watch` (13); keystrokes (14); sshd and cron (16); about 0.3 cores (17); one STALE gap during which the
  sampler is silent and which straddles the start of the work (18).

**The checks can fail.** `run.sh controls` runs a trace as a scenario it is not (same phase shape) and requires
FAIL: 8 of 8 were caught (4a/4b, 2a/2b/2c, 3a as 3b, 8/13).

Found and fixed while getting there: a 0x0 pty and a missing `TERM` stop curses, vim and tmux from starting;
the agent crashed without a peer (3a has none). The 500-process build variant of scenario 5 produced 504
processes and cost the Python sampler about 1.6% of a core at 1 s with every signal on: the same picture as the
cost matrix above.

**Finding: `nice -n -5` does not protect the sampler from a `--cpus=1` quota.** In that same 500-process run the
container was throttled for 169 s of `throttled_usec` in 55 s of wall time (the sampler now records
`cg_throttled_usec`), and the sampler's longest silence was 4.5 s at a 1 s interval, with the sampler at nice -5.
The CFS quota throttles the whole cgroup, sampler included; niceness only orders work inside it. Consequences:
(a) the staleness rule (D10) is not hypothetical, a saturating build in a quota'd box blinds the classifier;
(b) `check_trace.py` does not fail the 500-process variant on sampling gaps, because there the gaps ARE the
result; (c) T4 must not read a gap in a CPU-bound scenario as a harness fault, and the boxd VM (no quota) must be
compared against this before the sampler's priority is trusted.

Known limits, stated rather than hidden:

* **Attached mode is only a periodic window resize** (a GUI client redrawing an idle TUI). It is a real
  difference in pty output but a thin one; the claim "attached and detached agree" is only as strong as that.
* **Parallel runs share a throttled box.** Each container has its own quota, so the throttling above is per
  run, not from neighbours; D7's serial control still has to show the same verdicts.
* **The F7 closed loop is not complete**: scenario 16 runs the sampler at its real cadence but there is no
  lifecycle shim yet (T6 and T7). The idle-box result is therefore a lower bound on self-activity.
* **The peer is a Docker sidecar.** On boxd (T7) it has to be another machine or the Mac; the scenario modules
  only need `OQ19_PEER=host:port` and a name (`box`) the peer can connect back to.
* **The agent is synthetic**, as the plan said.
* Jobs end 0.2 s before their phase does (typing a command takes a moment), so the last 0.2 s of a BUSY phase
  is idle. It is inside the onset allowance and the hysteresis tail, but it is there.

## Closed loop (F7): the classifier and the shim in the box

`live.py` runs the sampler and the policy in one process, `scenarios/tools/wakeshim.sh` runs as `wr-wakeshim`, and
the driver publishes the pty and lifecycle counters the agent would own. Checked on scenario 16 at scale 0.1
(a pipeline check: the numbers say the plumbing works, not what the policy does):

* the sampler sees `wr-wakeshim` and its `sleep`/`cat` children; with the exclusion list they never vote, and the
  live verdicts stay IDLE (0 BUSY of 65 ticks);
* **RED control:** the same run with `exclusions: false` is BUSY on all 65 ticks, so the closed-loop gate can fail;
* the live verdicts equal a replay of the run's own trace (0% of seconds differ), and a unit test proves the same on
  a synthetic trace with pty, input and lifecycle counters, and fails when any of those three is dropped from `live.py`;
* self-cost, Python upper bound: classifier + sampler 0.35% of a core plus the shim 0.12% = 0.52%, just OVER the 0.5%
  gate at a 1 s interval. The shim is a shell loop that forks `cat` and `sleep` every second, so its cost is mostly
  process creation. Provisional, as every Python cost here is; a native implementation is expected to be cheaper, and
  a 5 s interval divides the shim's cost by five.

Limits: the counters reach `live.py` through a file refreshed every 0.2 s (the agent would hold them in memory), and
the shim only touches a file where the real one calls the provider.
