# OQ19 — can the agent tell BUSY from IDLE? Measurements

**Answer (signal half): yes, on the hold-out and on the provider, with one accepted cost and one
open question.** A policy exists (P4 below, numeric parameters frozen in
`vcs/scripts/oq19/results/frozen.json`) that made zero false-idle and zero busy-forever errors on 150
fresh closed-loop runs it was not tuned on, with the classifier's own activity in the box. On boxd
(2026-09-21, `results/boxd.md`, PASS) the same policy driving the item-5 lever kept a machine awake
through a 15-minute silent agent turn while an unprotected control was hibernated 167 s into the same
wait, and put the machine to sleep within 3 minutes of every IDLE stretch except the keepalive one: nine
sleeps on the treatment, one on its fork. The accepted cost is that an idle agent holding a keepalive
connection stays BUSY (D3; scenario 3b is exempt from the busy-forever gate everywhere below). The open
question is the awake ceiling, split out as OQ22. One gate does not have a clean hold-out: the staleness
gate (scenario 18), see "The claim".

Independent review (T9, 2026-09-21): seven findings, all fixed in this revision; the answer stood
"directionally" before them and stands as written after them. The reviewer's list is in the commit
message that closed it.

Plan: `~/.claude/plans/polished-cooking-feather.md` (approved after `/plan-eng-review`,
2026-09-19). Harness: `vcs/scripts/oq19/` (its README is the operator's guide). Issue: #208.

## The claim, and what it rests on

| Set | Runs | Can false-idle | Failing | 95% bound, false-idle | 95% bound, any gate | Critical (4b, 7, 10): runs / 95% bound |
|---|---|---|---|---|---|---|
| hold-out, full length, detached | 90 | 50 | 0 | 0.06 | 0.03 | 15 / 0.18 |
| hold-out, compressed, detached | 60 | 60 | 0 | 0.05 | 0.05 | 60 / 0.05 |

All 150 hold-out runs were **closed loop**: the real classifier (`live.py`, the same `tick_features`
and `vote` code the replay uses) and the real shim ran in the box at 1 s. What is scored is the
classifier's verdict log as the shim reads it (the shim's own assert/release transitions are logged
only on boxd, not in the container; the container shim's staleness reading is applied by the scorer,
and it changed none of the 145 runs it was not recorded with). The live verdicts matched a replay of
each run's own trace on every run (0.0% mismatch), and the classifier never fell back on a missed
counter read (0 of 150). The tuning set (190 runs) was recorded first, analysed, amended against
(below) and never carries the claim.

The numbers are what the plan's D5 sample size can say: with zero failures in 50 runs the miss rate is
bounded at 6% per run, not proven zero, and **the hardest full-length cases (4b, 7, 10) are only 15 runs,
bounded at 18%**; the compressed repeats of the same three bound them at 5%. Compressed and full-length
are reported separately (F6).

**The staleness gate (scenario 18) is tuned, not held out.** Its five hold-out runs failed at first
(144 of 150 done): the classifier is the process that gets stopped, so the rule had to move to the
reader. The shim and the scorer were changed and only those five runs were re-recorded (harness
5a15d432; the other 145 are from d6ea0e39). A hold-out re-recorded after seeing its own failure, with a
semantics change in between, is a second tuning set for that one gate. The other five gates' hold-out
status is unaffected (the reader-side fill changes no verdict on the other 145 runs).

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
gate under the amended contract (none did under the pre-registered one: the alternative exists only
because of amendment 1), but the real agent is an event loop and may never block in a tty read, so that
rule stays a conditional alternative until a real Claude Code trace exists (TODOS).

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
  are from d6ea0e39), which is why that gate counts as tuned, not held out. The shim compares integer
  wall seconds with a strict `>` while the scorer fills BUSY at exactly 2.0 s after the last verdict, so
  the scored series can be up to a second more optimistic than what the shim asserted; scenario 18's
  work starts 5 s into its gap, inside the allowance either way, and the divergence is not measured.
- **Attached mode is only a resize.** The harness's client resizes the window every 30 s; a full-screen
  TUI repaints and bash repaints its prompt. Predicted before analysis: attached 2a and 14 fail the
  busy-forever gate and `11-attached` failed its own check. Reported, never scored (scenario 15).
- **Sampler cost.** The Python sampler + classifier + shim cost a median 1.03% and worst 1.48% of a
  core in the closed loop, against the plan's 0.5% gate. It is an upper bound and was
  never used to exclude a configuration. Measured components: box-level reads 0.17%, the per-process
  walk 2.5% at 500 processes, one `ss` fork about 0.75% per Hz. The Rust port has to be re-measured
  against the gate; the signal set the winner needs (box + procs + sockets at 1 s) is the expensive one.

## The boxd confirmation run (T7) — PASS, on the fifth attempt, and the four failures are the findings

`vcs/scripts/oq19/boxd/boxd.sh` (harness 7ac2136d, 2026-09-21 00:45 to 01:12): four machines with
120 s auto-suspend and auto-hibernate timers. `oq19-treatment` ran the frozen policy live, the shim
translating BUSY/IDLE into the in-VM CLI setting the machine's own timers to 0 and back (item 5's lever),
through 4b, 3a, 3b, 5 and 16; `oq19-control` ran 4b with no policy; `oq19-fork` was forked from the
treatment afterwards for a clock check and an idle run; `oq19-peer` served the network scenarios. Every
machine was destroyed by the script's exit trap; `boxd machine list` was empty afterwards.

| Check | Result |
|---|---|
| treatment never slept inside a BUSY label | yes: awake through 4b's 900 s silent wait and 5's build |
| treatment's live gates | all pass on all five scenarios; live verdicts equal a replay of each trace (0.0%) |
| control slept mid-wait (D11) | yes: hibernated 167 s into the silent turn (283 s into the run), for 4120 s |
| treatment slept within the idle window after IDLE | yes: the first sleep in each idle stretch came 146 to 157 s after the label opened (IDLE verdict ~35 s, release, then the provider's 120 s timer); 9 sleeps of 79 to 97 s in all |
| fork's `CLOCK_MONOTONIC` | 0.9991 s/s against wall over 60 s; `/proc/uptime` 0.9999 s/s |
| fork slept after IDLE | yes: 235 s after scenario 1's label opened, for 424 s. The scorer's deadline is the window plus two provider timer periods (270 s): the provider re-arms its idle timer at its own cadence after the shim restores it, and a first draft with one period plus 60 s missed this sleep by 22 s |

Two provider facts the container could not show. **A hibernate is visible to the VM's clocks on boxd**:
monotonic and uptime both advanced by the full wall gap on every sleep, so a phase timed in monotonic
ends on wall time even if the box slept through it, and the design doc's "`/proc/uptime` lies on a
derived machine" did not reproduce on a fork here. **Every wake is a 30 s BUSY blip**: the box comes
back with 0.2 to 0.4 core of system CPU and ~1.5 KB/s of provider traffic for a few seconds, the policy
votes BUSY once, and the window holds it 30 s before the box goes back to sleep 2.5 min later. The scorer
excuses a BUSY run that begins within one net window of a wake and lasts no longer than the window's
allowance, and reports each one (30 to 31 s, six of them); the agent should mask its own resume the
way it masks its own provider call.

The four failed attempts each removed a harness artefact that a container hides, and each is an
attribution rule the production service needs (amendment 2, `boundary.md`):

1. **Exclusion reach.** On a systemd box pid 1 is the ancestor of everything; the first implementation
   excluded a matched name's descendants and the candidate set was empty. Hosts of user work (init,
   `sshd`, the agent) exclude only themselves; housekeeping daemons (cron, apt, the shim) keep excluding
   their children. The hold-out re-scored identically.
2. **The lever's own traffic.** Restoring the idle timer is an HTTPS call on `eth0`; the classifier
   re-voted BUSY within a second of every release and the timers flapped every 34 s. The shim marks each
   call and the classifier masks the net signal from the call until one net window after it.
3. **The harness's own loops.** A tick logger's `sleep 10` and the driver's own `time.sleep` are
   nanosleep waits, BUSY under the timer rule once they count. The sampler stamps wall time itself and
   the driver is excluded by pid.
4. **Survivors of a closed pty.** Three synthetic agents outlived their sessions, spinning at a core each
   on an empty read, one still holding its keepalive socket. The driver now kills its session's
   survivors, the way `terminationTargets` walks the tree.

Not root on the VM: the sampler ran without `nice -5` (its cost there: 0.63 to 0.75% of a core, no
throttling), and the container check's phase-duration tolerance flags the wake latency (4b's post phase
ran 687 s for 640 labelled) because monotonic keeps counting while the box sleeps.

## OQ22: the awake ceiling (reported, not decided)

Scenario 17 ran legitimate work for 5400 s five times. With a force-sleep ceiling of 1800 s or 3600 s
the job is killed every time; at 14400 s it completes. The measurement cannot choose between
force-sleep, advisory-only and ask-the-user, and a false-busy state has no natural ceiling other than
this one (3b is the case). The owner decides; OQ22 blocks the wakefulness service.

## What is not measured

- **A real Claude Code trace.** The agent here is synthetic (`scenarios/tools/agent.py`: alt screen,
  process title rewrite, blocks in a tty read at its prompt, spinner or silence mid-turn, keepalive).
  The tty-aware rule and the lifecycle signal (P5) both wait on a real trace (TODOS).
- **The claim's sample sizes are the container's.** The boxd run is one machine per role and five
  scenarios, a confirmation that the policy and the lever work together on the provider, not a second
  hold-out. Scenario 5 and 3a/3b/16 ran once each there; 4b once on each machine.
- **The wake blip is excused by the scorer, not handled by the classifier.** Six 30 s BUSY blips
  after wakes were excused and reported; a production service should mask its own resume.
- **P0 was reconstructed**, not recorded: `tcgetpgrp` was not sampled, so the baseline is bash blocked
  in `do_wait`, which holds exactly while a foreground job has the terminal.
- **The peer sidecar is container-only.** On boxd the peer is a fourth machine.

## For the Rust port

`vcs/scripts/oq19/golden/`: ten hold-out runs with inputs and expected change-points; `tests/test_golden.py`
is the contract. `boundary.md` is the counting boundary. `scenarios/tools/wakeshim.sh` is the shim
shape, including the reader-side staleness rule and the once-per-transition assert/release hooks.
