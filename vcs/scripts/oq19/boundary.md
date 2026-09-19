# OQ19 — the production counting boundary (plan decision D9)

PRE-REGISTERED with `labels.py` and `gates.py`. Reviewed, then frozen.

## Why this file exists

In the harness a container holds only the scenario, so "everything running in the container" IS the work,
and a box-level CPU counter is a perfect busy signal. A real workroom box also runs sshd, the agent, the
lifecycle shim, systemd, cron, apt timers and the provider's own guest tooling. A policy that only works
because the harness is quiet would keep real boxes awake forever (the design doc's "busy forever", OQ7's
uncapped cost) or misjudge real work. The agent has no cgroup or process-tracking code beyond session and
process-group setup (`grep -i cgroup vcs/crates/wr-agent/src` is empty), so production membership is not a
given and has to be specified before a policy is chosen.

The wakefulness verdict is **per machine**: the provider's idle timers are per machine (Phase 0 item 5).

## What counts as work (BUSY may be raised by)

1. **An agent-owned operation in flight**: an exec-service command (`run_exec_with`, start to completion,
   including its timeout). Signal S9; policy P5 (F8). Exact by construction, no heuristics.
2. **A live process in the tree of an agent-created pty session** (session leader and its descendants, by
   the `/proc/<pid>/stat` PPid walk that mirrors `process::descendants`), whose activity or state is not the
   idle-TUI pattern.
3. **An escapee**: a `setsid`/double-forked descendant that has left the session tree. Invisible to (2).
   Caught only by a box-level or per-cgroup view (S1b, S2 box-level), which is why the exclusion list below
   is load-bearing.

## Exclusion list (never counts, whatever it does)

Applied by executable path and process name, the same rule production would use, in every policy that uses
a box-level or cgroup view (P1b to P5):

* the agent itself (`wr-agent serve` and its own protocol threads) and its sampler;
* the lifecycle shim (the item-5 `sh` loop and whatever replaces it);
* `sshd` and its per-connection children **while idle** (a held connection is not work; a user command
  started through it is, via rules 1 and 2);
* init/systemd, journald, dbus, cron and its scheduled housekeeping, apt/unattended-upgrades timers, package
  update daemons, and the provider's in-guest agent/CLI.

Scenario 16 exists to prove the list works: an idle box running all of the above at their real cadence must
stay IDLE, with the sampler and shim running in closed loop (F7).

## The classifier's own activity (F7)

The sampler, the agent and the shim generate CPU and network activity of their own. Attribution is fixed
now: their pids are excluded by the list above, and any residual self-activity that cannot be attributed by
pid is measured once on an idle box (scenario 16) and subtracted. A policy is not allowed to be sustained
BUSY by its own monitoring; scenario 16 in closed loop gates exactly that.

## Permissions (what each signal needs; to be VERIFIED in the pipeline check, T2)

| Signal | Needs | Verify |
|---|---|---|
| `/proc/<pid>/stat`, `comm`, `cmdline` | readable by any uid unless the box mounts `/proc` with `hidepid` | `mount \| grep proc` on the boxd VM |
| `/proc/<pid>/fd`, `io`, `wchan` for other uids | root or same uid; the workroom's processes run as the workroom user, system daemons are excluded anyway | which uid the agent runs as on boxd |
| cgroup v2 `cpu.stat`, `cgroup.procs` | readable in the agent's own cgroup; per-session cgroups would need delegation | cgroup v2 present in the boxd VM and the container |
| `/proc/stat`, `/proc/net/dev` | any uid | none |
| `ss -ti` (socket last-send/receive ages) | any uid (inet_diag) for all sockets; socket-to-pid attribution needs same uid | `ss` present (D4 image and `setup.sh`) |

If a verification fails, the affected signal is dropped from the candidate policies and the results doc says
so; the gates and labels do not change.

## Assumptions stated up front (a failed one is a finding, not an edit to this file)

* The box is single-tenant: everything not on the exclusion list belongs to the workroom's user.
* The agent can read every process it needs to count; an unreadable process is counted as BUSY (fail safe).
* The production sampler runs at the same cadence and priority the harness sampler does (`nice -n -5`).
