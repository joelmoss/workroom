# OQ19 — can the agent tell BUSY from IDLE? Measurements

**Answer (signal half): yes, on the hold-out, with one accepted cost and one open question.** A
policy exists (P4 below, numeric parameters frozen in `vcs/scripts/oq19/results/frozen.json`) that
made zero false-idle and zero busy-forever errors on 150 fresh closed-loop runs it was not tuned on,
with the classifier's own activity in the box. The accepted cost is that an idle agent holding a
keepalive connection stays BUSY (D3). The open question is the awake ceiling, split out as OQ22.
The boxd confirmation run (T7) is scripted and not yet run: see "What is not measured".

Plan: `~/.claude/plans/polished-cooking-feather.md` (approved after `/plan-eng-review`,
2026-09-19). Harness: `vcs/scripts/oq19/` (its README is the operator's guide). Issue: #208.

## The claim, and what it rests on

| Set | Runs | Can false-idle | Failing | 95% upper bound on the miss rate |
|---|---|---|---|---|
| hold-out, full length, detached | 90 | 50 | 0 | 0.06 |
| hold-out, compressed, detached | 60 | 60 | 0 | 0.05 |

All 150 hold-out runs were **closed loop**: the real classifier (`live.py`, the same `tick_features`
and `vote` code the replay uses) and the real shim ran in the box at 1 s, and the verdicts scored are
the ones the shim asserted. The live verdicts matched a replay of each run's own trace on every run
(0.0% mismatch), and the classifier never fell back on a missed counter read (0 of 150). The tuning
set (190 runs) was recorded first, analysed, amended against (below) and never carries the claim.

The numbers are what the plan's D5 sample size can say: with zero failures in 50 runs the miss rate is
bounded at 6% per run, not proven zero. Compressed and full-length are reported separately (F6).

## The pre-registered outcome was NO WINNER, and the amendment is disclosed

Labels, gates and the counting boundary were committed and independently reviewed before any trace
existed (tag `oq19-preregistration-frozen`). Under that contract **no configuration passed every gate**
(`results/tuning-preregistered.md`, commit a8246fb3). Every residual failure traced to a fault in the
registration, not to the signal missing work:

1. The gate excused a hysteresis tail only after a BUSY phase, so a pure-idle label had a 10 s budget
   for its opening BUSY run while every window in the grid is >= 30 s. vim painting its screen at
   launch (2.2 KB) and the box's ~800 B startup network burst each failed a whole run.
2. The grace grid (0, 30 s) bracketed the passing range for keystrokes into an idle TUI: 0 never sees
   a keystroke's echo, 30 stacks on the window past the time-to-idle allowance. About 10 s passes.
3. Per-tick network bytes at 1 s let a single startup burst vote BUSY, while a 2 s request cadence
   (scenario 9) needs the signal; a rate over a short window separates them.
4. Whether a launch keystroke landed before or after a label boundary decided the gate at 2 s
   cadence and not at 1 s (tick phase, not behaviour).

The owner chose a disclosed post-hoc amendment (tag `oq19-amendment-1`, headers of `gates.py` and
`analyze.py` carry the rationale): every idle interval's opening BUSY run is excused up to the window
+ 10 s, provided it begins within one sampling interval of the open, and a BUSY run spanning the whole
interval fails regardless (the headline "idle TUI busy forever" failure cannot pass); grace 10 s joined
the grid; net is a 3 s windowed rate; the pty window went from 10 to 5 s; compressed runs scale the
grace like the window. **Labels and the counting boundary are untouched.** The hold-out was recorded
after the amendment and is what the claim rests on. Whether the amendment was reasonable is for the
second independent review (T9).

## The chosen policy: P4

`P4|cpu 0.05|pty 200 B/s|net 500 B/s|agnostic wait|no socket-age rule|grace 10 s|window 30 s|1 s`

A tick votes BUSY when any of these holds over the candidate set (every sampled process minus the
production exclusion list in `boundary.md` and the classifier's own pid tree):

- CPU >= 0.05 core in the last second, or a process in D state;
- pty output >= 200 B/s over the last 5 s;
- eth0 rx+tx >= 500 B/s over the last 3 s;
- a candidate blocked in `nanosleep` (a `sleep 900 && ...` job is work);
- a candidate owns an ESTAB TCP socket, of any age (this is what makes 4b pass and 3b the accepted cost);
- pty input within the last 10 s.

A BUSY vote holds the verdict BUSY for 30 s. A verdict older than 2 s is BUSY until a fresh one
arrives, and **that rule belongs to the reader** (the shim), not the classifier: a stopped classifier
cannot say anything. P5 (P4 plus the agent's own exec-operation lifecycle) tied on every gate; the
pre-registered rule prefers the earlier policy at a tie, so the lifecycle signal is available and
unneeded on this set. The ladder, best configuration per policy on the tuning set:

| Policy | Failing runs / 165 | What still fails |
|---|---|---|
| P0 foreground pgid (the design doc's baseline) | 130 | false-idle on every background job; busy forever on idle TUIs |
| P1 tree liveness | 100 | busy forever (an idle shell is alive); misses `setsid` |
| P1b cgroup liveness | 70 | busy forever |
| P2 + CPU delta | 80 | false-idle on every quiet wait |
| P3 + pty, net, timer, socket rules | 15 | onset and deadline on the silent waits |
| P4 + hysteresis, grace, staleness | 0 | — |
| P5 + exec lifecycle | 0 | — |

Winner metrics on the tuning set: false-busy 0.79% of idle time (excluding excused tails), scenario 12
flaps 2.0/h (reference line 6), worst time-to-busy 1.0 s, worst time-to-idle 36.4 s (window + the
grace) for keystrokes and 30 to 33 s elsewhere. Serial controls (D7) matched their parallel twins on
0.0% and 0.2% of seconds.

## D3: 3b and 4b are inseparable under any agent-agnostic rule, and the fallback fired as predicted

A silent 15-minute agent turn (4b: an open connection, no bytes, no CPU) and an idle agent holding a
keepalive connection (3b) present the same signals. The pre-registered fallback applies: both are BUSY,
3b is exempt from the busy-forever gate, and the cost is stated: **an idle agent with a held connection
keeps its box awake, 24 h/day.** A tty-aware wait rule (the socket counts only if its owner is not
blocked in a tty read) separates them on the synthetic agent, and 16 such configurations pass every
gate, but the real agent is an event loop and may never block in a tty read, so that rule stays a
conditional alternative until a real Claude Code trace exists (TODOS).

## What an idle box costs (the OQ7 input)

BUSY fraction on the idle-only scenarios, winner configuration, tuning set: bash prompt 0.000; idle
vim, less, tmux-with-clock, agent prompt and a listening server 0.125 to 0.130; the noisy box with
daemons 0.000; 3b 1.000. **The 0.13 is the 38 s launch tail (keystroke grace 10 s + paint + 30 s window)
over a 300 s labelled run, not a steady state**: an idle TUI left open costs about 40 s of awake time
once, then nothing. The table's "awake hours per day" column extrapolates that tail and overstates.

## Findings the run produced, beyond the gates

- **`nice -5` does not protect the sampler from a `--cpus` CFS quota.** Under the 500-process build the
  sampler went silent for 7.9 to 14.3 s per run (throttled with everything else); the staleness rule
  covers it, and `cg_throttled_usec` is now recorded.
- **The classifier's inputs must not cross a Docker Desktop bind mount.** `os.replace` there is not
  atomic for a reader (219 `FileNotFoundError` in 15 s of polling; 0 on the container's own `/run`).
  The first hold-out attempt read `{}` once, put a 0 into the pty history and voted BUSY 5 s later.
  The agent must hand its counters to the classifier in memory or on a local filesystem.
- **The staleness rule is the consumer's.** In the closed loop the classifier is the process that gets
  stopped, so its last verdict (IDLE) stood for a 15 s gap and the work that started inside it. The
  shim now treats a verdict older than 2 intervals as BUSY; the scorer scores the log the same way.
  Scenario 18's five hold-out runs were re-recorded under that shim (harness 5a15d432; the other 145
  are from d6ea0e39).
- **Attached mode is only a resize.** The harness's client resizes the window every 30 s; a full-screen
  TUI repaints and bash repaints its prompt. Predicted before analysis: attached 2a and 14 fail the
  busy-forever gate and `11-attached` failed its own check. Reported, never scored (scenario 15).
- **Sampler cost.** The Python sampler + classifier + shim cost a median 1.03% and worst 1.48% of a
  core in the closed loop, against the plan's 0.5% gate; 0.62% at best. It is an upper bound and was
  never used to exclude a configuration. Measured components: box-level reads 0.17%, the per-process
  walk 2.5% at 500 processes, one `ss` fork about 0.75% per Hz. The Rust port has to be re-measured
  against the gate; the signal set the winner needs (box + procs + sockets at 1 s) is the expensive one.

## OQ22: the awake ceiling (reported, not decided)

Scenario 17 ran legitimate work for 5400 s five times. With a force-sleep ceiling of 1800 s or 3600 s
the job is killed every time; at 14400 s it completes. The measurement cannot choose between
force-sleep, advisory-only and ask-the-user, and a false-busy state has no natural ceiling other than
this one (3b is the case). The owner decides; OQ22 blocks the wakefulness service.

## What is not measured

- **A real Claude Code trace.** The agent here is synthetic (`scenarios/tools/agent.py`: alt screen,
  process title rewrite, blocks in a tty read at its prompt, spinner or silence mid-turn, keepalive).
  The tty-aware rule and the lifecycle signal (P5) both wait on a real trace (TODOS).
- **The target machine.** Every scored run is a Docker container on a Mac. The boxd confirmation run
  (`boxd/boxd.sh`: a treatment machine with the frozen policy driving the item-5 shim through the in-VM
  CLI, a control that must hibernate mid-wait, a fork with a clock check; `analyze.py boxd` scores it)
  is written and tested on synthetic logs, and has not been run: creating cloud machines is a
  real-world transaction the authoring session could not make. Until it runs, the provider half of
  the claim rests on Phase 0 item 5 (the lever works) plus this document (the decision works).
- **P0 was reconstructed**, not recorded: `tcgetpgrp` was not sampled, so the baseline is bash blocked
  in `do_wait`, which holds exactly while a foreground job has the terminal.
- **The peer sidecar is container-only.** On boxd the peer is a fourth machine.

## For the Rust port

`vcs/scripts/oq19/golden/`: ten hold-out runs with inputs and expected change-points; `tests/test_golden.py`
is the contract. `boundary.md` is the counting boundary. `scenarios/tools/wakeshim.sh` is the shim
shape, including the reader-side staleness rule and the once-per-transition assert/release hooks.
