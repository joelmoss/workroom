# Herdr's OSC 7577 implementation and what Workroom can reuse

Status: research, 2026-11-26. Read from the PR diff (`gh pr diff 429`) and the head commit's files through the GitHub API. No Herdr code was built or run. The tweet could not be fetched (HTTP 402 from x.com), so it is not a source. Companion to `docs/designs/rex-program-resume-research.md` (call it "the Rex note": its §2 is the wire protocol, §3 Rex's trust rules).

**Answer: Herdr merged OSC 7577 support on 2026-11-26 (PR #429, head `0cb50d5`, merge `1f90391`). Its daemon ("core") puts a per-terminal token in `OSC7577_TOKEN`, scans each pty's raw output for `ESC ] 7577 ; ... ST`, checks the `mac` and a plus-or-minus 60 s window, and accepts a report only from a process under the terminal's own first process, same user, never root. It stores the record (token and argv in plain text) in `terminals.json`. When a kept terminal's program is lost (reboot, crash, core stop), it starts a login shell that runs a one-shot helper (`herdr-core __resume <file>`) which re-runs the reported argv in the reported cwd, else a plain shell. It has no trust rules or allow-list: any authenticated argv from a descendant process is re-run. That is the main difference from Rex. The code is Apache-2.0, in Rust, but the module is crate-private and the crate is `publish = false`, so Workroom cannot depend on it; it can port the logic and tests, which Apache-2.0 allows with its notice and change-marking terms. No coding agent emits OSC 7577 natively today except Pi (open source, `earendil-works/pi`). Claude Code has an open feature request (anthropics/claude-code#112408), its changelog up to 2.1.332 never mentions 7577, and no Codex hit was found.**

Terms: record = a stored resume report; core = Herdr's daemon; holder = Herdr's pty-holding helper process; kept = a Herdr terminal opted in to recovery (`hc keep`, `run --keep`).

## 1. PR state and scope

| Item | Finding | Source |
|---|---|---|
| State | MERGED 2026-11-26T17:04:42Z. Zero reviews, zero comments, zero inline comments. So there is no review discussion to read. | [S1] |
| Commits | `878e317b` "feat: resume kept programs with osc 7577" (16:05Z), `0cb50d57` "fix: resume review round" (16:37Z). Head = `0cb50d57832f3ebb69157ce7f023fbbc520181a8`; merge commit `1f9039171eaabfda0dde66facc1ea8bfc94874d6`. Author Ogulcan Celik. | [S1] |
| Spec version | Not stated in the PR or code. Spec v0.5 was published 2026-11-25 (Rex note). The test vectors are the spec page's published examples (§4 below). | [S1], [S2] |
| Scope | "A kept pane whose program reported how to resume itself ... comes back after a reboot, crash or core stop running that program again in its folder, instead of a bare shell. Programs that don't report still get a shell. Proven on Linux, macOS and Windows with real reboots. Refs #15." | [S1] |
| Files (31) | New: `src/resume.rs` (358 lines), `src/resume/protocol.rs` (287), `src/resume/launch.rs` (146), `src/platform/unix_resume.rs` (167), `src/platform/windows_resume.rs` (190), `tests/resume.rs` (287). Edited: `api/run.rs`, `kept.rs`, `runtime.rs`, `terminals.rs`, `viewers.rs`, `foreground.rs`, `exec.rs`, `cli.rs`, `paths.rs`, `platform/mod.rs`, `platform/windows.rs`, `platform/windows_exec.rs`, `holder_proto.rs`, `config.rs`, `api/types.rs`, `lib.rs`, `SKILL.md`, `help.txt`, `docs/commands.md`, `schema/hc.openrpc.json`, `scripts/notices`, `Cargo.toml` (adds `sha2 = "0.10"`), `Cargo.lock`, `THIRD-PARTY-NOTICES`. | [S1] |
| Origin | Issue #15 (closed): users lost Claude Code and omp conversations after reboots. Its proposals were an OSC 7501 `resume` key and a core-run "recovery command" (a prototype in a fork). The maintainer's closing comment is only "resume via osc 7577 implemented via ... #429". | [S3] |

## 2. The mechanism (file:line at head `0cb50d5`)

Paths are under `crates/herdr-core/`. Line numbers are in the head files, checked by grep.

| Piece | What Herdr does | Source |
|---|---|---|
| Token | `TOKEN = "OSC7577_TOKEN"`. `Resume::new` makes `platform::random_hex()` per terminal; returns `None` (resume off) if the user is root or setuid, or the state dir is not secure. | `src/resume.rs:14`, `:72-86` |
| Delivery | `terminal_env` inserts the token into the spawn env of every new or recovered terminal. A new token is minted at each recovery. | `src/api/run.rs:169-173`, `:228-229`; `src/kept.rs:102-118` |
| Kept out of children | `child_env` drops any client-supplied `OSC7577_TOKEN` (case-insensitive on Windows) after merging; `exec` env does the same, and a test asserts `hc exec` sees it unset. Herdr does not strip it from the program's own children: that is the program's job (spec: programs SHOULD strip it). SSH: not found in the diff (nothing forwards it; the spec says do not forward). | `src/api/run.rs:247`, test `:264-270`; `src/exec.rs:94`; `tests/resume.rs` "restart_preserves..." |
| Framing | A byte state machine over raw pty output: open string `ESC ] 7577 ;`, terminated by BEL or `ESC \`. Total frame limit 8192 bytes, longer is dropped. It resets on CAN, SUB or a new ESC, ignores DCS/SOS/PM/APC bodies, and works across any read split (the test splits at every byte). It tracks a byte `offset` for each frame. It is fed raw output in `Core::output`, before the screen, and also the holder's replayed tail on adoption. | `src/resume/protocol.rs:108-109` (`OPEN`, `LIMIT`), `:137` (`feed`); `src/viewers.rs:150`; `src/runtime.rs:504-506` |
| `mac` | `SHA-256(body-before-":mac=" + ":" + token)`, lowercase hex, compared byte-wise with a XOR fold (constant time). The mac must be the last 64 chars after `:mac=`. | `protocol.rs:193-198` (`mac`), `:214-222` (`authenticate`) |
| Time window | `now.abs_diff(time) > 60` is ignored: plus or minus 60 s, both sides. `time` and `pid` must be decimal with no leading zero, no `0`, no sign, and duplicated keys must agree. | `protocol.rs:201-212`, `:223` |
| Per-pid freshness | Per pid one `Word{time, offset, record}`. A report is dropped if its stream offset is not past the stored one (replay protection after a core restart re-reads the holder tail) or its `time` is older than the stored one (equal is accepted). Only accepted reports advance the stored `time`. At most 256 pids per terminal; unrecorded words are pruned after 60 s. | `src/resume.rs:129-162` (`apply`), `:137` (prune), `:140` (gate) |
| `argv` | Comma-split (max 65 split, more than 64 elements rejected), each element base64 decoded and re-encoded to demand canonical form (padding optional), valid UTF-8, no control characters. Element 0 must be an absolute path or a bare name (no separator, not starting with `-`). Empty trailing elements allowed. Frame cap 8192 bytes. | `protocol.rs:230-246` (`decode`, `command`), `:263-266` |
| `cwd` | Base64, absolute path only. At resume time a reported cwd that is not a directory means no resume (`NotFound`); with no `cwd` it uses the owner's cwd (read from the process when the report was accepted), else the recovery default. On Windows a Unix-style cwd is rejected (test). | `protocol.rs:268-275`; `src/resume/launch.rs:16-30` |
| `clear` | `clear=1` alone gives `Action::Clear`: the pid's record is removed, but the report still advances `time` (so a replayed older `set` is ignored). `clear=0`, `clear` with `argv`, are rejected. | `protocol.rs:277-286`; `resume.rs:151-156` |
| `need` | Accepted only if every listed key is in `{pid,time,mac,argv,cwd,clear,need}`; otherwise the report is rejected. Test vector `argv=Yg==:need=later` is rejected. | `protocol.rs:249`, `:278` |
| Unknown keys | Lowercase `a-z` keys with a value limited to `[A-Za-z0-9_.,+/=-]` are accepted and ignored (`unused=abc` parses). Uppercase keys, bad value characters, duplicate keys: rejected. | `protocol.rs:251-262`; test `:65-104` |
| Owner check | The reporting `pid` must be alive, owned by the same user as core, and have the terminal's first process (`root`, set at spawn) as an ancestor (parent chain up to 128, parent must not start later than child). Otherwise a `set` report becomes "no record". On Linux: `/proc/<pid>` fd, start time from `stat`; on macOS: `proc_pidinfo` + start time from `proc_pid_rusage`. Identity is `(pid, start time)` so pid reuse is detected. | `resume.rs:104-127` (`owner`); `src/platform/unix_resume.rs:31-97` |
| Ignored vs rejected | Ignored (no state change): bad `mac`, bad `time`, malformed envelope (no valid `pid`/`time`). Rejected: authenticated but malformed or unsupported (bad base64, both `argv` and `clear`, bad `need`, relative path, over 64 elements, control chars): `Report.action = None`, which removes that pid's record (but does not advance `time`). A `set` from a pid that fails the owner check also leaves no record. Herdr removes only the reporting pid's record, not "all records of that owner" as the spec says. | `protocol.rs:214-228`; `resume.rs:143-156`; test `protocol.rs:65-104` |
| Storage | `Terminal.resume: Option<Resume>` in the registry, serialised to `terminals.json` under the state dir with the token, owner identities and argv in plain text; `#[serde(skip)]` on the stream state. Excluded from the public API by the `PRIVATE` list, and `Debug` prints `Resume([private])`. A test asserts it is saved but never in the public projection. The state dir is forced to mode 0700 and must be owned by the user. Saved after each accepted change. | `resume.rs:44-60`, tests `:340-357`; `src/terminals.rs:116-118`, `:428`; `src/paths.rs` (`secure_state_dir`); `platform/unix_resume.rs:15-24` |
| Exit and grace | Every foreground-poll tick (`HC_FOREGROUND_MS`) `reconcile_resume` checks each owner pid: if gone (or pid reused) it stamps `gone_since`; after `EXIT_GRACE_MS = 2000` still gone, the record is deleted; if it reappears the stamp resets. So a record survives a pty loss inside the 2 s. Skipped when core is stopping, restarting, killing, or the host is shutting down. | `resume.rs:15`, `:198-208` (`check_exit`), `:229-271`; `src/foreground.rs:182` |
| Deliberate end | An explicit `kill` drops the record; an ordinary exit with a code ends the terminal and drops it (`t.resume = None`). If the terminal's first process dies by signal while its holder is healthy, that process's record is removed (reads as a deliberate close). | `src/terminals.rs:353-360`; `resume.rs:164-170`; `runtime.rs:899-906` |
| Restore trigger | Only for kept terminals whose program is lost (reboot, holder death, core stop). Core start adopts live holders first (`adopt` feeds the holder tail so a `clear` written while core was down is replayed). | `src/kept.rs:95-135`; `src/runtime.rs:322-358`, `:464-582` |
| Choice | Among records, drop any whose owner is an ancestor of another record's owner... then pick the highest stream offset. If the root program and a child both reported, the ancestor-most reporter wins (`choice` keeps records no other record's owner is an ancestor of; the test shows the parent preferred over the child, and the last report winning between unrelated owners). | `resume.rs:172-178`; test `:305-322` |
| Launch | `prepare` writes `resume-<id>-<32hex>.json` (`{argv, cwd, shell}`, mode 0600) in the state dir and spawns `<shell> -lic '"$1" __resume "$2"; exec "$0" -li' sh <exe> <helper> <file>` for bash/zsh/sh/dash/fish (login shell so the user's PATH from profiles applies; macOS always login). Other shells go through `/bin/sh -c`. Shell flags outside `-l -i -li -il --login` mean no resume. `first` (the reporter was the terminal's own first process): `exec` the helper so no shell stays behind. | `src/resume/launch.rs:16-60`; `platform/unix_resume.rs:99-134` |
| Helper | `claim` renames the file to `.claim` with a no-replace rename (one claimer only), checks it is a private regular file owned by the user with one link and 128 KiB or less, deletes it, then `chdir`s and `execv`s the argv (PATH lookup for bare names, `X_OK` check). The argv is passed as literal words, never through a shell. Failure prints "hc: could not resume the program" then a shell (first mode) or exit 1 (the shell wrapper then does its own `exec`). | `launch.rs:84-122`; `platform/unix_resume.rs:136-166` |
| Loop guard | A recovered terminal gets `rearmed = true`; if it is lost again within `RAPID_LOSS_MS = 10_000` of its start, all records are cleared, so a broken resume cannot loop. The screen divider reads "-- the program above ended; starting it again --". | `resume.rs:16`, `:164-170`; `kept.rs:30-31`, `:140-143` |
| Clean-up | Abandoned launch files (names `resume-<id>-<32hex>.json/.claim` not owned by any record) are removed at core start; the match is on a strict name pattern in the private state dir. | `launch.rs:62-82`; `resume.rs:18-26` |
| Trust or allow-list | None found. Only syntax checks (`command()`, `decode()`), same-user, not-root, descendant-of-first-process, then the argv is run. No per-program rules, flag lists, directory limits or opt-out key. Secrets in argv are stored in clear text in `terminals.json`. | `protocol.rs:240-246`; whole PR |
| Programs expected | The PR text says "pi supports it". The tests use a fixture shell script; the spec's nvim, lazygit and `resume-wrap` examples appear only as test vectors. The PR touches no Claude Code, Codex or other agent hook installer (not found). | [S1]; `tests/resume.rs` |

## 3. Departures from, or readings of, the spec

Compared with the Rex note §2 and §3.

| Point | Herdr | Spec (as summarised in the Rex note) | Source |
|---|---|---|---|
| Trust rules | None; any authenticated argv re-runs. | The spec is silent. Rex adds per-program rules on top (Rex note §3). | `protocol.rs`; Rex note §3 |
| Window | Plus or minus 60 s, fixed. | 60 s "suggested". | `protocol.rs:223` |
| Freshness | Per pid, plus a stream-offset order that is not in the spec. | Not older than the last accepted report for that pid. | `resume.rs:140` |
| Rejected report | Removes the reporting pid's record only. | Removes all records of that owner. | `resume.rs:143-156` |
| Who may report | Pid must descend from the terminal's first process and be the same user. | Not specified (the spec only requires the token). | `resume.rs:104-127` |
| Root | Resume disabled when the user is root or setuid. | Root terminals SHOULD NOT accept without opt-in; Herdr has no opt-in. | `unix_resume.rs:10-13` |
| Signal exit | If the terminal's first process is killed by a signal while the holder is healthy, its record is dropped. Everything else (reboot, holder loss) keeps it. | Programs MUST NOT send clear on SIGHUP/SIGTERM; silent on how a terminal reads a signal death. | `terminals.rs:353-354`; `resume.rs:164-170` |
| Grace | 2000 ms, measured by polling the owner pid. | "a second or two". | `resume.rs:15` |
| Limits | 64 elements, 8192-byte frame. | At least 2048 bytes and 64 elements. | `protocol.rs:109`, `:263` |
| Base64 | Canonical only; padding optional. | Not stated in the Rex note. | `protocol.rs:230-238` |
| `need` | Known key names only; unknown name rejects. | Unsupported key means reject. | `protocol.rs:249`, `:278` |
| Numbers | Rejects `0`, leading zeros, signs. | Not stated in the Rex note. | `protocol.rs:201-206` |
| cwd fallback | Reported cwd, else the owner's cwd at report time, else the default; OSC 7 is not used. | Reported cwd, owner's directory, OSC 7 (opt-in), default. | `launch.rs:16-30` |
| Run environment | Login shell after startup files, argv literal. Matches the spec. | Same. | `unix_resume.rs:99-134` |
| Spec ambiguities raised | None in the PR; it has no review or discussion. Implicit questions its tests settle: equal `time` is accepted; a clear still advances `time`; the same second can carry several reports. Whether the grace window applies on `clear` is not tested. | | `resume.rs:305-322` |

## 4. Test vectors Workroom could copy

Herdr keeps its tests in `src/resume/protocol.rs:1-107`, `src/resume.rs:273-357`, `src/resume/launch.rs`, `src/api/run.rs:264-270`, and an end-to-end `tests/resume.rs` (Unix only; shells bash, zsh, sh, dash, fish; needs `hc` and a core, so it is a model, not a copy).

Token `dummy-token-replace-me`, `now = TIME = 1795543200`. These are the spec's published examples (see the Rex note; the page itself was not re-read for this note):

```
pid=74877:time=1795543200:clear=1:mac=c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93   -> Clear
pid=74877:time=1795543200:argv=bnZpbQ==,LVM=,L2hvbWUvdXNlci8ubG9jYWwvc3RhdGUvbnZpbS9zZXNzaW9ucy84ZjJjMWQudmlt:mac=9dbb99bfb856749a87563839d7ce9062818d78cf25909db93f309e0cd3b1909b   -> argv[0] = nvim
pid=74877:time=1795543200:argv=bGF6eWdpdA==:cwd=L2hvbWUvdXNlci9zcmMvcHJvamVjdA==:mac=35cb909805c380336efd3689a125acc774a9dec8422a1d21492ebec06ca758e1   -> lazygit
pid=90412:time=1795543200:argv=cmVzdW1lLXdyYXA=,c3No,ZGV2Ym94:mac=e76149d0ba54a83570ffab0583867dacdfa23928ba9d18604f0badea88b62b65   -> resume-wrap
```

Window, token and framing cases from the same test:

- `authenticate(CLEAR, TOKEN, TIME - 60)` and `TIME + 60` are accepted; `TIME - 61` and `TIME + 61` are ignored (None); a different token is ignored.
- Framing: both terminators (`\x07` and `\x1b\\`) at every split point; `output\x1b]0;` followed by a full frame still yields the report; a frame ended by CAN (`\x18`) yields nothing; a body of exactly `LIMIT - OPEN.len() - end.len()` bytes is accepted, one byte more is dropped.
- Authenticated but malformed (each gives `action == None`, i.e. rejected, with a valid `mac` computed by the test): `argv=Yg==:argv=Yg==` (duplicate), `argv=Yg==:clear=1`, `argv=Yg==:need=later`, `argv=Yg==:Tag=x`, `argv=Yg==:unknown=!`, `argv=Yg==:need=`, `argv=Yg=`, `argv=Yh==` (non-canonical), `argv=Yg===`, `argv=Yg==,wqA=,AA==` (control char), `argv=Yg==,f4A=` (DEL), `argv=Yg==,woA=` (C1), `argv=` (empty), `argv=Li9h` (`./a`), `argv=LWE=` (`-a`), `argv=Yg==:cwd=cmVs` (relative cwd), `clear=0`, `clear=1:pid=5` (duplicate key).
- Accepted: `argv=Yg,LA==,:unused=abc` gives argv `["b", ",", ""]` (unpadded base64, empty element, unknown key ignored); 64 elements (`Yg` plus 63 of `,YQ`) accepted, 65 gives `None`.
- Ignored (whole report None): `clear=1:pid=6` (a second `pid`), `clear=1:time=99999999999999999999999`.
- State rules (`resume.rs` tests): replay of an already consumed offset is ignored; older `time` ignored even if emitted later; same-second new reports apply; a reused pid (new start time) is not an ancestor of its old child; owner exit gives a 2000 ms grace (`check_exit(.., 61_999)` keeps the record, `62_000` drops it); `lost(Some(60_000), 70_000, false)` keeps records, `lost(Some(60_000), 69_999, false)` after a re-armed resume clears them.
- End to end: reporter script emits `argv=fixture-resume,resumed,"two words","a'\"b",'$(echo unexpected)',""` with `cwd`; the test checks the resumed program received those words literally, in the saved cwd, with a new 32-char token different from the old one.

## 5. Licence

| Item | Finding | Source |
|---|---|---|
| herdr-core | Apache-2.0 (`LICENSE` is the Apache 2.0 text; GitHub reports `Apache-2.0`; workspace `Cargo.toml` `license = "Apache-2.0"`). No `NOTICE` file (404). | [S4] |
| Language and publishing | Rust 2024. `publish = false` in the workspace, and `mod resume;` is private (`lib.rs:27`), all items `pub(crate)`. It cannot be used as a crates.io dependency, and as a git dependency the resume code is unreachable. | [S4]; `src/lib.rs` |
| Workroom | `license = "MIT"` in `vcs/Cargo.toml` `[workspace.package]` line 18. | `vcs/Cargo.toml` |
| Verdict | Copying or porting is allowed. Apache-2.0 §4 requires: give recipients a copy of the licence; mark modified files as changed; keep copyright, patent, trademark and attribution notices in the source; keep any NOTICE text. It does not require relicensing Workroom. Putting Apache-2.0 code into an MIT repo is normal, but those files stay Apache-2.0 and the binary's third-party notices (`make notices`) should list it. Porting ideas and re-deriving tests from the public spec vectors needs no licence; the spec's vectors are Rex's. This is my reading of the licence texts, not legal advice; confirm with the owner. | Apache-2.0 text |

## 6. Which agents report OSC 7577

| Agent | Finding | Source |
|---|---|---|
| Pi | Emits it natively: `packages/tui/src/program-resume.ts` reads `OSC7577_TOKEN`, docs in `terminal-setup.md#program-resume`; Pi removes the token from its own environment at start. | [S5] |
| Claude Code | Not native. The open request #112408 (2026-11-26, label `area:tui`) asks for `argv = claude --resume <id>` on start, `/resume`, `/clear`; `clear=1` on `/exit` or Ctrl+D; token kept from children. It says a hook can write to the tty today. The changelog (top entry 2.1.332) names OSC 7501 in three entries (L1084, L1085, L1153, L3251 of the file) and has no "7577" or "resume protocol". | [S6], [S7] |
| Codex | Not found. A code search of `openai/codex` for `7577` matched only unrelated hashes and an unrelated issue; no issue or release note found. Releases checked: the alpha pre-releases to `0.174.0-alpha.7`. | `gh search` on 2026-11-26 |
| Others | `charmbracelet/bubbletea` has an `examples/program-resume`; `Gaurav-Gosain/tuios` has `progresume`; NousResearch `hermes-agent` PR #160297 is open (a "reference implementation passing the spec's vectors"). omp (reported by an issue #15 user) is not shown to emit it. | `gh search code`; [S6]; [S8] |
| Herdr's way to make agents report | Not in the PR: no hook installer or wrapper was added. Before it, issue #15 users used SessionStart hooks writing labels and `.bashrc` blocks. | [S1], [S3] |

## 7. What Workroom has today (for the mapping)

| Piece | Workroom | Source |
|---|---|---|
| OSC 7501 | Parsed by libghostty-vt inside the daemon's shadow terminal: `ghostty-vt` exposes a `program_status` callback; `vt.rs` collects reports and answers the probe; `program_status.rs` keeps records per owner group. The raw 7577 sequence has no libghostty callback in `terminal.rs` (only `PROGRAM_STATUS` was found, not 7577). | `vcs/crates/ghostty-vt/src/terminal.rs:33-34`, `:524`; `vt.rs:58-73`, `:315`; `program_status.rs:1-5` |
| Session env | `identify()` appends `WORKROOM_PANE` and `WORKROOM_DAEMON` to each new session's environment, removing client-forwarded copies first. | `vcs/crates/workroomd/src/terminal/dispatch.rs:538-547` |
| Process info | `process.rs` reads argv, environment values and cwd for a pid on macOS (`procargs2`) and Linux (`/proc`); it has no start-time identity or parent-chain walk (not found by grep of function names). | `vcs/crates/workroomd/src/terminal/process.rs:84-92`, `:177-273`, `:314-336` |
| Hashing | No `sha2` or `sha256` dependency found in the workspace manifests or lock. | grep of `vcs/Cargo.lock`, `vcs/crates/*/Cargo.toml` |

## Not documented / open questions

- The tweet: unreadable (402). Anything it says beyond the PR text is unknown.
- Which spec revision Herdr targeted: not stated; the vectors match the Rex note's v0.5 page but that page was not re-read.
- Review discussion: none exists (no reviews, no comments on #429).
- Master has moved after the PR (the repo was pushed at 19:01Z the same day, and master's `resume.rs` already contains an "OSC 7577 resume disabled" log line absent at head). Line numbers here are for `0cb50d5` only.
- Herdr's `Windows` side (`windows_resume.rs`, PowerShell only) was only skimmed.
- Whether Herdr's behaviour on SSH or a remote core forwards the token: not found.
- No documentation of why Herdr chose no trust rules; whether a rule layer is planned: not found.
- Pi's exact emission details (when it clears) were not read.
- Claude Code and Codex release notes after 2.1.332 and 0.174.0-alpha.7 were not checked.

## Implications for Workroom

Facts and options only; no recommendation.

| Piece | Herdr gives | Workroom option | Where it would sit |
|---|---|---|---|
| Frame scanner (`Stream::feed`) | A tested raw-byte OSC 7577 scanner. libghostty has no 7577 callback, so a daemon scanner over pty output is needed. | Port it (Apache-2.0 terms), or write a smaller one against the spec. | A new module beside `program_status.rs`, fed from the pty read path before `vt.rs`. |
| `authenticate`, `parse`, `decode`, `command` | Pure functions with the vectors above. Needs `sha2` (new dependency; a `sha256` crate dependency adds a notice entry). | Port as-is, with its tests. Highest reuse, lowest platform risk. | A `resume/protocol.rs`-style module in `workroomd`. |
| Token | `random_hex` per terminal, injected through env; stripped from client env and `exec`. | Write: add `OSC7577_TOKEN` in `dispatch.rs` next to `identify()`, and remove any forwarded copy the same way. | `dispatch.rs:538-547`. |
| Owner check (descendant of the first process, same user, start-time identity) | `resume_process` for Linux and macOS, plus ancestor walk. | Port or write. `process.rs` has argv/cwd readers but no start time, parent or identity; those would be new. | `process.rs` and the new module. |
| Per-pid records, freshness, offset replay guard | `apply`, `check_exit`, `choice`, tests. | Port; the offset rule matters only if Workroom re-reads pty tails after a daemon restart. | The new module, with state beside OSC 7501's records. |
| Persistence | `terminals.json`, token and argv in plain text, 0700 dir. | Write: Workroom has its own saved-layout and screens files; where records live and their file mode is a decision (Rex note G5). | Daemon state or the app's saved layout (decision). |
| Restore | A login-shell wrapper plus a one-shot helper subcommand with claim-once launch files, rapid-loss guard, screen divider. | Write: Workroom's restore paths are ADR 0046 (local) and ADR 0031 (remote); the helper would need a hidden `workroom` subcommand. The argv-literal, claim-once and 10 s loop guard are portable ideas. | `workroomd` session start for a replaced session; hidden command in `src/commands/`. |
| Trust model | None. | Write if wanted: Rex's rules (Rex note §3) are the other model; Herdr's is "descendant, same user, authenticated". | Policy layer between records and restore. |
| Agents | Only Pi emits natively; Herdr adds no hook. | Claude Code and Codex would need a hook or wrapper, as in Rex's `rex skill setup`; nothing exists in Workroom (Rex note §6). | Outside the daemon (agent config). |

## Sources

- [S1] PR #429, `herdrdev/herdr-core`: <https://github.com/herdrdev/herdr-core/pull/429>. Head `0cb50d57832f3ebb69157ce7f023fbbc520181a8`, first commit `878e317b7aa1fa15b4bbacdab70443339b346654`, merge `1f9039171eaabfda0dde66facc1ea8bfc94874d6`. Diff saved from `gh pr diff 429`; head files read with `gh api repos/herdrdev/herdr-core/contents/crates/herdr-core/<path>?ref=0cb50d57...`.
- [S2] Program Resume Protocol (OSC 7577) v0.5: <https://www.superlogical.com/rex/docs/build/program-resume> (via the Rex note [S1]/[S4] there; not re-read here).
- [S3] Issue #15 "Discuss carrying a resume reference in OSC 7501": <https://github.com/herdrdev/herdr-core/issues/15>.
- [S4] Licence and manifests: <https://github.com/herdrdev/herdr-core/blob/master/LICENSE>, `Cargo.toml`, `crates/herdr-core/Cargo.toml` (read with `gh api`).
- [S5] Pi: <https://github.com/earendil-works/pi> (`packages/tui/src/program-resume.ts`, `packages/coding-agent/docs/terminal-setup.md`), found by `gh search code OSC7577_TOKEN`.
- [S6] Claude Code issue #112408: <https://github.com/anthropics/claude-code/issues/112408>.
- [S7] Claude Code changelog: <https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md>, read 2026-11-26 (top entry 2.1.332).
- [S8] NousResearch hermes-agent PR #160297: <https://github.com/NousResearch/hermes-agent/pull/160297> (state: open, title "feat(cli,tui): support OSC 7577 program resume protocol").
- Rex note: `docs/designs/rex-program-resume-research.md`. Workroom side: `vcs/Cargo.toml`, `vcs/crates/workroomd/src/terminal/{program_status,vt,dispatch,process}.rs`, `vcs/crates/ghostty-vt/src/terminal.rs`.
- Tweet <https://x.com/herdrdev/status/2125720826984935731>: not fetched (HTTP 402).
