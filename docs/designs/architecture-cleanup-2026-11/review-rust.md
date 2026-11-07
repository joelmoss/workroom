# Rust workspace review: `vcs/` (workroomd, wr-protocol, wr-vcs-git, wr-vcs-model)

Status: research. Evidence for the [cleanup plan](../architecture-cleanup-2026-11.md), measured at
`65f01f1fa`; its paths and counts are not updated as the plan is built.

Read-only. Measured on master at 65f01f1fa. Line numbers are from that tree.

**How the numbers were taken**
- **Prod/test split.** For each file I counted lines before and after its `mod tests {` line. Across `workroomd/src` there are 29,431 lines: 17,865 production and 11,566 inline tests, plus 10,582 lines in `tests/`. `session.rs` is 2,460 production lines and 2,544 test lines; `terminal.rs` is 1,890 and 1,713.
- **Clippy.** `cargo clippy --workspace --all-targets --offline` came back clean. That was Homebrew cargo 1.99.1, not CI's 1.96.1, and default features only.
- **Dead-code probe.** In a scratch copy of the workspace I changed every `pub mod` in `lib.rs` to private except `cli`, then ran `cargo check --lib --bins`, with and without `terminal-state` (`WR_GHOSTTY_VT_PREFIX` set to the cached `83fb95624-zig0.17.0/aarch64-macos` build). Output is in `scratchpad/deadcode-default.txt` and `deadcode-ts.txt`.
- **Compile times.** Measured in the same scratch copy, after appending a real function to a file:
  - incremental `cargo build -p workroomd --tests`: 2.6 s
  - incremental bin only: 1.0 s
  - release bin (thin LTO, codegen-units 1): 33 s
- **Churn.** `git log --since=2026-10-10` over `vcs/crates`: 117 commits, +18,483 / −6,174 lines. Hottest files, counting both the `wr-agent` and the `workroomd` paths:
  - `session.rs`: 32 commits
  - `serve.rs`: 20
  - `terminal.rs`: 19
  - `program_status.rs`: 10 under `wr-agent` alone

## 0. The headline question: is workroomd one crate because services share state, or by accident?

**Both, split cleanly down the middle.** One binary is settled (ADR 0026, ADR 0009: `execve` hand-off keeps every pty master, so everything that owns a session must be in one process). One *crate* is only justified for half of it.

### What genuinely shares state: the terminal cluster

`session`, `pty`, `shadow`, `terminal`, `images`, `input`, `screens`, `run`, `program_status` and `handoff` are coupled through `SessionStore` and the per-session lock triple `(Arc<Pty>, Arc<Mutex<Shadow>>, Arc<Mutex<Attached>>)` (`session.rs:158`). `SessionStore` itself (`session.rs:419-452`) owns:
- the session map
- `screens`
- `kills_in_flight`
- `ending` (Mutex+Condvar)
- `refused`, and `refusals` (its file)
- the program-status `Hub`
- `runs`
- two `Wake` condvars

`screens.rs`, `run.rs` and `program_status.rs` import `SessionStore`, and `SessionStore` holds their state: a real cycle, `session ↔ screens ↔ run ↔ program_status`.

### Lock graph, reconstructed (it is not written down anywhere as one hierarchy)

```
TERMINATING (static RwLock, session.rs:154)
  read:  kill / kill_all / reader end (1375, 1395, 1442, 2218)
  write: hand-off freeze (frozen_formatting, 1205)
    └─> sessions: Mutex<HashMap>            (store lock)
          ├─> refused                        ("only ever locked alone or inside the session map's lock", 433-436)
          └─> attached (per session)         (list + end of attach hold the store lock while waiting, 1210-1211)
                ├─> shadow (per session)     (apply_size 1822-1825, send_images 1849-1856, reader 2140-2147)
                │     └─> Hub.boot           (change_program_status: status.event(hub.boot()), 2026-2030)
                └─> writer (SharedWriter)    (attach repaint written under the attachment lock, 906-911)
leaves: ending (Mutex+Condvar), runs_wake / screens_work (Wake), Hub.subscribers, Subscriber.queue,
        images queues / encoder sender (images.rs:110-267)
store lock is dropped before a reader starts (824)
```

The order is consistent as far as I traced it. Its rules are spread across about six doc comments ("the ordering note above", `session.rs:930`), so a new contributor cannot check an edit against it.

### What shares nothing but plumbing: the request/reply services

`vcs`, `file`, `watch`, `layout` and `forward` never touch `SessionStore`. Their non-test `crate::` imports:
- `forward` → `rpc`
- `layout` → `rpc`
- `watch` → `file`, `rpc`, `transport`
- `file` → `rpc`, `vcs`, `watch`
- `vcs` → `cli`, `process`, `rpc`, `shell`

What they share with the rest of the daemon is process-wide liveness state, which idle-exit and hand-off consult:

| State | Where | Read by |
|---|---|---|
| admission budget `ACTIVE`, `Permit`, `Quiet` | `rpc.rs:56-129` | idle-exit (`serve.rs:280-283`), hand-off (`handoff.rs:438`) |
| file walks left behind | `file.rs:85` | hand-off (`handoff.rs:445`) |
| kills in flight | `session.rs:427` | idle-exit, hand-off (`handoff.rs:456, 465`) |
| idle wake | `serve.rs:136, 163` | called from `rpc::Permit::drop` (`rpc.rs:76`) and `session::KillInFlight::drop` (`session.rs:509`) |
| accept pause | `handoff.rs:194-199` | `serve` accept loop |

That is a "work in flight" ledger smeared over five modules, and it is the only cross-service shared state.

### Verdict

- **Module tree: yes.** It would give real boundaries for the five request/reply services and for the liveness ledger.
- **More crates: no, apart from one optional one.**
  - Compile time is no reason: an incremental test build is 2.6 s and a bin build 1.0 s.
  - The terminal cluster cannot be split without inventing interfaces for state that really is shared.
  - The one crate that would earn its keep is a `ghostty-vt` sys+safe-wrapper crate (complaint 8). It is for containment, not for speed.

## 1. Top complaints (ranked)

### 1. `SessionStore` and `serve.rs` are where every terminal feature lands, so two features cannot proceed in parallel
**Claim.** The Terminal service has no module of its own. It is spread over `serve.rs` (wire codecs and the FrameKind handler), `session.rs` (store, attachments, reader, kill, freeze, refusals, runs and screens hooks) and nine smaller modules.

**Evidence.**
- `impl SessionStore` is `session.rs:534-1684`: 1,150 lines and 51 `pub` fns. They cover lifecycle, refusals, runs, screens, program status, the hand-off freeze and adopt, and shadow compression.
- `read_session` is `session.rs:2062-2344`, 282 lines.
- `serve.rs::dispatch` (`528-826`) is an `if envelope.service == …` chain for six services. It then handles every Terminal/Control FrameKind inline (Attach, Input, Resize, List, Kill, Signal, Retag, KillAll, HandOff).
- `serve.rs` also holds the terminal payload codecs:
  - `encode_/decode_descriptor_list` (969, 1009)
  - `session_metadata` (1114)
  - `decode_retag` (1150)
  - `encode_resize` / `decode_resize` (1167, 1175)
  - `AttachRequest` (1197-1345)
  - `parse_session_id` (1355)
- It also does instance locking (55-100), freshen (102-130), idle wake (131-175), the `Daemon` accept loop (176-342), `bind` / `make_socket_folder` (357-380), `connect` and `spawn_daemon` (1068-1100).
- Churn since 2026-10-10: `session.rs` 32 commits and `serve.rs` 20, the top two in the workspace. `session.rs` commit subjects show five unrelated features landing in the same file:
  - run sessions #522 (9 commits)
  - images #551
  - pixel size
  - Retag
  - program status #358 / #473

**Cost.**
- Adding a Control frame touches `wr-protocol/frame.rs`, `serve.rs::dispatch`, a codec in `serve.rs`, `SessionStore`, `cli/attach.rs`, and usually `read_session`.
- A run-session change and an images change both edit `SessionStore`'s field list and `read_session`, so they conflict.
- Program status and screens both hang a `Wake` or `Hub` off the store.

**Direction.**
- Create a `terminal/` service module:
  - `dispatch.rs`, taken out of `serve.rs::dispatch`
  - `wire.rs`, the codecs in `serve.rs:969-1355`, or move them to wr-protocol (see 7)
  - `session/{store,attached,reader,terminate,freeze,refusals}.rs`
- Make `runs`, `screens` and `program_status` observers of the store through one small hook surface ("session created / output / ended"), not fields on it.
- `serve.rs` shrinks to the accept loop, `handle_connection` and a per-service dispatch table.

**Size: L.** Test churn is low if the session tests move with their code as sibling `tests.rs` files (see 6). The `tests/` binaries use only `SessionStore`, `SessionSpec`, `SessionId`, `READ_CHUNK`, `handle_connection`, `AttachRequest`, `parse_session_id` and `BUILD`; re-export those.

### 2. The lock hierarchy is implicit, and poison handling drifts per call site on the same mutex
**Claim.** No single place states the lock order (the graph in §0 had to be rebuilt from comments). Poison policy differs between call sites that lock the same mutex.

**Evidence.**
- Production code, counted before each `mod tests`:
  - 62 `unwrap_or_else(|e| e.into_inner())`
  - 21 `.lock().expect("…poisoned")`, all in `session.rs`
  - 5 `.lock().ok()`
  - 11 `if let Ok(..) = x.lock()`
  - 6 `let Ok(..) = x.lock() else`
- The same `attached` mutex:
  - panics: `attach` 906 `expect`; `read_session` 2140 `expect`
  - silently degrades: `targets` 1763-1767 returns no targets on poison, so output goes nowhere; `deliver` 1791 `.ok()?`; `send_images` 1849 returns
  - recovers: `apply_size` 1822 `into_inner`
- The store map:
  - panics: `expect("session store poisoned")` at 694, 720, 760, 869; `panic!` in `frozen_formatting` 1215
  - treats poison as false: `store.lock().is_ok_and(...)` / `map_or` in `read_session` 2084, 2229, 2331
- `session.rs:918-925` shows the authors know poisoning here is dangerous (an oversized repaint once poisoned the lock and killed the reader). That makes this drift, not ignorance.

**Realistic trigger and cost.** It takes a panic while the lock is held. The known one (the frame-cap panic) was fixed by chunking, so this is unlikely in ordinary use. What it costs is maintainability: every new call site picks a policy, and reviewers cannot tell a deliberate degrade from an accident.

**Direction.** Put one lock-order block in the store module's doc (the §0 graph). Adopt one poison rule per lock: recover everywhere (`into_inner`) or panic everywhere, using a small `lock_or_recover` helper. `significant_drop_in_scrutinee` is already a lint (`vcs/Cargo.toml:36-38`), so the team cares about this class.

**Size: S** for the documentation, **S-M** for the policy. No test churn.

### 3. Service modules depend on the CLI layer and on each other, against rpc.rs's own stated rule
**Claim.** `rpc.rs:3-4` says "Services depend on this rather than on each other." Four edges break that.

**Evidence.**
- **A service depends on a CLI command.** `vcs.rs:62,75` calls `crate::cli::run_script::{login_environment, PROBE_TIMEOUT}`. `cli/run_supervisor.rs:11` calls `super::run_script::probe_invocation`. The login-shell policy (`POSIX_SHELLS`, `run_script.rs:24-26`, and `probe_invocation`, 197-204) lives in a subcommand. Session shells use `shell.rs`.
- **File depends on Vcs.** `file.rs:27,184,344,359,370,422` uses `vcs::{absolute, relative, host_read_environment, run_exec_with, escaped_len, EXEC_REPLY_RESERVE}`. `vcs.rs` is really the daemon's "run a git child safely" library with the Vcs service bolted on.
- **The Terminal side depends on File.** `images.rs:58` and `terminal.rs:3247` (test) call `crate::file::base64`.
- **CLI depends on Vcs.** `cli/run_script.rs:172-181` uses `crate::vcs::{descendants, kill_recorded, REAP_GRACE}`.

**Cost.**
- The login-environment rule (#560, ADR 0063) cannot change without editing a CLI subcommand that two services rely on.
- Someone working on the File service has to understand `vcs.rs`'s exec internals.
- Splitting `vcs.rs` today would break `file.rs`.

**Direction.**
- `shell.rs` (or `host/environment.rs`) owns `POSIX_SHELLS`, `probe_invocation`, `login_environment` and `PROBE_TIMEOUT`.
- A `child.rs` / `exec/` module owns the environment scrub and pins, path validation (`absolute`, `relative`), the bounded capture and the tree kill (see 4).
- `base64` moves to a util module.
- Then `vcs`, `file` and `cli/run_script` all depend downward.

**Size: S-M.** Test churn: tests move with their functions; no behaviour change.

### 4. Child-process supervision is implemented four times, in two crates, and the copies have drifted
**Claim.** The pattern "spawn in its own group, scrub git env, capture with a bound, time out, signal the tree, SIGKILL survivors, reap" is copied.

**Evidence: tree kill (4 sites).**
- `workroomd/src/vcs.rs:592-632` (`run_exec_with`): snapshots descendants, TERM group, KILL recorded, KILL group.
- `workroomd/src/cli/run_script.rs:170-187` (`end_tree`). Its comment admits it: "`vcs.rs`'s exec does the same".
- `workroomd/src/session.rs:2400-2458` (`terminate`): HUP to roots and descendants, poll, KILL survivors, reap.
- `wr-vcs-git/src/diff.rs:165-190` (`run_bounded`): group SIGKILL only, no descendant snapshot. `vcs.rs:451-466` documents at length why that misses a `setsid` escaper.

**Evidence: git environment scrub and pins (2 sites, divergent).**
- `workroomd/src/vcs.rs:99-125` scrubs 7 keys, including `GIT_EXTERNAL_DIFF`.
- `wr-vcs-git/src/diff.rs:97-115` scrubs 6. It relies on `--no-ext-diff` at 346 and 696 instead.
- Both pin `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0` and `LC_ALL=C`, and both set `GIT_CEILING_DIRECTORIES`. `workroomd` reuses `wr_vcs_git::diff::ceiling_directories` (`vcs.rs:559`) but not the scrub.

**Evidence: bounded drain (2 sites).** `vcs.rs:420-450` and `diff.rs:119-160`.

**Evidence: `O_NONBLOCK` (4 sites).**
- `serve.rs:150` sets `F_SETFL O_NONBLOCK` without reading `F_GETFL` first. That is harmless on a fresh pipe, but it is the odd one out.
- `transport.rs:306-316`
- `pty.rs:618-626`
- `wr-vcs-git/src/diff.rs:125-132`

**Cost.** A fix to one copy (the setsid-escaper fix, the PID-reuse guard) has to be found and applied to the others by hand. `run_bounded` shows that one already wasn't. Two people changing the "git children" policy, one in each crate, will not see each other's edits.

**Direction.**
- Create one `exec` module in workroomd with:
  - `spawn_git(root, env) -> Command`
  - `capture_bounded`
  - `end_tree(pid, first_signal, grace)`
  - `set_nonblocking(fd)`
- Then either move the git-child half into wr-vcs-git as a public `git_command` that workroomd's exec also uses (wr-vcs-git already depends on `libc`), or have wr-vcs-git take a runner from its caller.
- `session::terminate` keeps its HUP semantics through the `first_signal` parameter.

**Size: M.** Test churn: the setsid-escape tests in `vcs.rs` (for example `exec_kills_a_descendant_that_escaped_the_process_group`, line 1781) move to the shared module. Add one for the `run_bounded` path.

### 5. `pub mod` for the integration tests switches off dead-code detection; about 10 methods exist only for tests
**Claim.** `lib.rs:11-31` makes 11 modules `pub`. Only `cli` is needed by `main.rs`. `tests/` uses `credential`, `forward`, `program_status`, `pty`, `screens`, `serve`, `session` and `transport`. `account` and `run` are `pub` with no external user at all (`grep -rlE 'workroomd::(account|run)\b' tests src/main.rs`: 0 hits). Because they are `pub`, rustc never reports unused items in them.

**Evidence.** From the private-modules probe, with each item's use sites confirmed by grep:
- **Dead in every build.** `Session::pty()` (`session.rs:260`): `grep -rnF '.pty()' src tests` gives 0 hits.
- **Production API used only by tests.** Every call site is in a `mod tests` block (past session.rs:2460, screens.rs:369, pty.rs:685) or in `tests/`:
  - `SessionStore::create` (745; production uses `create_then`)
  - `size_owner` (1124)
  - `with_pty` (1146)
  - `shadow` (1153)
  - `replay_bytes` (1160)
  - `Pty::wait` (`pty.rs:547`; only `pty.rs:920` and `1080`)
  - `Shadow::visible_text` (`shadow.rs:264`, `337`)
  - `ShadowTerminal::visible_text` (`terminal.rs:1787`)
  - `transport::{PipeTransport, PipePair, pipe, close}` and `FdStream::new` (`transport.rs:127, 229-277, 320`; only `transport.rs` tests and `tests/remote_transport.rs`)
- **Not dead, only hidden by cfg.**
  - `Pty::wait_readable_within` (`pty.rs:378`) is used at `session.rs:2102` under `#[cfg(target_os = "linux")]`.
  - The `program_status` constants, `Report`, `Event` and `images::Hold` are used only with `terminal-state`; the warnings go away with the feature.

**Cost.** Any helper added to a `pub` module and later orphaned is invisible to the compiler. Reviewers have to grep by hand, as this report did.

**Direction.**
- Delete `Session::pty`.
- Make `account` and `run` private.
- Gate the test-only methods behind `#[cfg(any(test, feature = "test-support"))]`, or move them into the test modules that use them.
- Expose what `tests/` needs through one `#[doc(hidden)] pub mod testing` re-export, so the rest can be `pub(crate)` and dead-code analysis comes back.

**Size: S.** Test churn is minimal: import paths only.

### 6. Inline test modules double the size of every big file
**Claim.** 11,566 of the 29,431 lines in `workroomd/src` are inline `mod tests`. The production code in the largest files is half what the line counts suggest:

| File | Production lines | Test lines |
|---|---|---|
| `session.rs` | 2,460 | 2,544 |
| `terminal.rs` | 1,890 | 1,713 |
| `vcs.rs` | 995 | 988 |
| `file.rs` | 788 | 724 |

There are 446 inline `#[test]` functions, against 188 in `tests/`.

**Cost.** Navigating and diff-reviewing a 5,000-line file whose second half is tests. Editors and agents read the whole file.

**Direction.** `#[cfg(test)] mod tests;` with a sibling `session/tests.rs`. Privacy is unchanged and the move is mechanical. Do it as part of 1's split.

**Size: S.** No assertion churn.

### 7. Integration tests re-implement the client, and the `common` harness is bypassed
**Evidence.**
- Five near-identical JSON request/reply `Client` structs, each with connect, a stream counter and a chunked-reply reassembly loop:
  - `tests/file_service.rs:17`
  - `tests/forward_service.rs:84`
  - `tests/program_status.rs:19`
  - `tests/remote_transport.rs:39`
  - `tests/status_service.rs:14`
- `Hello::current` / `Hello::decode` appear in 7 test files besides `common/mod.rs`, which already has a handshake: `attach_falls_back_to_a_shell` (4), `remote_transport` (4), `run_session` (3), `attach_survives_detach` (2), `host_environment` (2), `hand_off` (1).
- `daemon_binary()` is defined three times: `common/mod.rs:14`, `cli_contract.rs:12` and `run_script.rs:10`. The authors acknowledge it ("which this file doesn't pull in for one function"), so it ranks low.

**Cost.** A change to the chunked-reply framing, or to the hello, edits five or more test files. A new service's tests start by copying a Client.

**Direction.** `common::RpcClient { connect_in_process, request(service, json) -> Value, events() }`, with the existing `common::connect_in_process` behind it.

**Size: S-M.** Test churn: about 5 files, all mechanical.

### 8. The libghostty FFI, its safe wrapper and the shadow's policy are one 1,890-line file
**Evidence.**
- `terminal.rs` has 95 of the crate's 229 production `unsafe` tokens.
- Its contents:
  - `mod sys` with the `include!` of the bindgen output (70-79)
  - a PNG decoder installed into libghostty (168-266)
  - placement, history-budget and repaint policy
  - program-status callbacks
  - `impl ShadowTerminal` (718-1824)
- `build.rs` mixes the build number (20-50) with the Zig/bindgen build (54-119), both in the daemon crate.

**Cost.** Anyone changing repaint policy works next to raw pointers. An engine bump (ADR 0061) and a repaint fix touch the same file. The `unsafe` surface cannot be audited on its own.

**Direction.** Put a `ghostty_vt` safe wrapper (types, write, format, callbacks, image access) in its own module, or better its own crate, `crates/ghostty-vt` with the `build.rs` and bindgen. workroomd would depend on it optionally under `terminal-state`. The shadow's policy stays in `terminal.rs`, which would then hold no `unsafe`. This does not contradict ADR 0010: the feature stays off by default, and `shadow.rs` stays the seam.

**Size: M.** Test churn: the terminal tests split between wrapper and policy.

### 9. The terminal service's wire codecs live in the daemon, not in `wr-protocol`
**Evidence.**
- `wr-protocol` says it exists so "anything that speaks to a daemon can link it without the daemon's own dependencies" (`wr-protocol/Cargo.toml` comment). It has frames and envelopes, but the payloads of List, Resize, Retag and Attach are encoded in `serve.rs` (969-1355).
- The in-repo client, `cli/attach.rs` and `cli/list.rs`, has to import `serve` to speak them:
  - `serve::encode_resize` from `attach.rs`
  - `serve::decode_descriptor_list` from `list.rs`
  - `AttachRequest` from `attach.rs` and `tests/remote_transport.rs`
- `wr-protocol` has exactly one consumer, workroomd (grep over `vcs/`).

**Cost.** Small today. But a client-side command like `list` and `attach` cannot be reasoned about without the server module, and every new Control frame (Retag, Signal) puts its codec in `serve.rs`.

**Direction.** Move the codecs into `wr-protocol/src/terminal.rs`, beside `frame.rs`.

**Size: S.** Test churn: the codec tests in `serve.rs` move.

### 10. Stale or narrowed documentation in the Rust tree
- `wr-vcs-git/Cargo.toml:2` says "The original log spike remains a bin". It was deleted in 42986d131 ("refactor: remove code nothing calls", removed `src/main.rs`).
- `workroomd/src/lib.rs:8-9` reads "Phase 1 is the protocol and the terminal service; the VCS, file, status and port-forwarding services are Phase 2". There are now seven services: Status is retired and Layout and ProgramStatus came later. Nothing at the crate root maps services to modules.
- `vcs/Cargo.toml:1`, `AGENTS.md` and `docs/macapp/vcs-and-sessions.md` ("terminal sessions, VCS and File services") all omit Forward, Layout and ProgramStatus.

**Cost.** A new contributor cannot get from `lib.rs` to where a service lives. **Size: S.**

### 11. The `terminal-state` stub costs three edits per new shadow capability (cost note, not a defect)
`shadow.rs:272-341` mirrors every `Shadow` method as a no-op for the build without the feature. Images added six stubs: `visible_images`, `pixels`, `placement`, `hand_off_image`, `at_ground` and `take_disturbed`. Each new shadow method costs an edit in `terminal.rs`, an edit in `shadow.rs`'s feature arm and an edit in its stub arm. CI and `make vcs-lint` / `vcs-test` build both arms.

This is the price of ADR 0010's off-by-default decision, and it is contained well: every one of `session.rs`'s 34 `feature = "terminal-state"` gates is at line 3087 or later, inside tests. I would keep it.

## 2. Dead code and duplication

**Dead code, with proof**
| Item | Proof |
|---|---|
| `Session::pty()` (`workroomd/src/session.rs:260-262`) | rustc `method pty is never used` with modules private, in both feature builds; `grep -rnF '.pty()' src tests` gives 0 hits |
| `vcs/crates/wr-agent/` | an untracked leftover. `git ls-files vcs/crates/wr-agent` gives 0 and `find -type f` gives 0. It holds only empty `.claude/.cc-writes` folders (ignored by `~/.gitignore_global:15`) and an empty `src/wakefulness/`. Safe to `rm -r`. |
| The "spike remains a bin" comment (`wr-vcs-git/Cargo.toml:2`) | 42986d131 removed `wr-vcs-git/src/main.rs` |

**Test-only production API.** This is not dead, but it exists only for tests; see complaint 5 for the list. Nothing in `#[allow(dead_code)]` / `#[allow(unused…)]` hides code in `src`. The only allows are `#[allow(dead_code)] mod common;` in 12 `tests/` files, which is the normal idiom, and the bindgen `mod sys` in `terminal.rs:71-76`.

**Duplication sites**
- **Tree kill:**
  - `vcs.rs:592-632`
  - `cli/run_script.rs:170-187`
  - `session.rs:2400-2458`
  - `wr-vcs-git/src/diff.rs:165-190`
- **Git environment scrub and pins:** `vcs.rs:99-125` and `wr-vcs-git/src/diff.rs:97-115`. They differ by one key, `GIT_EXTERNAL_DIFF`.
- **Bounded pipe drain:** `vcs.rs:420-450` and `wr-vcs-git/src/diff.rs:119-160`.
- **`O_NONBLOCK`:**
  - `serve.rs:145-151`
  - `transport.rs:306-316`
  - `pty.rs:618-626`
  - `wr-vcs-git/src/diff.rs:125-132`
- **Close-on-exec:** `serve.rs:151` inline, against `pty::set_cloexec` (`pty.rs:603`), which `log.rs:235` already reuses.
- **Test JSON clients:** `tests/{file_service:17, forward_service:84, program_status:19, remote_transport:39, status_service:14}`.
- **Test `daemon_binary`:** `tests/common/mod.rs:14`, `tests/cli_contract.rs:12` and `tests/run_script.rs:10` (acknowledged in comments).
- **Not duplication, despite appearances:**
  - `cli/run_supervisor.rs` reuses `run_script::probe_invocation` rather than copying it.
  - The production clients share one handshake, `cli/mod.rs:107` `handshake`.

Already in TODOS (cited, not new): the jj-era wire fields `shared_root`, `barrier_root`, `backend` and `Commit.change_id` (TODOS.md:376-395).

## 3. Proposed target structure (`workroomd/src`)

```
main.rs                 argv → cli::*
lib.rs                  module map: one line per service → module (fixes complaint 10)

daemon/                 Daemon connection context (CONTEXT.md)
  serve.rs              instance lock, freshen, accept loop, idle exit
  connection.rs         handle_connection, greeting, Service → dispatch table
  liveness.rs           Permit/Quiet/ACTIVE, kills-in-flight, file walks left behind, idle wake,
                        accept pause: the one ledger idle-exit and hand-off read
  transport.rs  rpc.rs  handoff.rs  log.rs

terminal/               Terminal context
  dispatch.rs           FrameKind handling taken out of serve.rs::dispatch
  session/              store.rs  attached.rs  reader.rs  terminate.rs  freeze.rs  refusals.rs  tests.rs
  pty.rs  shell.rs  process.rs  input.rs
  shadow.rs             the feature seam (unchanged role)
  vt.rs                 policy half of today's terminal.rs (no unsafe)
  images.rs  screens.rs  run.rs  program_status.rs

vcs/                    Version control context
  service.rs            Service::Vcs dispatch (today's vcs.rs minus exec)
  file.rs  watch.rs

host/                   Remote hosts context
  forward.rs  layout.rs  credential.rs  account.rs
  environment.rs        login-shell probe (from cli/run_script.rs)

exec.rs                 child processes: git env scrub/pins, bounded capture, end_tree, fd flags
cli/                    thin: parse flags, call into the modules above; nothing imports cli/
testing.rs              #[doc(hidden)] re-exports for tests/ (lets everything else be pub(crate))
```

**Dependency direction:** `cli → daemon → {terminal, vcs, host} → exec / shell / rpc`. Nothing points upward into `cli` or `daemon::serve`. `terminal` and `vcs` never import each other.

**Crates.** Keep the four. Optionally add `crates/ghostty-vt` (sys + safe wrapper + bindgen `build.rs`) as the dependency behind `terminal-state`. Move the terminal payload codecs into `wr-protocol`. Do not split services into crates: an incremental build is 1-3 s, and the only shared state is the liveness ledger, which a module boundary contains.

**Ownership.** A terminal owner and a VCS/File owner can work in parallel once `vcs.rs` stops being `file.rs`'s exec library (3, 4) and `serve.rs::dispatch` stops being shared (1). `host/` (forward, layout, credentials) is independent already.

## 4. Things that are good and should stay
- **`unsafe` discipline is lint-enforced** (`undocumented_unsafe_blocks`, the pointer-cast lints, `mem_forget`, `significant_drop_in_scrutinee` in `vcs/Cargo.toml`). The `SAFETY:` counts track the `unsafe` counts per file, and clippy `--all-targets` is clean.
- **The `terminal-state` seam works** as `shadow.rs` claims. In production code the gates are only:
  - `shadow.rs` (11)
  - `handoff.rs:795`
  - `program_status.rs:1035`
  - `images.rs:80`
  - `cli/mod.rs:165`
  - `lib.rs:37`
  
  Everything else is in tests.
- **`cfg(target_os)` is modest** (about 30 sites) and sits mostly in the platform modules: `process.rs`, `pty.rs`, `shell.rs`, `transport.rs`. `session.rs`'s 7 are one Linux run-exit path (1688-1693, 2083-2114).
- **Error handling is consistent apart from poisoning.**
  - Each module has its own `thiserror` enum: `ServeError`, `SessionError`, `RunSignalError`, `HandOffError`, `CredentialError`, `PtyError`, `ProtocolError`, `FrameError`, `VcsError`.
  - Wire errors `FileError` and `LayoutError` are serde enums shaped for the Swift decoder.
  - There is no `anyhow` and no `Box<dyn Error>`.
  - `Result<_, String>` appears only for argv parsing (`cli/serve.rs:206, 237`, `serve.rs:832`).
- **`rpc.rs` is an explicit, documented seam.** Per-connection `PartialRequests` and one admission budget, each with its reasoning written down.
- **Module docs cite ADRs and measurements.** `process.rs`'s platform table and the descendant-snapshot reasoning in `vcs.rs:451-466` are examples of documenting why a design is what it is.
- **wr-vcs-git** keeps gix at `default-features = false` with the reason written down. The `wr-vcs-model` boundary is clean.
- **The black-box CLI contract test** (`tests/cli_contract.rs`) pins what ADR 0057 says must keep the old name.
- **`cli/attach.rs` has no inline tests** but is covered end to end by `tests/attach_*.rs`.

## 5. Open questions for the owner
1. **Is `wr-vcs-model` still worth its own crate?** Its reason, staying free of any VCS library so a binding crate could link it, predates the removal of `wr-vcs-uniffi`, `wr-vcs-core` and `wr-vcs-diff` (ad8eb9d12). Its only two consumers, `wr-vcs-git` and `workroomd`, both link gix. It is harmless at 164 lines; keep it only if a non-gix consumer is planned.
2. **Should `run_bounded` in wr-vcs-git get the setsid-escape kill that `vcs.rs` has?** A read-only `git diff` can spawn hooks and helpers too (fsmonitor, for one). I did not try to reproduce an escape there.
3. **Which poison policy do you want?** Recover everywhere (`into_inner`), or fail the session loudly? Today both are used on the same mutexes.
4. **Should complaints 1 and 6 land as one mechanical refactor PR (module moves only, no logic) before any further terminal feature?** That keeps the diff reviewable as "moved".
5. **Could the test-side Hello loops in seven test files use `cli::handshake` or `common`'s handshake?** I did not check each file's needs; some may test malformed greetings on purpose.

What I could not check:
- The Linux-only build (`make vcs-lint-linux` needs the container).
- Clippy with `terminal-state`: only `cargo check` ran with the feature.
- CI's pinned Rust 1.96.1: every run here used Homebrew cargo 1.99.1.
