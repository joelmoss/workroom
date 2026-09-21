# OQ19 boxd confirmation run

Harness commit `7ac2136d`; frozen configuration `P4|0.05|200.0|500.0|agnostic|None|10.0|0|1|True|True|True`; provider timers 120 s.

## Verdict: **PASS**

* treatment_never_slept_in_busy: yes
* treatment_live_gates_pass: yes
* control_slept_in_busy: yes
* control_slept_during_run: yes
* treatment_slept_after_idle: yes
* fork_monotonic_at_wall_rate: yes
* fork_slept_after_idle: yes

## oq19-treatment
sleep events (a wall gap over 3 sampling intervals inside a run): 9
* asleep 92 s (VM monotonic advanced 92 s, uptime 92 s) starting at wall 1789947975
* asleep 92 s (VM monotonic advanced 92 s, uptime 92 s) starting at wall 1789948217
* asleep 79 s (VM monotonic advanced 79 s, uptime 79 s) starting at wall 1789946229
* asleep 81 s (VM monotonic advanced 81 s, uptime 81 s) starting at wall 1789945530
* asleep 92 s (VM monotonic advanced 92 s, uptime 92 s) starting at wall 1789945731
* asleep 92 s (VM monotonic advanced 92 s, uptime 92 s) starting at wall 1789945973
* asleep 97 s (VM monotonic advanced 97 s, uptime 97 s) starting at wall 1789947242
* asleep 92 s (VM monotonic advanced 92 s, uptime 92 s) starting at wall 1789947490
* asleep 91 s (VM monotonic advanced 91 s, uptime 91 s) starting at wall 1789947733

| scenario | BUSY phases (wall) | slept inside BUSY / IDLE | live gates | wake tails excused (s) | live vs replay |
|---|---|---|---|---|---|
| 16 | none | 0 / 2 | all pass | 30, 31 | 0.0% |
| 3a | none | 0 / 1 | all pass | 30 | 0.0% |
| 3b | none | 0 / 0 | all pass | - | 0.0% |
| 4b | turn 1789944478-1789945378 | 0 / 3 | all pass | 30 | 0.0% |
| 5 | build 1789946793-1789947093 | 0 / 2 | all pass | 31, 31 | 0.0% |

seconds from an IDLE label's start to a sleep inside it: 146, 388, 157, 152, 353, 595, 149, 397 (deadline 270 s)
first asleep status after the last IDLE label: hibernated
 at wall 1789948473 (deadline wall 1789948699)

## oq19-control
sleep events (a wall gap over 3 sampling intervals inside a run): 1
* asleep 4120 s (VM monotonic advanced 4120 s, uptime 4120 s) starting at wall 1789944645

| scenario | BUSY phases (wall) | slept inside BUSY / IDLE | live gates | wake tails excused (s) | live vs replay |
|---|---|---|---|---|---|
| 4b | turn 1789944478-1789948765 | 1 / 0 | open loop | - | - |

seconds from an IDLE label's start to a sleep inside it: none (deadline 270 s)
first asleep status after the last IDLE label: hibernated
 at wall 1789948913 (deadline wall 1789949035)

## oq19-fork
sleep events (a wall gap over 3 sampling intervals inside a run): 1
* asleep 424 s (VM monotonic advanced 424 s, uptime 424 s) starting at wall 1789949072

| scenario | BUSY phases (wall) | slept inside BUSY / IDLE | live gates | wake tails excused (s) | live vs replay |
|---|---|---|---|---|---|
| 1 | none | 0 / 1 | all pass | - | 0.0% |

seconds from an IDLE label's start to a sleep inside it: 235 (deadline 270 s)
first asleep status after the last IDLE label: never (deadline wall 1789949766)

## Fork clock check (60 s)
monotonic 0.9991 s/s, uptime 0.9999 s/s

## Shim timeline (treatment)
* 1789944363 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789944364 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789944366 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789944405 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789944478 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789945410 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789945610 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789945611 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789945822 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789945852 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789946065 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789946066 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789946070 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789946109 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789946307 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789946337 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789946375 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789946680 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789946681 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789946793 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789947122 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789947339 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789947370 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789947581 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789947613 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789947824 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789947825 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789947855 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789948066 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789948097 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
* 1789948309 assert
* auto-hibernate for oq19-treatment: off
* auto-suspend for oq19-treatment: off
* 1789948340 release
* auto-hibernate for oq19-treatment: 120s
* auto-suspend for oq19-treatment: 120s
