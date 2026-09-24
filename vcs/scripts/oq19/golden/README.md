# Golden traces: the port contract (plan decision D2)

Ten hold-out runs, each with the inputs a policy may see and the verdict change-points the frozen
configuration produced from them. `analyze.py holdout` showed the live classifier in the box logged the
same change-points on every one (0.0% mismatch).

They are the CLASSIFIER's series, not the shim's timing. Across a sampler gap the fixture records the
staleness BUSY at exactly 2 intervals after the last sample, the moment the rule first allows it; the shim
reads the verdict file's mtime at 1 s resolution with a strict `age > 2 * interval`, so it asserts up to one
second later (`scenarios/tools/wakeshim.sh`). A port must reproduce the change-points; the reader's timing
is the shim's and is not in these fixtures.

The Rust wakefulness service must replay each fixture to EXACTLY `expected.jsonl`. `tests/test_golden.py`
is the Python side of the contract and runs in `run.sh --self-test`. Rebuild with `golden/build.py` only
when the frozen configuration changes, never to make a failing port pass.

## Per fixture

| File | Meaning |
|---|---|
| `trace.jsonl.gz` | The sampler's header, one `s` row per tick (1 s), footer. Rows: `procs` are `[pid, ppid, sid, pgrp, comm, exe, state, ticks, nice, wchan]`; `sockets` are `ss -tinp` rows; `net_rx`/`net_tx` cumulative bytes; `roots` the session leaders. |
| `pty.jsonl` | Pty events `{t, d: out|in, n}` (bytes), timestamped; a policy sees them bucketed into its ticks. |
| `lifecycle.jsonl` | Agent-owned exec-operation `start`/`end` events (F8; empty for most scenarios). |
| `truth.jsonl` | The labels. NOT an input to the policy; only the gates read it. |
| `meta.json` | Scenario, mode, compressed flag, the closed-loop config the run was recorded with. |
| `expected.jsonl` | The change-points `{t, verdict}`; the verdict holds until the next row; time before the first row is IDLE. |
| `gates.json` | What the gates said about `expected.jsonl` (all PASS). |

## The frozen configuration (`results/frozen.json`)

P4: CPU >= 0.05 core over the candidate set, OR pty output >= 200 B/s over a 5 s window, OR eth0 rx+tx
>= 500 B/s over a 3 s window, OR a candidate process blocked in `nanosleep`, OR a candidate-owned ESTAB
socket (any age), OR pty input within the last 10 s (grace); D-state counts as CPU. A BUSY vote holds the
verdict BUSY for a 30 s window. A sample older than 2 s is BUSY until fresh data (the READER applies this;
see `scenarios/tools/wakeshim.sh`). Compressed runs (4b, 7 in this set) use the compressed window (3 s) and
grace (1 s): `analyze.effective`.

Candidates (`analyze.tick_features`, as amended by amendment 2): every sampled process except zombies, the
session roots (their descendants still count), and:

* `EXCLUDED_WITH_DESCENDANTS` (`cron`, `unattended-upgr`, `apt.systemd.dai`, `wr-wakeshim`): the process
  and its descendants, whose work is its own housekeeping;
* `EXCLUDED_SELF_ONLY` (`systemd`, `sshd`, `wr-agent`, `boxd-automation`, `systemd-journal`,
  `systemd-logind`, `dbus-daemon`, `rsyslogd`): the process itself only, because it HOSTS user work;
* pid 1 and the driver (`header.driver_pid`), self only; the sampler and its forks.

Excluding a self-only host's descendants empties the candidate set on a real VM, where systemd is the
ancestor of everything, and a silent agent turn then reads IDLE: the boxd failure amendment 2 fixed. The
Rust port also keeps a session tree beneath an excluded daemon (a session started by an `@reboot` cron) as
candidates; no fixture contains that shape.

Time is `CLOCK_MONOTONIC` everywhere. A port that reads `/proc/uptime` fails on a derived machine.
