# The shadow terminal keeps the app's history, compressed, and sends only the newest part that fits

Decided 2026-10-14 (#462, #463). Each session's shadow terminal in `workroomd` keeps what the app's own pane keeps: the same Ghostty commit's default of 50 MB of history with no line limit (`SCROLLBACK_MAX_BYTES`). Before this it kept libghostty's default 10 KB, about one page, so a pane that reattached came back with almost none of its history (#462). Every daemon compresses each shadow's idle history on its 2 s screens tick (#463).

What is kept is not what is sent. Every record, repaint and hand-off screen carries the screen and the newest history rows whose paint fits its budget (`format_tail`), because a paint's size follows how densely its rows are styled, not how many there are: the same 10,000 lines at 200 columns measured 1.9 MiB plain and 75 MiB in truecolour. A byte or line cap on what is kept cannot bound what is sent (#469's 4 MiB cap still produced 18 MiB records, which `save` deletes).

The invariants:

- **Kept follows the app.** Both keep 50 MB, fixed on purpose: there is no setting for it (#471, `.out-of-scope/scrollback-size-setting.md`). If the app's limit changes, the shadow's changes with it.
- **Each paint is the newest history that fits its budget.** A repaint (`REPAINT_MAX_BYTES`, `MAX_RECORD` less 64 KiB), a record on disk (`RECORD_MAX_BYTES`, 1 MiB: rewritten every 2 s on a busy remote session and read only after a host restart), a hand-off screen (its share of `HANDOFF_TOTAL_BYTES`, 16 MiB, at most a repaint).
- **The parts whose size history does not change are sized first** (the erase, kitty flags, cursor, and on the alternate screen that screen's paint); the primary's history gets what is left. The screen alone is always sent, even over a budget smaller than itself.
- **How many rows fit comes from the formatter's own output**: the newest 64 rows are formatted first to measure density, then at most three guesses scaled at 90% of `budget / bytes` and growing at most 8 times a step (prompts over an older truecolour dump otherwise formatted 118 MB once to send 4 MiB), stopping within 80% of the budget, then halvings.
- **A paint reaches the last row of the screen**, whatever history it carries, so the next output lands below the last line. Ghostty's untrimmed VT output has kept the trailing blank rows since v1.4.0 (amended 2026-10-31, #552; the daemon used to add them as scroll padding).
- **A hand-off that runs out of time still happens.** Screens are captured within `HANDOFF_FORMAT_DEADLINE` (250 ms) with every session stopped; sessions reached after it carry their screen alone, and one under a full-screen program skips the primary's paint, which costs a copy of the terminal. Refusing instead would refuse again at every launch while the same sessions stayed open, and the daemon would never upgrade. The timeout sum in `handoff.rs` counts the deadline and a 250 ms table-write allowance; the app waits 7 s.

What a user sees: a reattached pane has up to 50 MB of history in the daemon, and a repaint of up to about 4 MiB: all of a full history of short coloured lines (28,809 rows at 200 columns came to 2.5 MiB), about 18,000 rows of full-width random text, about 800 of the densest (truecolour changing every cell). A pane restored after its host restarted has up to 1 MiB: about 10,000, 4,500 and 160 rows of the same. After a daemon upgrade each session starts from the tail it was handed, its share of 16 MiB; if capturing screens takes longer than 250 ms, the rest start from their screen alone, and `workroomd.log` says how many.

There is no runtime override, no setting, environment variable or flag, for any of these numbers. They are fixed on purpose, and changing one is a code change (#471 was closed rather than add a setting).

Measured (release, Apple silicon, 200 by 50, `measure_shadow_history` and `measure_hand_off`; re-run both on every engine bump):

| History (150,000 lines, 28,809 rows kept) | Resident | Compressed | Compress | Repaint | Clone (alternate screen) |
|---|---|---|---|---|---|
| Moderate (16 colours, short lines) | 47.7 MiB | 1.26 MiB | 7 ms | 2.50 MiB, all rows, 25 ms | 28 ms |
| Dense (truecolour alternating per cell) | 47.7 MiB | 0.92 MiB | 5 ms | 3.39 MiB, 810 rows, 16 ms | 42 ms |
| High-entropy (random base64) | 47.7 MiB | 16.8 MiB | 68 ms | 3.53 MiB, 18,315 rows, 24 ms | 96 ms |

A hand-off of ten sessions like the first row, each under a full-screen program, captured five with their history and five with their screen alone in 257 ms, and encoded and wrote its 7.5 MiB table in 10 ms. Because the copy can take ~100 ms, the primary's paint is kept while a program runs, and dropped when the pane resizes or output switches screens or resets the terminal.

Alternatives rejected: a byte cap on what is kept (bounds memory, not what is sent, and the densest record still exceeded `MAX_RECORD`); a line cap (the same, and fewer rows than the app); paging history to the client on demand (#470: GhosttyKit cannot insert history above what a surface shows, so it needs an app-side history view); a hand-off by snapshot (TODOS.md: snapshots have no cross-revision guarantee, ADR 0031, so it needs a same-engine check); refusing a hand-off that runs out of time (above).

Residual risks, accepted:

- History that compresses poorly (random base64) keeps about 17 MB per full session, about 340 MB for twenty such panes on one host. The app's own panes keep their 50 MB uncompressed.
- A row guess can still overshoot when density changes sharply, by at most 8 times the rows of the last format (measured peak 4.6 MB for a 4 MiB repaint over truecolour history).

Source: [`vcs/crates/workroomd/src/terminal.rs`](../../vcs/crates/workroomd/src/terminal.rs), [`vcs/crates/workroomd/src/session.rs`](../../vcs/crates/workroomd/src/session.rs) (`frozen_formatting`, `compress_shadows`), [`vcs/crates/workroomd/src/screens.rs`](../../vcs/crates/workroomd/src/screens.rs), [`vcs/crates/workroomd/src/handoff.rs`](../../vcs/crates/workroomd/src/handoff.rs).
