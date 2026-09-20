# OQ19 measurement harness

Answers OQ19 (`docs/designs/remote-workrooms.md`): can the agent tell busy from idle well enough to let a
provider sleep a box without killing real work? The approved plan is the source of truth for what is
measured and why; this directory is the harness.

## The contract is frozen

`labels.py`, `gates.py` and `boundary.md` were pre-registered, independently reviewed and tagged
`oq19-preregistration-frozen` (sha256 of each is in the tag message). Do not edit `labels.py` or `gates.py`
once any trace has been recorded: a gate the results embarrass is a finding, not a bug to fix.

**Amendment 1 (2026-09-20, owner-approved, post hoc).** The pre-registered tuning outcome was NO WINNER
(`results/tuning-preregistered.md`). Every residual failure traced to a registration fault, not to the
signal, so the owner chose a disclosed amendment: `gates.py` (an idle interval's opening BUSY run, one that
begins within a sampling interval of the open, is excused up to the window + 10 s, and a run spanning the
whole interval fails regardless) and the `analyze.py` grid (grace 10 s; net as a 3 s windowed rate; pty
window 10 -> 5 s; compressed runs scale the grace like the window). Labels are untouched. The amended
contract is tag `oq19-amendment-1`, which `record.py` now checks; the hold-out set was recorded after the
amendment and is what the claim rests on. Both headers carry the full rationale. Results:
`results/holdout.md` (the claim), `results/tuning.md`, `results/tuning-preregistered.md`, and the write-up in
`docs/designs/oq19-wakefulness-measurements.md`.

## Layout

| File | Role |
|---|---|
| `labels.py` | Ground truth: scenarios, phases, BUSY/IDLE labels, durations (full and compressed). |
| `gates.py` | Acceptance gates and metrics, pure functions of a verdict series and a truth timeline. |
| `boundary.md` | What counts as work in production, the exclusion list, permissions per signal. |
| `procfs.py` | Parsers for the Linux signals; tested against real captured output. |
| `sampler.py` | Reads the signals on a fixed cadence into `trace.jsonl`; reports its own CPU cost. |
| `driver.py` | Runs one scenario in a pty session, writes the truth log from what it actually did. |
| `run.sh` | Runs the harness in a container (`container`, `docker` or `podman`); `--self-test`, `scenario`, `smoke`, `controls`, `cost`. |
| `scenarios/` | One action module per scenario (`s_<id>.py`), `lib.py`, and `tools/` (`agent.py` the synthetic agent TUI, `peer.py` the network peer, `burn.py`, `burst.py`). |
| `check_trace.py` | Proves a recorded run did what its label claims, from the sampler's trace rather than the driver's intent. |
| `live.py` | The classifier ONLINE (sampler + chosen policy in one process): the closed loop of F7. Uses `analyze.tick_features` and `analyze.vote`, the code the replay was scored with. |
| `scenarios/tools/wakeshim.sh` | The item-5-shaped lifecycle shim, run as `wr-wakeshim` (on the exclusion list); its CPU is measured. It owns the staleness rule (D10): a verdict file older than 2 intervals is BUSY, because a stopped classifier cannot say so itself (found by scenario 18's hold-out runs). `analyze.live_verdicts` scores the live log the same way. |
| `record.py` | Records the whole tuning set (or a hold-out) a few containers at a time from a snapshot of the committed harness; resumable, never discards a failed run. |
| `analyze.py` | Replays recorded runs through policies P0 to P5 with the pre-registered gates; the candidate grid and the winner-selection rule are fixed in the file before any tuning trace existed. `--pipeline-check` for scaled runs. |
| `cost_matrix.json` | The measured sampler cost per signal set, interval and load (from `run.sh cost`), so the analysis charges each policy what its signals cost. |
| `cost.py` | Sampler cost per signal group, interval and process load (`run.sh cost`). |
| `Dockerfile` | The measurement image. `setup.sh` (boxd) installs the same package list. |
| `setup.sh`, `boxd/` | T7, the boxd confirmation run: `boxd/boxd.sh` creates `oq19-peer`, `oq19-treatment` (the frozen policy driving the shim through the in-VM CLI), `oq19-control` (no policy; must hibernate mid-wait) and `oq19-fork`, runs 4b/3a/3b/5/16 detached (`boxd/runall.sh`, `OQ19_PROCS=all`: the whole box minus the exclusion list), logs ticks and control-plane status, collects, destroys everything in an EXIT trap. `analyze.py boxd` scores it (`results/boxd.md`). |
| `pipeline-check.md` | What the pipeline check found in the image, and what it corrected. |
| `tests/` | Self-checks; real fixtures in `tests/fixtures/`. Run by file name, never `unittest discover`. |

## Running

```
vcs/scripts/oq19/run.sh --self-test                      # gates, labels and parsers, no container needed
vcs/scripts/oq19/run.sh scenario 1 --scale 0.1           # a pipeline check: 10% of the phase durations
vcs/scripts/oq19/run.sh smoke [ids...]                   # every scenario at a small scale, then check_trace.py
vcs/scripts/oq19/run.sh controls                         # negative controls: a wrong-scenario check must FAIL
vcs/scripts/oq19/run.sh cost                             # the sampler cost matrix
vcs/scripts/oq19/record.py tuning --dry-run              # the job list and the wall-time estimate
vcs/scripts/oq19/analyze.py tuning                       # replay + gates over traces/tuning (needs scale 1.0 runs)
# after the tuning analysis: freeze, COMMIT results/frozen.json, then record and score the hold-out
vcs/scripts/oq19/analyze.py tuning --freeze              # writes results/frozen.json from the pre-registered rule
vcs/scripts/oq19/record.py holdout                       # refuses unless frozen.json is committed and unmodified
vcs/scripts/oq19/analyze.py holdout                      # the final claim: PASS/FAIL from the hold-out alone
# closed loop (F7): the real classifier and shim in the box, at the real cadence
vcs/scripts/oq19/run.sh scenario 16 --closed-loop '{"config": {<analyze.Config fields>}, "window_s": 30}' --out DIR
vcs/scripts/oq19/analyze.py closed-loop --run DIR        # live verdicts vs the gates, vs a replay, and the cost
# T7, boxd (creates cloud machines; ~1.7 h; the boxd CLI must be signed in)
caffeinate -i vcs/scripts/oq19/boxd/boxd.sh              # treatment + control + fork, cleanup in a trap
vcs/scripts/oq19/analyze.py boxd                         # results/boxd.md: PASS iff the treatment stayed awake through BUSY, the control did not, both slept after IDLE, the fork's clock is sane
```

`--scale` is for pipeline checks only and is recorded in `meta.json`; a scored run always uses scale 1.0.
Raw traces go to `traces/` (gitignored). Each run gets its own container with `--cpus=1 --memory=512m
--cap-add=SYS_NICE`; the capability is required for `nice -n -5` (see `pipeline-check.md`).

## Rules that keep the numbers honest

* Time is `CLOCK_MONOTONIC` everywhere, never `/proc/uptime`.
* The driver never reads a signal and the sampler never reads a label.
* A BUSY phase without an action module refuses to run: an unimplemented scenario must never be recorded as
  if it had done its work.
* A scenario is not trusted until `check_trace.py` says it did what its label claims, and that check is not
  trusted until `run.sh controls` shows it fails on the wrong scenario.
* Scenarios that need a network peer (3b, 4a, 4b, 9) get it as a SEPARATE container on a private network, so
  its traffic crosses the box's `eth0` as a provider's network-idle timer would see it (loopback is invisible).
* A missed sample is a gap, scored by the staleness rule (D10), never filtered out.
