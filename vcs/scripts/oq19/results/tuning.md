# OQ19 tuning analysis

Scored tuning set (scale 1.0). Parameters are chosen here and frozen; the hold-out set (T6) carries the claim.

**Post-hoc amendment 1 applies** (see `gates.py` and `analyze.py` headers; the pre-registered outcome is `results/tuning-preregistered.md`): grace 10 s added to GRACE_GRID; net rate over NET_WINDOW_S = 3 s instead of per tick; PTY_WINDOW_S 10 -> 5 s; compressed runs scale grace by COMPRESSION; gates: every idle interval's opening BUSY run (within one interval of the open) gets the window as its tail; a run spanning the whole interval fails.

Analysis code at `0500d6f5`. Runs scored: 165 detached (full 105, compressed 60); attached 19; 500-process variant 3; serial controls 2; excluded 1.
* excluded `11-attached-full-r0`: check_trace failed (kept in the manifest; not scored)

## D3 (3b vs 4b)
The fallback FIRES over the agent-agnostic grid: no candidate had 4b false-idle = 0 AND 3b no-busy-forever, so 3b and 4b are treated as inseparable, both BUSY (never-idle wins), and 3b is exempt from no-busy-forever as an accepted cost (OQ7: an idle agent with a held connection keeps its box awake).

## The ladder: best config per policy (fewest failed runs, then least false-busy)
| policy | best config | failed runs / runs | failing gates | downsampled |
|---|---|---|---|---|
| P0 | `P0\|None\|None\|None\|agnostic\|None\|0.0\|None\|1\|True\|True\|True` | 130 / 165 | false_idle x75, no_busy_forever x55, provider_deadline x75, staleness x5, time_to_idle x35 | no |
| P1 | `P1\|None\|None\|None\|agnostic\|None\|0.0\|None\|5\|True\|True\|True` | 100 / 165 | false_idle x35, no_busy_forever x65, provider_deadline x35, staleness x5, time_to_idle x40 | yes |
| P1b | `P1b\|None\|None\|None\|agnostic\|None\|0.0\|None\|5\|True\|True\|True` | 70 / 165 | false_idle x5, no_busy_forever x65, provider_deadline x5, staleness x5, time_to_idle x40 | yes |
| P2 | `P2\|0.05\|None\|None\|agnostic\|None\|0.0\|None\|5\|True\|True\|True` | 80 / 165 | false_idle x80, provider_deadline x75, staleness x5 | yes |
| P3 | `P3\|0.05\|200.0\|500.0\|agnostic\|None\|0.0\|None\|5\|True\|True\|True` | 15 / 165 | false_idle x15, provider_deadline x10, staleness x5 | yes |
| P4 | `P4\|0.05\|200.0\|500.0\|agnostic\|None\|10.0\|0\|1\|True\|True\|True` | 0 / 165 | none | no |
| P5 | `P5\|0.05\|200.0\|500.0\|agnostic\|None\|10.0\|0\|1\|True\|True\|True` | 0 / 165 | none | no |

## Winner (pre-registered rule, `select_winner`)
`P4|0.05|200.0|500.0|agnostic|None|10.0|0|1|True|True|True`

* charged sampler cost (Python, upper bound): 0.82% idle, 2.83% at 500 processes, against the 0.5% gate: **PROVISIONAL** (a native sampler has to be re-measured; never used to exclude a config)
* mean false-busy fraction on idle scenarios: 0.0079; scenario 12 flaps/hour: 2.0 (reference 6, a reference line, not a gate)
* interval 1 s

| scenario | scale | runs | failed | worst time-to-busy (s) | worst time-to-idle (s) |
|---|---|---|---|---|---|
| 1 | full | 5 | 0 | - | 0.0 |
| 10 | full | 5 | 0 | 0.9 | 30.8 |
| 10 | compressed | 20 | 0 | 0.9 | 3.8 |
| 11 | full | 5 | 0 | 0.9 | 30.4 |
| 12 | full | 5 | 0 | - | 0.0 |
| 13 | full | 5 | 0 | - | 0.0 |
| 14 | full | 5 | 0 | 0.9 | 36.4 |
| 16 | full | 5 | 0 | - | 0.0 |
| 17 | full | 5 | 0 | - | 0.0 |
| 18 | full | 5 | 0 | 0.0 | 30.8 |
| 2a | full | 5 | 0 | - | 0.0 |
| 2b | full | 5 | 0 | - | 0.0 |
| 2c | full | 5 | 0 | - | 0.0 |
| 3a | full | 5 | 0 | - | 0.0 |
| 3b | full | 5 | 0 | - | 0.0 |
| 4a | full | 5 | 0 | 1.0 | 32.6 |
| 4b | full | 5 | 0 | 0.9 | 32.1 |
| 4b | compressed | 20 | 0 | 1.0 | 5.7 |
| 5 | full | 5 | 0 | 0.7 | 30.7 |
| 6 | full | 5 | 0 | 0.9 | 29.6 |
| 7 | full | 5 | 0 | 0.9 | 30.3 |
| 7 | compressed | 20 | 0 | 0.8 | 3.8 |
| 8 | full | 5 | 0 | - | 0.0 |
| 9 | full | 5 | 0 | 0.7 | 33.3 |

Per-group table (`gates.final_claim`; the tuning set never carries the claim, and its bounds are for the record): 0 failures in N runs only bounds the miss rate at the 95% upper bound shown.

| set / scale / mode | runs | runs that can false-idle | failing runs | 95% bound, false-idle | critical scenarios (4b, 7, 10): runs / 95% bound |
|---|---|---|---|---|---|
| tuning / compressed / detached | 60 | 60 | 0 | 0.05 | 60 / 0.05 |
| tuning / full / detached | 90 | 50 | 0 | 0.06 | 15 / 0.18 |

### What an idle box costs (the OQ7 input): BUSY verdict time on the idle-only scenarios, winner config
A BUSY fraction near 0.13 on a 300 s idle run is the launch tail (keystroke grace + paint + window, ~40 s), paid once when the TUI opens, not a steady state; the hours column extrapolates it and overstates.

| scenario | runs | mean BUSY fraction | awake hours per day if left like this |
|---|---|---|---|
| 1 | 5 | 0.000 | 0.0 |
| 2a | 5 | 0.128 | 3.1 |
| 2b | 5 | 0.128 | 3.1 |
| 2c | 5 | 0.128 | 3.1 |
| 3a | 5 | 0.125 | 3.0 |
| 3b | 5 | 1.000 | 24.0 |
| 8 | 5 | 0.130 | 3.1 |
| 16 | 5 | 0.000 | 0.0 |

### Serial control (D7)
* `4b-detached-comp-r0` vs `4b-detached-comp-r0-serial`: 0.2% of seconds differ: **match**
* `5-detached-full-r0` vs `5-detached-full-r0-serial`: 0.0% of seconds differ: **match**

### Scenario 17 and the awake ceiling (OQ22: reported, never gated)
* `17-detached-full-r0`: longest continuous BUSY 5400 s; ceiling 1800 s -> force-sleep kills the job; ceiling 3600 s -> force-sleep kills the job; ceiling 14400 s -> force-sleep ok
* `17-detached-full-r3`: longest continuous BUSY 5400 s; ceiling 1800 s -> force-sleep kills the job; ceiling 3600 s -> force-sleep kills the job; ceiling 14400 s -> force-sleep ok
* `17-detached-full-r1`: longest continuous BUSY 5399 s; ceiling 1800 s -> force-sleep kills the job; ceiling 3600 s -> force-sleep kills the job; ceiling 14400 s -> force-sleep ok
* `17-detached-full-r2`: longest continuous BUSY 5399 s; ceiling 1800 s -> force-sleep kills the job; ceiling 3600 s -> force-sleep kills the job; ceiling 14400 s -> force-sleep ok
* `17-detached-full-r4`: longest continuous BUSY 5400 s; ceiling 1800 s -> force-sleep kills the job; ceiling 3600 s -> force-sleep kills the job; ceiling 14400 s -> force-sleep ok

### Attached vs detached (scenario 15: reported, never scored)
PREDICTION, written before any attached trace was analysed: the harness's fake client resizes the window every 30 s, which redraws a full-screen TUI (several KB of pty output). That lands in the pty-rate window (10 s when this was written, 5 s after amendment 1) for part of the time, above both grid values, so attached 2a/2c/3a will look false-busy. That is the harness's client, not a policy defect, and it does not enter the claim.
* `4b-attached-full-r0`: all gates pass
* `7-attached-full-r0`: all gates pass
* `6-attached-full-r0`: all gates pass
* `9-attached-full-r0`: all gates pass
* `4a-attached-full-r0`: all gates pass
* `5-attached-full-r0`: all gates pass
* `14-attached-full-r0`: FAILS no_busy_forever, time_to_idle
* `16-attached-full-r0`: all gates pass
* `10-attached-full-r0`: all gates pass
* `1-attached-full-r0`: all gates pass
* `2a-attached-full-r0`: FAILS no_busy_forever
* `2b-attached-full-r0`: all gates pass
* `2c-attached-full-r0`: all gates pass
* `3a-attached-full-r0`: all gates pass
* `3b-attached-full-r0`: all gates pass
* `8-attached-full-r0`: all gates pass
* `18-attached-full-r0`: all gates pass

## Conditional alternative (tty-aware wait rule; requires an agent that blocks in a tty read)
16 passing tty-aware config(s). Not selectable until a real agent trace confirms the wait class.

## 500-process build (sampler starvation)
* `5-detached-full-500proc-r0`: 835 samples, longest silence 7.9 s; sampler cost 1.13% of a core (steady)
* `5-detached-full-500proc-r1`: 786 samples, longest silence 14.3 s; sampler cost 0.87% of a core (steady)
* `5-detached-full-500proc-r2`: 851 samples, longest silence 9.0 s; sampler cost 0.97% of a core (steady)
