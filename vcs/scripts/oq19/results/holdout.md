# OQ19 hold-out result

Scored hold-out set (scale 1.0, closed loop).

Frozen configuration `P4|0.05|200.0|500.0|agnostic|None|10.0|0|1|True|True|True` (tuning commit `0edbc2e9`, D3 fallback applied).

Harness commit per run: `5a15d432` x5, `d6ea0e39` x145 (more than one: a run re-recorded under a later harness is disclosed in the results doc).

## Claim: **PASS**

PASS requires zero failures on all gates in the hold-out set, detached, at BOTH scales, and the pre-registered sample size (every gated scenario x5 full-length, every critical scenario x20 compressed).

| set / scale / mode | runs | can false-idle | failing | 95% bound false-idle | sample size ok |
|---|---|---|---|---|---|
| holdout / compressed / detached | 60 | 60 | 0 | 0.05 | True |
| holdout / full / detached | 90 | 50 | 0 | 0.06 | True |

## Failing runs (0)

## Classifier + sampler + shim cost (Python, an upper bound: PROVISIONAL)
median 1.03%, worst 1.48% of one core, against the 0.5% gate; 0 of 150 runs at or under it.
