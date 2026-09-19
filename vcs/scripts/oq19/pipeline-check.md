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
