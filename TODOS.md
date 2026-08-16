# TODOs

> Grouped by priority, then by area. Within a group, cheaper/higher-leverage first. Each entry states
> what it is, why, how to start, what it depends on, and its priority. Completed work is summarised in
> **Recently done** at the bottom — including the traps found while doing it, which are the parts worth
> reading before touching the same code. Full write-ups for finished items live in git history.

## P1 — before GA

## P2 — perf, correctness, and the next VCS phase

### `workroom-session` daemon: the findings the `/review` pass didn't fix (macapp) — persist-sessions follow-up

**What:** The `workroom-session` daemon (persisted ordinary terminals across quit, `b28e9134`) went
through a two-round `/review` (checklist + specialist dispatch, then a full Claude+Codex adversarial
pass). The three highest-value findings from round two were fixed directly (fallback-socket path
colliding across Workroom/Dev/Nightly builds, an off-by-one in
`PersistentSessionControlClient`'s own `sockaddr_un` length check that was one byte stricter than
the daemon's/attach-client's, and a `closeTab`-initiated kill racing an immediate quit). What's left,
in descending order of how much it matters:

1. ~~**The daemon reports a session as successfully created before `execve` runs.**~~ **FIXED.**
   `SessionPTY.spawn` now uses the classic self-pipe trick: a `CLOEXEC` pipe created before
   `forkpty`, whose write end the child holds open only until `execve` either succeeds (the kernel
   closes it as part of the exec syscall) or fails (the child writes its `errno` and `_exit(127)`s).
   The parent's blocking read on the other end distinguishes the two synchronously — EOF means the
   child reached its shell, any bytes mean it didn't — so `spawn` now returns `nil` on a genuine
   exec failure and `create()`'s existing failure path (which already sent a clean `.failure` frame
   whenever `spawn` returned `nil`) fires instead of acking `.attached` and then closing moments
   later. Red/green-verified: `SessionDaemonEndToEndTests.testExecFailureReportsFailureNotSilentExit`
   (a nonexistent `shell` path forces a real `execve` failure) fails with the detection bypassed and
   passes with it restored, with no regression across the other 197 session/store tests.
2. ~~**No connection-limit or reply-queue bound — a same-UID DoS vector.**~~ **HALF-STALE, now
   FIXED.** The connection-count half was already capped (`maximumConnections = 64`, landed in an
   earlier round of this same review) — this entry hadn't been updated to reflect that. What was
   still genuinely open: protocol replies (`list`/`info`/`attach`/`kill`/`killAll`) are generated
   straight from client requests and aren't covered by the existing `clientOutputLimit` backpressure
   (which only gates output frames sourced from a session's pty), so a same-UID client that kept
   sending requests without ever reading its socket could grow a connection's outbox without bound.
   Fixed with a `connectionOutboxLimit` (8 MB, deliberately above `clientOutputLimit` so a client
   legitimately backed up on real terminal output isn't punished for it) checked after every frame
   processed in `handleConnection`; a connection that crosses it is dropped as misbehaving.
   Red/green-verified: `SessionDaemonEndToEndTests.testMisbehavingClientReplyQueueIsCapped` (a
   session with a bulky metadata title makes each `list` reply large, so a client that floods `list`
   requests without draining its socket crosses the cap in well under a second) fails with the cap
   disabled and passes with it restored.
3. ~~**PID reuse after `waitpid` reaps a session's child.**~~ **FIXED, and the window was real, not
   theoretical.** `reapChildren`'s `waitpid` call REAPS the zombie — releasing its pid back to the
   OS's available pool — before it calls `endSession`, which used to call `closeMaster`, which
   unconditionally sent the session's process group a `SIGHUP`+`SIGCONT` via `SessionPTY.terminate`.
   Any `kill`/`killpg` issued after that reap targets whatever the OS may have already recycled that
   pid to, not the session's shell. The interleaving that triggers it is the ORDINARY case of a
   command that prints trailing output right before exiting: the pty keeps that output buffered
   until it's read, so the master fd doesn't report EOF (the OTHER path into `closeMaster`, which
   runs before `reapChildren` in the same event-loop turn and is therefore always safe — the pid is
   still an unreaped zombie at that point) until after `reapChildren`'s `waitpid` has already reaped
   it. Fixed by threading a `signalProcess` flag through `closeMaster`/`endSession`, defaulting to
   `true` everywhere except `reapChildren`'s call, which already knows — from the `waitpid` that just
   returned this exact pid — that there is nothing left to signal.
   `SessionDaemonEndToEndTests.testNaturalExitWithTrailingOutputReapsCleanly` exercises this precise
   interleaving (trailing output immediately before exit) end to end and pins the outcome: correct
   exit status delivered, session cleanly removed. It can't assert the skipped signal directly —
   nothing in the protocol surfaces that — so treat the code review (the vulnerable call site is
   simply gone from the reap path) as the other half of the verification, the same way other latent
   races in this file are closed by reasoning plus a behavioral pin rather than a flaky repro.
4. ~~**`SessionDescriptor.decodeList`'s wire encoding has no cap relative to `SessionFrame`'s max
   frame size.**~~ **FIXED, and the failure mode was worse than "fails somehow."** A `list`/`info`
   reply's size grows with both session count (up to `maximumSessions`) and each session's
   client-supplied metadata, but unlike `.output` (chunked across frames by `enqueueReplay`) it's a
   single frame that `SessionControlClient.list` expects to decode whole. An oversized one wouldn't
   just fail to decode — `SessionFrameDecoder.next()` permanently fails ANY reader the instant it
   sees a declared length past `SessionFrame.maximumPayloadSize`, poisoning that connection for
   every frame after. New `enqueueSessionList` checks the encoded payload against
   `maximumPayloadSize` before ever building the frame and sends a `.failure` reply instead —
   `SessionControlClient.list`'s existing `guard frame.kind == .sessions else { return nil }` already
   treats any non-`.sessions` reply the same as a timeout, so no client-side change was needed.
   Red/green-verified: `SessionDaemonEndToEndTests.testOversizedSessionListRepliesWithFailureNotAMalformedFrame`
   (six sessions with a bulky metadata title, each individually well under the frame cap but
   summing past it) reproduces the exact poisoning — `frameTooLarge(1200592)` — with the guard
   disabled, and gets a clean `.failure` with it restored.
5. ~~**`setsid()`-spawned children can fork their own descendants that escape the daemon's forced
   cleanup.**~~ **FIXED, and the first attempt exposed a second, sharper bug.** `killpg` (the soft
   `terminate()` used by `closeMaster`) and the old `getsid`-based matching (`forceTerminate`) both
   scope by session/group, so a deliberately double-forking/re-`setsid`'d grandchild — now the
   leader of a session nothing was tracking — escaped both. Fixed with a one-time, upfront
   parent-pid tree walk (`SessionPTY.descendantProcessIDs`, sharing a `snapshotProcesses()` scan
   with the existing `sessionProcessIDs`): every transitive descendant of the root pid is tracked
   as its own additional signal target, found by ancestry rather than by whatever
   session/group it has since made itself leader of.
   **What the first version of this fix missed, caught by the regression test itself:** `endSession`/
   `endSessions` call `closeMaster` (the soft `killpg`+`SIGHUP`) BEFORE `forceTerminate` — and SIGHUP's
   default disposition is terminate, so that soft signal was reliably killing the session's shell
   moments before `forceTerminate`'s own tree-walk snapshot ran, reparenting the detached grandchild to
   launchd and erasing the very parent-pid link the walk depends on. The real fix needed the snapshot to
   happen before ANY signal in the sequence, not just before the hard one — `closeMaster` now takes a
   `signalProcess` flag (added for the PID-reuse fix above) and both force-path callers suppress the
   soft signal, since `forceTerminate` immediately following is both more thorough and (with this fix)
   the thing that actually needs to see the tree intact.
   Red/green-verified with a REAL detached grandchild, not a simulation:
   `SessionDaemonEndToEndTests.testKillAllReachesASetsidGrandchild` spawns a shell that backgrounds a
   perl process calling `setsid()`, confirms it's alive from outside the daemon, sends `.killAll`, and
   asserts the grandchild's pid is actually gone. Fails (reproducing survival) with either half of the
   fix reverted on its own, passes with both restored.
6. **`TerminalSessions.assignedSessionID`'s `isQuickTerminal` parameter is dead.** No caller passes
   `true` for it any more (the quick-terminal exclusion is handled elsewhere in
   `TerminalPersistentSessionPolicy` now) — cosmetic, but confusing for the next reader trying to
   figure out which layer actually excludes quick terminals.

**P0 architectural note, accepted as-is (not a bug for this PR):** the daemon's only authentication
is `LOCAL_PEERCRED`/`peerUserID == getuid()` — any process running as the same user can list/attach/
kill any of that user's persisted sessions across every open project. This is the same threat model
tmux and screen have always had (a same-user socket is inherently shared trust), not a regression
this feature introduces, and items 1-3 above assume that same boundary rather than trying to harden
past it.

**Why:** Residue of a two-round review (checklist + specialist dispatch, then Claude+Codex
adversarial) on a brand-new always-on daemon that every persisted terminal now depends on. None of
these are exploitable beyond the accepted same-UID trust boundary, and none causes silent data loss
in the common path — they're edge cases (process launch races, resource exhaustion, PID reuse
windows, an encoding ceiling, escaping cleanup, dead code) that are real but lower-value than the
three fixed directly.

**Priority:** P2. (1)-(5) are fixed (see above) — what remains is (6), cosmetic dead code, not a bug.

### Bump the libghostty pin (macapp) — SHIPPED, 2026-08-13

**Landed 2026-08-13** across four commits: `2e37b446` (doc hygiene), `0f11f479` (pre-bump QA
baseline), `e6f926a3` (the pin bump + resources + tests), `b338c737` (the new orphan-shell XCUITest).
Full before/after numbers in `macapp/QA-libghostty-results/2026-08-12-libghostty-1.3.2-bump.md`.
**Headline result: the `free_text` leak below is CONFIRMED FIXED** — an isolated repro (300
accessibility reads, `leaks` before/after) went from 299 leaks / 38272 bytes on the old pin to
**0 leaks** on the new one. No regressions found in surface/split churn, backspace, ⌃Tab,
`$TERM`/infocmp, the orphan-shell teardown path (now a permanent XCUITest, see below), or the two
`GhosttyActionDispatchUITests`. Everything below this point in the entry describes the WORK DONE to
get here; kept as the historical record rather than rewritten, per this repo's usual practice of
correcting claims in place rather than deleting the trail.

**What did NOT get verified, filed as its own follow-up** (see "Automate the rest of §N's IO-layer
checklist" below): workroom switch/delete and OSC 7 (blocked on a real mouse — synthetic `AXPress`/
`click at` didn't register on these specific custom SwiftUI controls in an external-AppleScript
driving session), and the terminfo `Se` capability's cursor-style-reset behavior change (`\E[2 q` →
`\E[0 q`, found during the resource regen below) — attempted via screen capture, abandoned when
`screencapture -x` grabbed the whole display instead of the target window.

**GA-gate removed (2026-08-12):** this entry originally read "post-GA, first change after the GA
tag" and gated on GA shipping. That gate has been explicitly lifted — the repo is still at
`v2.0.0-beta.24`, no `v2.0.0` tag exists, and the bump is proceeding ahead of it. See the execution
plan for the full phased breakdown, cross-model review, and task list.

**What:** move `macapp/project.yml` from the currently pinned `libghostty-spm` package to **1.3.2**
(ghostty commit `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`). Those two numbers are this task's
TARGET, not a claim about what ships — for what is pinned today, read `project.yml`'s comment, which
is the single source of truth. Re-check the target against the packager's newest release before
starting; it moves.

**Why:** it is the only way to reach `ghostty_surface_foreground_pid` + `ghostty_surface_tty_name`
(the "libghostty exposes no PTY child PID" limitation CMT-1 records at `GhosttySurfaceView.swift:95`)
and `GHOSTTY_ACTION_SELECTION_CHANGED` (CMT-3's a11y hook), plus ~1300 upstream commits. **It ships
no user-visible change by itself** — both wins need separate work to wire — which is exactly why it
waits for GA rather than riding under it.

**The version trap that produced two wrong roadmap entries — read this first.** `libghostty-spm`
versions its **package** independently of ghostty. The release bodies state the ghostty ref
explicitly, and package `1.2.3` is built from ghostty **`v1.3.1`**. Reading a package version as a
ghostty version is what made an earlier CMT-2 claim we trailed ghostty by ~2 versions and file it as
P1. Package `1.3.1` ≠ ghostty `v1.3.1`. Always read `Ghostty.ref` + the release body, never the tag.

**Scope check (2026-08-12):** we link only the raw `GhosttyKit` C-API product (`project.yml`'s
`libghostty` target) — not the wrapper's own Swift `TerminalSurface`/`TerminalView` convenience
layer. Every wrapper-side Swift PR between our pin and 1.3.2 (AppKit copy-path change, async
host-managed output queuing, prompt navigation, per-surface env vars, scrollbar delegate) touches
types we don't consume and is out of scope for this bump. Whether we *should* start consuming that
layer is a separate, open question — see "Own the GhosttyKit xcframework" below for the supply-chain
angle; the API-surface angle is undecided and not yet filed.

**The real risk is the patch swap, not the API.** The packager applies its own patches to ghostty
before building, and `Script/apply-patches.sh` feature-probes the header to choose between them:

```
  grep -q "ghostty_surface_foreground_pid" include/ghostty.h
      │
      ├── absent  (ghostty v1.3.1 — what we ship today)
      │     └── 0002-host-managed-io.patch          (17,588 B)
      │
      └── present (ghostty 35e1a016 — package 1.3.2)
            └── 0002-host-managed-io-modern.patch   (18,447 B)   ← never run here
                                                                    PTY/IO hosting: surface teardown,
                                                                    orphan shells, the EXC_BAD_ACCESS
                                                                    site WorkroomApp.swift:665-678 documents
```

By contrast the mid-enum `GHOSTTY_ACTION_SELECTION_CHANGED` insert — which renumbers 14 following
tags including `SHOW_CHILD_EXITED` and `COMMAND_FINISHED` — is **not** a risk: header and static
archive ship together, `GhosttyRuntimeAdapter.handleAction` dispatches on symbolic labels, and
nothing persists a raw tag. Don't spend the retest budget there. (Don't write a test asserting a
tag's raw value either — test and app import the same header, so it can never fail.)

**Full `include/ghostty.h` diff swept (2026-08-12, `332b2aef` → `35e1a016`) — two real C-ABI
removals found, both confirmed unused:** `ghostty_app_key_is_binding()` is gone (moved to
`ghostty_config_key_is_binding`); the `translated` field is gone from `ghostty_input_trigger_u`.
Grepped `WorkroomApp*` for both — zero call sites, zero `.translated` reads; we only ever call
`ghostty_surface_key_is_binding` (surface-level, untouched), so neither removal costs anything.
Also confirmed: upstream's OSC 9;4 progress-report expansion (PR #13483) is **not** in this pin —
it merged 2026-07-27, three weeks after `35e1a016`'s actual commit date (2026-07-10), so don't
expect it from this bump.

**Re-swept as a full unified `diff -u` this time (2026-08-12, not just a symbol-grep) — clean,
nothing beyond the above.** Every existing function signature we call is byte-identical (same
params, same return type); the only structural change anywhere in the header is the one union-field
removal above, and it was same-type/same-size with the field that survives (`physical`), so it was
never a layout risk even for someone still calling it. New in this header: a `GHOSTTY_API` symbol-
visibility macro on every declaration (resolves to `__attribute__((visibility("default")))` on our
Clang/macOS static-archive build since we never define `GHOSTTY_STATIC` — inert for a statically-
linked consumer, this is for making the same header serve shared-lib builds too) and
`GHOSTTY_IPC_ACTION_TOGGLE_QUICK_TERMINAL` appended to `ghostty_ipc_action_tag_e` — grepped, zero
usage of that enum anywhere in `WorkroomApp*`. No thread-affinity/ownership signal is expressible in
a C header at all (that needs a Zig source diff, explicitly out of scope — see "Bump the libghostty
pin" plan's Failure-modes decision to leave this check one-time, not permanent).

**Two more upstream fixes for the retest budget, on top of the patch-swap risk above — both
confirmed, not assumed:**
- ~~`ghostty_surface_free_text` was silently not freeing memory~~ **CONFIRMED FIXED.** Isolated
  before/after leak check (300 accessibility reads through `extractString`/`read_text`, `leaks`
  before and after): 299 leaks / 38272 bytes on the old pin → **0 leaks** on the new one. The
  headline result of this whole bump — see the QA results file for the exact reproduction.
- A crash fix: `mouseButtonCallback` raced the I/O thread's scrollback pruning without the renderer
  mutex on link clicks (use-after-free). Add "select/click text while scrollback is actively
  producing output" to the IO-layer retest below. `SelectionGesture` was also rewritten internally
  (same public surface) — retest drag/click-threshold edges while there.

**Blocking work, same commit:**
- ~~**Decide the `ghostty +ssh` question.**~~ **DONE, ahead of this bump.**
  `Contents/MacOS/ghostty` is now a relative symlink to the app binary, and `main.swift` dispatches
  Ghostty's `+action` CLI on `argv[0]` — libghostty already carried the whole action set, so no
  second binary and no Zig toolchain were needed. `GHOSTTY_BIN_DIR` turned out to be set by the
  engine all along (from the running executable's directory); the directory simply had no `ghostty`
  in it. Full correction in `Resources/ghostty/SOURCE.md`. **Regenerating `shell-integration/` is
  now safe — but only with or after this bump**, never before it: `+ssh` does not exist at the
  pinned v1.3.1 and arrives at the bump target.
- ~~**Test `+ssh` itself, not just `+ssh-cache`.**~~ **DONE.** `GhosttyCLITests.testGhosttySshHelpDispatches`
  (exit 0 + real help text) plus three tests against a stub `ssh` on `PATH` that prove the
  regenerated shell-integration wrapper itself translates `GHOSTTY_SHELL_FEATURES` into the right
  `--forward-env`/`--terminfo` flags — without a real network round-trip. **The real-host SSH
  integration test stayed explicitly deferred** (Codex cross-model tension 7's accepted middle
  ground: the fake-ssh test closes most of the risk at a fraction of the infrastructure cost) — filed
  as its own decision in the execution plan, not silently dropped.
- ~~**Regenerate `macapp/Resources/ghostty/`**~~ **DONE**, and it was NOT a no-op the way "ahead of
  the engine" implied: a source diff of `src/terminfo/ghostty.zig` between the two engine commits
  found the `Se` (cursor-style-reset) capability actually changed (`\E[2 q` → `\E[0 q`) — regenerated
  via `infocmp`/`tic`, not assumed unchanged. `shell-integration/` is now copied straight from the
  pinned commit instead of carrying a separate ahead-of-engine snapshot. Full detail in
  `Resources/ghostty/SOURCE.md`.
- ~~**Resolve `TerminalSearch.navigationPlan`.**~~ **Checked, no change needed.** The manual ⌘F
  retest (below) showed the match counter still counts up exactly as before — no drift in direction
  or wrap semantics detected, so the existing inversion/wrap-synthesis logic is still correct at this
  pin. (On-screen highlight direction wasn't independently re-verified — see the QA results file.)

**Retest the IO layer, not the enum: DONE**, partially via a new permanent XCUITest
(`GhosttyOrphanShellUITests.testNormalQuitLeavesNoOrphanedShell`, replacing the `ps`-name-grep
approach with a marker + heartbeat-file design — `ps` itself turned out to throw `EPERM` from inside
an XCUITest runner, a real platform constraint worth knowing for any future test in this style) and
partially via manual retest (surface/split churn, backspace, ⌃Tab, `$TERM`/infocmp — see the results
file). Workroom switch/delete and the scrollbar overlay were NOT re-verified — filed below.

**Also required:**
- **A universal Release build before landing.** ~~CI only ever builds Debug/arm64, so the first
  universal link happens at release time.~~ **That was wrong** — `nightly.yml` has run
  `make app-release` (universal Rust core + `ARCHS_STANDARD` Release) daily since it landed. What
  was actually missing was an *assertion*, which now exists: `release.sh` refuses to notarize a
  bundle containing any thin Mach-O. So the bump inherits a daily universal build plus a gate; run
  one locally only if you want the signal before pushing:
  `VCS_APPLE_FLAGS=--universal make app-vcs`, then
  `xcodebuild -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build`.
- **A bake gate.** `nightly.yml` builds daily from master, so this reaches nightly users ~24h after
  landing. Require N clean nightlies before it enters a `pre` tag. **Still open** — landing this
  commit doesn't itself decide N; that's a separate call at promotion time.
- ~~**A `QA-libghostty.md` §N "engine bump smoke"** (~12 items).~~ **Stale claim, corrected
  2026-08-12: it already exists.** `QA-libghostty.md:137-216` has a full §N with 4 subsections and
  ~20 checkbox items (IO layer/patch-swap, behaviour keyed to engine internals, resource contract,
  build shapes CI doesn't cover). Its own preamble requires running it against the *current* engine
  first as a baseline — a baseline taken after the bump is worthless. Extend it, don't recreate it.
- ~~**Retest the GhosttyKit modulemap-collision workaround.**~~ **DONE — still holds.** The Debug
  build (T4) compiled clean against the 1.3.2 xcframework with no "Multiple commands produce
  include/module.modulemap" error, so the library-only-xcframework + separate-C-target workaround
  (`macapp/CLAUDE.md:120-124`) needed no changes.

**Rollback is not one line:** revert the commit(s), `rm -rf macapp/DerivedData/SourcePackages`,
rebuild. CI's `spm-`/`xcbuild-` caches key on `project.yml` and their `restore-keys` fallback can
restore a mixed state. Do **not** remove any workaround (backspace DEL-as-text, ⌃Tab) until this has
baked — both fail safe, and the backspace test passes either way, so removal needs a raw-PTY probe.

**Depends on:** nothing — landed. `Package.resolved` is tracked, so the resolved revision is a
reviewable diff, and `GhosttyPinIntegrityTests` asserts it matches `b146b73a...` permanently (fails
loudly if the packager ever re-cuts the `1.3.2` tag).

**Priority:** P2 — real value, no user-visible gain on its own, and it swaps the layer that runs the
user's shell. SHIPPED; watching the bake gate and the residual gaps filed below before promoting to
a `pre` tag.

### Automate the rest of §N's IO-layer checklist (macapp) — libghostty-bump follow-up, filed 2026-08-13

**What:** the 1.3.2 bump (above) added exactly one automated tripwire
(`GhosttyOrphanShellUITests.testNormalQuitLeavesNoOrphanedShell`) for `QA-libghostty.md` §N's
IO-layer subsection. Everything else in §N — surface/split churn volume, workroom switch, workroom
delete, force-quit variant, the scrollbar overlay — is still manual-only, exactly as it was before
this bump. That gap isn't new; it's just now visible with a name, having been walked end-to-end this
session rather than assumed.

**Two concrete blockers surfaced while running the manual retest, worth fixing before the next
attempt at automating this, not just re-discovering them again:**
- **Workroom-tab chips and the run-command button (`workroom.tab.*`, `runCommand.run`) didn't respond
  to synthetic `AXPress` or a raw `click at {x,y}` from an external AppleScript-driven session** —
  0 observable effect despite the action reporting success and the on-screen bounds being correct.
  Real keyboard shortcuts (⌘R/⇧⌘R) and raw `keystroke` text input worked fine throughout, which is
  how the QA results file's Run-tab and behavioral checks actually got driven. `GhosttyOrphanShellUITests`
  and `GhosttyActionDispatchUITests` prove an actual XCUITest host process (not external AppleScript)
  CAN drive these controls — `focusTerminal`'s tab-chip click works there. So the fix for
  workroom-switch/delete/OSC-7 automation is likely "write it as a real XCUITest," not "find the
  right AppleScript incantation."
- **`Process()` spawning `/bin/ps` (or presumably anything) throws `NSPOSIXErrorDomain Code=1
  "Operation not permitted"` from inside an XCUITest runner** (`WorkroomAppUITests`'s auto-generated
  `XCTRunner` host is sandboxed against subprocess spawning; the app under test itself is not — two
  different sandbox realms). `GhosttyOrphanShellUITests` worked around this with a heartbeat FILE
  (`/tmp`, not `NSTemporaryDirectory()` — see that file's doc comment for why `NSTemporaryDirectory()`
  resolves to a different, container-private path in the runner vs. the app) instead of polling `ps`.
  Any future XCUITest needing to observe OS-level process state should reuse that pattern rather than
  rediscovering the `ps` restriction.

**Also unverified, not automated, and not re-attempted manually either — flag before assuming
fine:** the terminfo `Se` capability's cursor-style-reset behavior change (`\E[2 q` → `\E[0 q`, found
during the bump's resource regen) has never been visually confirmed. A `screencapture -x` attempt at
this was abandoned mid-session when it turned out to capture the whole display rather than the
target window (see the bump entry above) — needs either a window-scoped capture API or a human at
the keyboard, not screen-wide automation.

**Sharper target for whoever runs this, found while surveying the wider `332b2aef...35e1a016`
upstream range (not just the diff of the terminfo file itself):** the `Se` change isn't a one-time
fixed-escape swap. It was refined again after `\E[2 q`→`\E[0 q` — `Se` now restores whatever cursor
style/blink the engine is *configured* with, paired with new default-cursor-style/blink options
(ghostty `c19ce03b`, `42fcd58d`; both confirmed ancestors of our pinned `35e1a016`). So the right
check is "does resetting after a TUI exit return to Workroom's actual configured default," not
merely "does it emit `\E[0 q`" — a literal-escape assertion could pass while the dynamic-default
behavior is still unverified.

**Depends on:** nothing blocking — can start anytime. The two platform-constraint findings above
mean whoever picks this up should design as a real XCUITest from the start, not attempt external
AppleScript driving again.

**Priority:** P3 — the manual checklist still covers this; nothing is unguarded, just unautomated.

### Wire native `selection_changed` notification (macapp) — CMT-3 follow-up, unblocked by the pin bump, filed 2026-08-14

**What:** `GhosttySurfaceView.startAccessibilityPolling`/`pollAccessibilityContent`
(`GhosttySurfaceView.swift:990-1014`) drive VoiceOver's `.valueChanged`/`.selectedTextChanged` off a
400ms `Timer`, gated cheaply on `NSWorkspace.shared.isVoiceOverEnabled` checked first each tick. The
comment justifying the poll (lines 984-989) says libghostty has no per-frame content-changed callback
to hook instead — true when CMT-3 shipped (2026-08-10), on the pre-bump engine. **Confirmed stale
today** against the currently-linked header
(`DerivedData/Build/Products/Debug/include/libghostty/ghostty.h:953`):
`GHOSTTY_ACTION_SELECTION_CHANGED` exists on this exact pin, and `GhosttyRuntimeAdapter`'s action
switch (`GhosttyRuntimeAdapter.swift:25-126`, `default:` fallback at 127) has no case for it — grepped,
zero matches for `SELECTION_CHANGED` anywhere in `WorkroomApp` outside the vendored header.

**Why:** replaces a 400ms poll with an engine-pushed event for the selection half of the a11y signal.
Selection changes get announced immediately instead of up to 400ms late, and the poll's
`readSelectionText()` call (the actual per-tick cost) only runs when the engine says something
changed, instead of unconditionally on every tick while VoiceOver is on. The `.valueChanged` side
(screen content) has no native hook in this action set and keeps polling — this only replaces the
selection half, exactly as the original CMT-3 entry anticipated ("after the pin bump it comes from the
engine as `GHOSTTY_ACTION_SELECTION_CHANGED`").

**How to start:** the action carries no payload — checked the header's `ghostty_action_u` union, it has
no `selection_changed` field, so it's a bare tag. Add a `case GHOSTTY_ACTION_SELECTION_CHANGED:` to
`GhosttyRuntimeAdapter.handleAction` that resolves the view via `surfaceView(from: target)` and calls a
new `view.handleSelectionChanged()` doing what `pollAccessibilityContent` already does for the
selection half: `readSelectionText()`, diff against `lastAccessibilitySelectedText`, post
`.selectedTextChanged` on change. Leave the poll running for `.valueChanged` until/unless a
render-changed action shows up too.

**Depends on:** nothing — the pin bump already landed (2026-08-13) and the header confirms the action
tag exists on this exact linked build.

**Priority:** P3 — no user-visible regression today (the poll works correctly), but it's a small,
scoped cleanup the bump specifically unblocked, and the original CMT-3 entry already named it as the
reason to revisit.

### `ghostty_surface_tty_name` is available and unused (macapp) — filed 2026-08-14

**What:** the pin bump also exposes `ghostty_surface_tty_name` (confirmed in the currently-linked
header, `ghostty.h:1138`, right next to `ghostty_surface_foreground_pid` at `:1137` — which we DO
already consume, for agent-backend recognition at `GhosttySurfaceView.swift:41`). `tty_name` has zero
call sites anywhere in `WorkroomApp` (grepped).

**Why it might matter:** session-daemon reattach and orphan-shell detection currently identify a pane's
process by foreground-pgid + argv0 heuristics. A tty name is a firmer, OS-level identity than a pgid
snapshot taken at one point in time — worth a look if a future reattach/process-matching bug turns out
to need sturdier identity than pgid gives. Not chasing a known bug today; this is "available primitive,
nobody has looked at it yet," filed so it isn't rediscovered from scratch.

**Depends on:** nothing.

**Priority:** P3 — no known bug this fixes today.

### Own the GhosttyKit xcframework (macapp) — CMT-2, GA-time supply-chain decision

**What:** stop depending on the third-party `libghostty-spm` (Lakr233) package as the source of
truth. Build our own universal `GhosttyKit.xcframework` + version-matched resources from a ghostty
ref *we* pin, and point `project.yml` at it.

**Status: demoted from P1, and re-argued.** Two of the three rationales this entry used to carry were
wrong, and are struck:

- ~~"We trail ghostty by ~2 versions"~~ — a **package-vs-ghostty version confusion**; see the trap
  described in the pin-bump entry above. We have been on ghostty's newest *release* the whole time.
- ~~"Only owning the pin can reach OSC 99"~~ — **a fork cannot deliver OSC 99 either.** See the OSC 99
  entry under Notifications for the upstream state; the short version is that the open parser PR
  routes the command into an "unimplemented → discard" branch, and the pieces that would make it
  reach an embedder do not exist as PRs at all.

**What survives, and it is the whole argument: supply chain.** The shipped binary is **not stock
ghostty**. `Patches/ghostty/` carries 11 patches (~200 KB, including a 113 KB prebuilt-framedata
patch and the ~18 KB host-managed-IO patch that rewrites PTY hosting), applied at build time by a
single maintainer. The artifact is checksummed by SPM but **not signed or notarized** — unlike
ghostty-org, which minisigns its own `ghostty-vt` artifacts. We link that into a notarized app, in
the component that runs the user's shell. Slice composition churns too: arm64e slices shipped
2026-07-21 and were reverted three days later, re-cutting an already-published tag.

**And the lag concern is real — for a mechanism the old entry never identified.** The packager does
**not** track ghostty. `.github/workflows/build.yml` reads its ghostty commit from a hand-maintained
`Ghostty.ref` file (regex-validated as a 40-char sha), and the weekly cron never queries ghostty at
all — it bumps the package's own patch number and bails with `"main matches package tag …, skipping
scheduled release"` when the package repo hasn't moved. Release-tag auto-detection existed up to
package 1.2.9 and was **removed**. Five package releases in 17 days all shipped one engine. So when
ghostty ships 1.4.0, nothing pulls it until one person edits a file.

**Measured, not hypothetical (2026-08-14):** `ghostty-org/ghostty`'s own `main` is **652 commits
ahead** of our pinned `35e1a016` (last moved 2026-07-10) — over a month of drift already, and
counting. `libghostty-spm` has cut nothing since `1.3.2` (2026-07-27); its own `main` last moved
2026-08-06 and is still building that same engine ref. Not urgent — nothing we need today is stuck
behind it — but this is now a live, growing number, not a someday-risk.

**How to start:** clone `ghostty-org/ghostty` at the chosen ref, decide deliberately which of the 11
patches to carry (`0002-host-managed-io*` is load-bearing for embedding; the iOS/Catalyst ones are
not ours), and regenerate `terminfo`/`shell-integration` from that same ref. Vendor the xcframework +
a 2-file C shim, or host it as a release artifact in a separate repo's CI. Zig is needed only to
*build*, not to *consume*. Signing is unchanged (a static archive in the main executable, no new
framework to sign). **The build mechanics themselves are cheaper than "reuse the packager's tooling"
implies** — see "Build path for owning GhosttyKit.xcframework" below.

**Depends on:** nothing in-app. Best decided once GA has shipped and the pin bump has baked, since
owning the pin means owning the patch decisions above.

**Priority:** P3 — a real supply-chain posture question with no feature blocked behind it. Revisit at
GA, or the first time the hand-maintained `Ghostty.ref` leaves us stranded on an engine we need to
move off.

### Build path for owning GhosttyKit.xcframework (macapp) — CMT-2 finding, checked 2026-08-12

**What:** if/when CMT-2 (above) is actioned, the build mechanics are cheaper than "reuse the
packager's tooling" suggests. `ghostty-org/ghostty`'s own `build.zig` has first-class
`-Demit-xcframework` machinery (`src/build/{Config,XCFrameworkStep,LipoStep,GhosttyXCFramework}.zig`)
— it's what builds `GhosttyKit.xcframework` for **ghostty-org's own** macOS app
(`macos/Ghostty.xcodeproj` links that exact framework). `-Demit-xcframework -Dapp-runtime=none` is
the official surface, confirmed in `Config.zig`'s option defaults; it isn't a reverse-engineered
path, it's the same one ghostty-org's own Mac build uses.

**Why it's cheaper than assumed:** the packager's `Script/build-ghostty.sh` +
hand-rolled `merge-xcframework.sh` reimplement a slice of that official machinery because their CI
matrix targets 7 slices (macOS × iOS × iOS-sim × Catalyst, for *their* downstream reach — Workroom
doesn't need any of that). We only ship macOS — 2 slices (`aarch64-macos`, `x86_64-macos`) — so
`-Dxcframework-target=universal` should drive Zig's own `LipoStep`/`XCFrameworkStep` to assemble the
universal xcframework directly in one invocation, with no custom lipo script needed.

**What this doesn't solve:** patch curation is still fully on us. `Patches/ghostty/` carries 11
patches (~200 KB); `0002-host-managed-io*` is load-bearing for embedding, the iOS/Catalyst ones are
not ours to carry. Self-building doesn't remove that decision, it just makes it ours instead of
inherited from Lakr233 — that's the real ongoing cost of CMT-2, not the build mechanics this entry
is about.

**Depends on:** CMT-2 actually being actioned — this is a build-path finding for that entry, not an
independent task.

**Priority:** P3 — same gating as CMT-2; irrelevant unless/until that entry is executed.

### Evaluate adopting `AppTerminalView` for action-dispatch plumbing (macapp) — reviewed 2026-08-12, not now

**What:** `libghostty-spm` ships more than the raw `GhosttyKit` C-API product we link — a Swift
convenience layer (`Sources/GhosttyTerminal`) with a cross-platform `AppTerminalView`
(AppKit)/`UITerminalView` (UIKit) pair, a `TerminalSurfaceCoordinator`/`TerminalController`, and a
typed delegate family (`TerminalSurfaceTitleDelegate`, `...ResizeDelegate`, `...FocusDelegate`,
`...BellDelegate`, `...ScrollbarDelegate`, `...ProgressReportDelegate`,
`...CommandFinishedDelegate`, `...OpenURLDelegate`, `...HoverLinkDelegate`, `...PwdDelegate`,
`...LifecycleDelegate`, etc.). We use none of it — `GhosttySurfaceView.swift` is our own 2001-line
`NSView` subclass calling `ghostty_surface_config_new()` and the rest of the raw C API directly, with
our own `GhosttyRuntimeAdapter` doing the `GHOSTTY_ACTION_*` switch by hand.

**Checked, not assumed:** `AppTerminalView` is `open class: NSView` (not sealed), and every
input override in `AppTerminalView+Input.swift` (`keyDown`, `mouseDown`, `rightMouseDown`,
`scrollWheel`, `performKeyEquivalent`, …) is itself `override open`, so a subclass in our module
genuinely can override further and call `super`. This is a real, thoughtfully-designed extension
point, not a rebrand of a black box — worth recording so this doesn't get re-litigated on a
surface-level "it's probably sealed" guess.

**Why not now anyway:**
- **It would bundle a UI-layer rewrite with the IO-layer risk the pin bump already carries.**
  Adopting the delegate surface means adopting the coordinator/controller layer underneath it too,
  which is exactly where the packager's `0002-host-managed-io*` patch swap lives (see the pin-bump
  entry above). Evaluating two unknowns — a new engine *and* a new plumbing layer — at once defeats
  the point of bumping the pin first and baking it.
- **Migration cost is real, not mechanical.** `GhosttySurfaceView.swift` encodes ~15-20 documented,
  empirically-discovered AppKit fixes (several **real-mouse-only** — synthetic/XCUITest clicks pass
  on the buggy code, so they can't be regression-tested by CI alone): `.textSelection(.enabled)`
  swallowing real mouseDown, the ⌘-key routing through `AppDelegate`'s monitor rather than
  `event.window`, DECSET-1004 focus reporting via `ghostty_app_set_focus` + window-key handling, the
  backspace-DEL-as-text and ⌃Tab workarounds, mask+contentShape hit-testing during scroll. `open`
  subclassing means each of these is *portable in principle*, but re-deriving exactly where each one
  hooks into `TerminalKeyEventHandler`/`TerminalSurfaceCoordinator` internals we didn't write is
  rediscovery work, not a mechanical port — and several of these fixes have no delegate hook at all
  (they're not events `AppTerminalView` surfaces, they're workarounds for how SwiftUI/AppKit deliver
  events to *any* view underneath them).
- **No pin-bump goal needs it.** `ghostty_surface_foreground_pid`/`ttyName` and
  `GHOSTTY_ACTION_SELECTION_CHANGED` are both reachable through the raw C API we already call —
  adopting the Swift layer buys nothing for CMT-1/CMT-3.
- **It deepens exactly the coupling CMT-2 (above) is questioning.** Consuming more of a
  single-maintainer package's Swift surface, while a neighboring entry is asking whether to stop
  depending on that same package altogether, is the wrong direction until CMT-2 is resolved.

**What it could buy, if revisited later:** the delegate family plausibly replaces a chunk of
`GhosttyRuntimeAdapter`'s hand-rolled `GHOSTTY_ACTION_*` switch (title/resize/bell/scrollbar/
progress-report/command-finished are all typed callbacks instead of a raw tag switch) — but that's
an argument for adopting the **dispatch layer only**, not for replacing our own input/mouse/keyboard
handling, which is where nearly all the hard-won fixes live.

**Depends on:** the pin bump landing and baking first (see above), and CMT-2's supply-chain question
being settled — no point deepening coupling to a dependency we might drop.

**Priority:** P3 — no feature blocked behind it, reviewed and consciously deferred rather than
unconsidered.

### Finish the action-dispatch UI coverage (macapp) — search counters

**What:** add the `SEARCH_TOTAL` / `SEARCH_SELECTED` case to
`WorkroomAppUITests/GhosttyActionDispatchUITests.swift`. The other two visible tags (`SET_TITLE`,
`PROGRESS_REPORT`) are covered and green; this one was attempted, hit a wall, and was parked rather
than left as a failing test.

**Why:** the scrollback find bar's "n/N" counter is the only surface for those two actions, so
without it they have no automated detector — the same gap the rest of that file exists to close, and
it matters most when the engine is bumped.

**It is also the pin bump's missing tripwire.** `TerminalSearch.navigationPlan` encodes three
*engine* assumptions — `navigate_search:next` steps newest→oldest, the engine never wraps, and index
0 is the bottom-most match — and none is observable without driving a real search. If any moved
upstream, ⌘G becomes silently **wrong** (walks the wrong way, or stops dead at an end) rather than
merely redundant, and `TerminalSearchTests` cannot see it: those cover the pure fold, which stays
self-consistent against a changed engine. Until this lands, the only detector is manual —
`QA-libghostty.md` §N, "⌘F wrap + ordering". Once the fixture seam below exists, assert direction and
wrap against a seeded scrollback and the tripwire is automatic.

**What is already known (do not re-derive):**
- The bar DOES open under XCUITest from **`Edit ▸ Find…`** (`app.menuBars.menuBarItems["Edit"]
  .menuItems["Find…"].click()`). The menu item is `exists=true enabled=true hittable=true` while a
  terminal is focused — measured. `app.typeKey("f", modifierFlags: .command)` does NOT work: the
  focused terminal consumes the keystroke, exactly as `RunStatusUITests` documents for the Run button.
- Assert bar-open on the **text field** (`app.textFields.firstMatch`), NOT on the match summary:
  `TerminalSearchModel.matchSummary` is `""` until a needle is set, and an empty SwiftUI `Text`
  produces no accessibility element at all, so waiting on it waits forever while the bar is up.
- **The wall:** the needle never reaches the field. Both `app.typeText` and element-scoped
  `field.typeText` leave the summary at its empty-needle state (`""` — distinguishable from a real
  no-match, which renders "No results"). So `model.needle` is not being set. The field is a SwiftUI
  `TextField` with `.focused($fieldFocused)` and a deferred `onAppear` focus grab
  (`TerminalSearchBar.swift`), and `TerminalContainerView.applyFocus` yields to it — that interaction
  is the place to look.
- `terminal.search.summary` (the a11y identifier on the summary `Text`) already exists for whoever
  picks this up.

**How to start:** dump the accessibility tree with the find bar open
(`app.debugDescription` written to a file from inside the test) and confirm what the field element
actually is and whether it reports keyboard focus. If SwiftUI focus proves undrivable here, the
fallback is to drive `TerminalSearchModel.setNeedle` through a `UITestFixture` seam and assert the
counter, which still exercises the two engine actions end-to-end.

**Depends on:** nothing. `TerminalSearchTests` already covers the pure state folding, so this is
purely about the engine→UI leg.

**Priority:** P3 — two of the three visible tags are covered, and the search path has unit coverage
for everything except the engine round-trip.

### Bundled ghostty resources — provenance recorded, nothing to regenerate (macapp)

**Status: the premise of this entry was wrong, and it is measured now.** It used to say "regenerate
`terminfo/` + `shell-integration/` from the ref the pinned package builds from", on the assumption
that unrecorded provenance meant *stale* resources. Measured 2026-08-09 against a stock Ghostty.app
1.3.1 install and ghostty's own git history:

- **`terminfo/` has zero drift.** `terminfo/78/xterm-ghostty` is byte-identical to the engine's own.
  `terminfo/67/ghostty` is the same record under the `ghostty` alias. Nothing to regenerate.
- **`shell-integration/` is *ahead* of the engine, not behind** — a `main` snapshot from the window
  [`43f3dc5f` 2026-03-25 … `484d6ec6` 2026-05-04), pinned by a byte-exact blob match on
  `bash/ghostty.bash`. It carries four upstream fixes v1.3.1 lacks (ble.sh cursor desync,
  `PROMPT_COMMAND` newline handling, inherited-`PROMPT_COMMAND` errors in subshells, trailing-`%`
  prompt corruption).
- **The drift is safe on both contract axes**, checked rather than assumed: the two sets reference
  an identical ten-variable `GHOSTTY_*` surface, and our OSC 133 vocabulary is a subset of what the
  v1.3.1 scripts themselves emit, so the pinned engine parses everything we send.

So **regenerating against v1.3.1 would be a downgrade** — four real fixes traded for a version
number. Don't.

What actually shipped instead: full provenance in `macapp/Resources/ghostty/SOURCE.md`, a
`CHECKSUMS` manifest pinning the bytes, and `GhosttyResourcesTests` verifying membership + hashes
both ways. That is the tripwire the entry existed to ask for.

~~**One live risk survives, and it moved to the bump entry**: upstream deleted the inline ssh wrapper
in favour of `ghostty +ssh`, a binary we do not ship.~~ **Resolved** — we ship it now, as a relative
`Contents/MacOS/ghostty` symlink to the app binary (libghostty already carried the `+action`
dispatcher). What remains under the bump entry is testing `+ssh` itself once the pin moves.

**Watch:** `libghostty-spm` PR #43 proposes shipping compiled terminfo + shell-integration from the
package itself, pointing `GHOSTTY_RESOURCES_DIR` at the package bundle. If that merges, our copies
get deleted instead of refreshed. Open as of 2026-08-05.

**Trap that still applies:** `themes/` in that directory is **ours** — 116 curated files whose
filenames `ThemeService.families` parses. Never regenerate it from a ghostty checkout. It keeps its
own `themes/SOURCE.md` + `themes/CHECKSUMS`, deliberately disjoint from the new one.

**Priority:** done.

### VCS write actions — Phase 2 (macapp) — roadmap pointer

**What:** The next VCS phase: turn the read-only foundation into a full in-app VCS UI. **Fetch, push
and pull-with-rebase have SHIPPED** (the VCS toolbar), and so have **commit + message-only amend/describe**
(the Changes inspector's commit dialog). What remains: selection-aware amend (needs a temp index),
bookmark (jj) / branch (git) management, and the deep jj ops (undo/op-log, split, absorb, evolog,
interdiff).

**Where the write seam actually is — this changed.** The original plan put write methods on
`VCSProviding` with a `CLIVCSProvider` fallback. That is **not** what shipped, and new work should not
follow it. Writes live behind a **separate** `VCSWriting` protocol (`Core/VCSWriting.swift`) with its
own factory `VCS.writer(for:)`, conformed by `CLIVCSWriter`. Two reasons, both load-bearing:

- `VCSProviding`'s doc calls it "the single seam the app **reads** VCS data through", and four
  resolvers construct providers freely and call them with no gate. A `fetch` on that protocol means
  nothing structurally stops a read path firing a network mutation — the opposite of what
  `JJSnapshotGate` exists to guarantee.
- A CLI-backed method needs an injected `StatusCommandRunning`, and `GitProvider`/`RustJJProvider` are
  stateless value types constructed at four call sites with nowhere to put one. A new conformer has
  somewhere.

So: add commit/amend and the rest as `VCSWriting` members, and they inherit the gate, the network
environment hardening and the failure taxonomy for free.

**Which backend each op uses — decided, don't re-litigate.** `VCSWriting` says *where* writes live,
not *how* they run. The split:

| Ops | Backend | Why |
|---|---|---|
| commit/amend — **CLI, decided against this table's original answer** | **CLI** (`CLIVCSWriter.commit`, shipped) | This row used to say "native", and that was wrong on three counts it never weighed. **libgit2 runs no hooks** ([#964](https://github.com/libgit2/libgit2/issues/964)) — a `pre-commit`/`commit-msg` that the user's terminal honours would be silently skipped, which is worse than not offering commit at all. **libgit2 cannot sign**, so `commit.gpgsign = true` would produce unsigned commits. And native jj commit is blocked on `immutable_heads()` being a jj-*cli* revset alias that jj-lib cannot resolve — so it would happily rewrite commits the user's own `jj` refuses to touch. (The empty-committer and dropped-signature halves of that third blocker are now fixed by `jj_config.rs`; the revset one is not.) |
| branch + bookmark management, jj undo/op-log/split/absorb/evolog | **native** (libgit2/SwiftGitX, jj-lib) — provisional | Local, typed APIs, no output to parse, no tool-version floor, no locale exposure. Still the default answer, but **not "don't re-litigate"**: commit was re-litigated on measurement and moved. Check each op for hooks, signing, and revset aliases before assuming native. |
| fetch, push, pull | **CLI** — permanently, not a stopgap | Three independent blockers, all verified from checked-out sources: SwiftGitX passes NULL options (`git_remote_fetch(remotePointer, nil, nil, nil)`, and `pull` is a `// TODO`), so it has no credential callback at all; **libgit2 implements no `credential.helper` protocol** — nothing in its `src` reads that config key, so native auth means reimplementing helper invocation ourselves; and jj-lib shells to `git` for remote ops anyway (that's where its `MINIMUM_GIT_VERSION` comes from), so a "native jj push" is a git subprocess wearing a Rust coat. |

**Non-goal: Workroom does not store credentials.** No OAuth client, no keychain writes, no auth
prompt, no account concept. The user's own helpers (`osxkeychain`, GCM, `!gh auth git-credential`,
anything corporate) are the correct answer, and shelling out gets every host — including ones we've
never heard of — for free, with the same credentials their terminal uses. GitHub Desktop is the
instructive counterexample: it also shells out (via `dugite`, which bundles its own git), but blanks
your helpers and registers itself as `credential.helper=desktop` because being *the GitHub client* is
its product. The cost of that choice is `app/src/lib/generic-git-auth.ts` — a second credential store,
with its own prompt UI, keychain keys and invalidation, for every non-GitHub host. We are not that
product, and the app's one GitHub dependency (PR status) already rides `gh`'s own token.

**When you do shell out, never parse prose.** `--porcelain`, `-z`, `%(…)`, `-T`, exit codes. Measured:
`Updates were rejected` becomes `Les mises à jour ont été rejetées` under `fr_FR.UTF-8`, so a prose
match loses the whole failure taxonomy for a non-English user. `StatusCommandRunner` pins `LC_ALL=C`
as a backstop; it is not the plan.

*Filed, not planned:* bundling our own `git` the way `dugite` does would delete all of
`Core/VCSToolVersions.swift` — floor, probe, notification, per-VCS scoping. Real cost (universal
binary, notarization, ~40MB, and the Go CLI would want the same binary), so revisit only if the
version floor actually bites a user.

**Why:** This is a roadmap phase, not a tactical follow-up. The authoritative scope + sequencing live
in the issue #59 plan; this entry is the pointer that makes it discoverable.

**How to start:** Read `Core/VCSWriting.swift` — its doc comment carries the routing diagram, the
per-backend command table and the placement rules (fetch always runs at the project root, for both
backends; jj push too, because bookmarks are repo-global). The read layer blocks nothing. What's left
of the error taxonomy is one-sided (git still flattens to `.io`), and the stale-working-copy **repair**
is itself a write, so it belongs to this phase.

**Depends on:** the VCS read foundation (shipped, Phase 1) and the write seam (shipped with the
toolbar). Spans `Core/VCSWriting.swift`, possibly `vcs/` (Rust) + `WrVcs` UniFFI for native jj ops, and
new write-flow UI.

**Priority:** P2 (the product direction; large — see the plan for the real breakdown).

### `.task(id:)` cancellation is not reliably delivered on an in-place value swap (macapp) — measured 2026-08-13

**What:** while fixing an `AvatarView` staleness bug (a stale in-flight fetch for author A landing
in `result` after the same slot switched to author B), the fix's first draft guarded on
`Task.isCancelled` — SwiftUI's documented behavior for `.task(id:)` is "if the id value changes,
SwiftUI cancels the previous task." Instrumented and measured directly (`Avatar.swift`, temporary
`lastCancelObserved` seam, since removed): for an in-place `subject` swap at a stable view-identity
slot (no `ForEach` re-keying, just a `@Published`/`@ObservedObject` value change), `Task.isCancelled`
read **`false`** throughout the outgoing task's remaining lifetime, even though a brand-new `.task`
invocation for the new value had already started and completed. The guard was dead code.

**Fix applied there:** replaced it with a generation token — `@State private var activeTaskKey`,
written at the START of every `.task` invocation (before its `await`) and compared against the
invocation's own captured key before committing. `@State` survives the slot being reused (same
mechanism `result` itself already relies on), so whichever invocation started LAST always wins the
comparison, independent of whether SwiftUI ever delivers real cancellation. Red/green-verified:
reverting the token guard reproduces the exact original failure.

**Why this is worth a standalone entry:** any OTHER `.task(id:)` in this codebase that guards a
stale-write race on `Task.isCancelled` alone is potentially relying on the same dead code. Grep for
`Task.isCancelled` near a `.task(id:` call before trusting one; the working pattern is the
generation-token comparison above, not the cancellation flag.

**Priority:** informational — no other call site audited yet. Worth a pass if another stale-write bug
surfaces in a `.task(id:)`-driven view.

### `withTimeout` doesn't observe the CALLER's own cancellation (macapp) — FIXED

**Status:** the original version of this entry (a `withThrowingTaskGroup` awaiting a detached
operation child past its own deadline) is **fixed** — `Core/Timeout.swift` now races via a single
`withCheckedThrowingContinuation` + a `TimeoutGate`, exactly the fix this entry used to recommend.
Re-audited during the jj-snapshot-serialization `/review` (2026-07-24, cross-model: Codex found it)
and found a **different, still-live** gap in that same seam — **now also fixed.**

**Fixed:** `withTimeout` wraps its continuation in `withTaskCancellationHandler` (a `TimeoutCancelBox`
bridges `onCancel`, which Swift can invoke before/during/after the continuation attaches, to settling
the SAME `TimeoutGate` early with a new `VCSCancellationError`) — same shape `JJSnapshotGate.run`
already used. `WorkroomStatusResolver`'s two catch sites treat `VCSCancellationError` the same as
`VCSTimeoutError`; `BranchResolver`'s blanket `catch` and `JJSnapshotGate`'s own `try?` call were
already safe either way. `TimeoutTests.swift` (previously zero coverage on this seam) covers the
success/deadline baselines plus both cancellation orderings (mid-race and already-cancelled-at-call)
and a 200-iteration stress test for the exactly-once settle guarantee; the cancellation test itself
proves the fix by needing well under 1s against a 5s deadline/operation, not the full wait. Full
`WorkroomStatusResolverTests`/`WorkroomStatusConcurrencyTests`/`BranchResolverTests`/
`VCSProviderConformanceTests` sweep green, no regressions.

**What:** `withTimeout`'s `withCheckedThrowingContinuation` only resolves on ITS OWN internal race
(the operation finishing vs. its own `seconds` deadline firing) — it never wires up
`withTaskCancellationHandler`, so it does not observe the CALLING task being cancelled from outside.
Concretely: `AppStore+WorkroomStatus.swift`'s `statusSweepTask?.cancel()` (a new sweep replacing an
old one) propagates into `runLocalSweep`'s `withTaskGroup` children structurally, but a cancelled
child's in-flight `withTimeout(seconds:) { … }` call (inside `resolveJJ`/`resolveGit`) keeps running
to completion (or its own `seconds` timeout) regardless — it doesn't stop early just because the
enclosing task gave up.

**Why:** Wastes CPU/time re-running a probe nobody wants anymore, and — post the jj-snapshot-gate
fix — adds unnecessary extra contention pressure on `JJSnapshotGate` (an unwanted, already-abandoned
caller still occupies a project's queue slot for up to its full timeout). This is a
responsiveness/efficiency gap, not a data-integrity one, because the call sites in this seam do
check `Task.isCancelled` before merging a stale result (`runLocalSweep`'s
`if Task.isCancelled { break }`, etc.).

**Corrected 2026-08-05 — do NOT re-read this entry as "the convention protects us".** This used to
say *every* call site already checks, so state stays correct. That was false, and the counterexample
shipped: `refreshGitHubCLI` mutated `githubCLIStatus` **inside** an awaited function, where the
callers' own guards (`AppStore+WorkroomStatus.swift:86`/`:144`) run too late to help. A cancelled
probe's SIGKILLed `gh` still returned through `StatusCommandRunner`'s non-throwing continuation with
the signal number as its exit code, the classifier read that as "not signed in", and publishing it
*stamped the TTL* — so the wrong value suppressed its own repair for a full minute. The cost of a
missed guard is therefore a **wrong published value**, not merely a wasted probe. Two defences
landed with that fix and are what keeps the residual risk low: `CommandResult.signaled` (a killed
child is never mistaken for a CLI that ran and failed) and `GHAuthProbe.keepPrior` (a non-answer
neither writes nor stamps). The `withTimeout` gap below is a genuinely different mechanism and stays
deferred on its own merits.

**Priority:** done.

### VCS toolbar: the findings the `/review` pass didn't fix (macapp)

**What:** Everything the toolbar review verified but left standing. Each was reproduced or read off the
code; none is speculative. Ordered by what a user hits first.

**Nine have since SHIPPED and are struck below**, so the list is what remains:

- **the empty-remote case** (was (1)): `CLIVCSWriter.mergeRemotes` now unions the configured remote list
  (`git remote`, `jj git remote list`) with the ref-derived names for both backends, so publishing to a
  brand-new empty remote works and the counts stay ref-derived.
- **(5), (6) and (7)** — the three a user noticed — see each entry.

3. ~~**jj bookmark names that need quoting never match.**~~ **SHIPPED.** jj's template pre-quotes
   non-identifier names (verified: `"main|evil"` comes back WITH the quotes) — `jjUnquote` (the exact
   inverse of `jjQuote`) now unquotes every name coming out of `parseJJBookmarks` before it's stored or
   compared, and `jjRebaseDestination` builds its revset from the raw bookmark name and remote, each
   quoted independently with `jjQuote`, rather than reusing the pre-joined `comparedTo` display string.
4. ~~**jj multi-remote: the wrong remote's tracking row wins.**~~ **SHIPPED.** `parseJJBookmarks` now
   takes a `primaryRemote` hint (resolved from the configured remote list, ahead of the ref-derived
   merge) and picks that remote's row per bookmark name instead of last-write-wins, closing the
   `origin` + `upstream`-both-tracking-`main` collision.
5. ~~**`resolvedBranchNames` is stale-wins and never pruned.**~~ **SHIPPED.** The cache now yields
   instead of winning: `mergeLocalStatus` drops the entry when the sweep's `branchForCI` disagrees
   (`pruneResolvedBranchNameIfDrifted` — an empty/absent swept branch is not a disagreement, since a
   detached HEAD and an unbookmarked jj `@` legitimately report none), and `removeWorkroomLocally` /
   `removeProjectLocally` prune it on delete beside the label they already dropped. `git switch` in a
   workroom's terminal now follows within one sweep. Note what was NOT changed: the write side is still
   focused-target-only and still gated on the inspector showing Changes — that gate is the reason a read
   costs 2-3 processes rather than a pointer move, and drift-pruning is what makes it safe.
6. ~~**A failure is discarded if the selection moved.**~~ **SHIPPED.** The `lastFailure` write stays
   behind `finish`'s identity guard (correct — the bar renders whatever is selected NOW), but the DIALOG
   is now raised ahead of it, carrying `VCSFailureReport.workroom` so the sheet names where it happened
   when that isn't the current selection. Deliberately NOT a toast: `WorkroomNotification` is OSC-shaped
   (`targetID` + `tabID` + `kind == .osc`), so a VCS failure doesn't fit it without inventing a second
   kind, and the dialog was already the app's answer for "something you asked for failed" — it was just
   being suppressed.
7. ~~**A failed remote READ renders "No repository".**~~ **SHIPPED.** `RemoteStateModel` now publishes
   the read's failure typed (`readFailure`) rather than only as the `String` inside `state.failed`, which
   nothing rendered and nothing could classify. The presenter has a tier for it ([13b], below an action
   failure and an in-flight action, above everything else): it names the cause, carries the lock path,
   and — only when re-reading could plausibly help (`readRetryIsWorthwhile`) — offers "Try Again", which
   re-runs the READ (`retriesRead` — re-reading is not a `VCSRemoteAction`, so it can't route through
   `perform`). A read failure carrying an ACTION recovery (a leftover rebase, a rejection) offers that
   action instead; one that nothing can fix (`toolMissing`, a LOCATED lock, `noRemote`) is a disabled
   message, per `retryAction`'s rule. [13c] renders the re-read in flight ("Trying again…" + spinner).
   `activate` is wired too, as the toolbar's own `.task`.
8. ~~**A workroom deleted mid-action reports "git isn't on Workroom's PATH".**~~ **SHIPPED.**
   `CommandResult.launchFailed` (a negative sentinel, `-1`) is now returned by the runner's catch
   block instead of `commandNotFound` when the process never launched at all (cwd vanished), and
   `classify`/`classifyCommit` check it before `commandNotFound` — so a deleted-mid-action workroom
   reports "This workroom's folder is no longer there" instead of a false "tool missing" that
   contradicted the version toast.
9. ~~**`JJSnapshotGate`'s 30s self-heal is far below the write timeouts it guards.**~~ **SHIPPED,
   via a different mechanism than raising the ceiling.** Rather than raising `maxChainWait` (which
   would slow every unrelated status probe on the project, not just ones racing a live write), added
   a unified per-project `writingProjectRoots` counter (`ProjectStore`) that commit/fetch/push/pull
   all check via `isWritingProject`/`canStartWrite` BEFORE starting — a second write on the same
   project root now refuses outright (`.locked(nil)`, "The repository was busy. Try again.") instead
   of queuing into the gate and racing a live one past its wedge-detection ceiling. The gate's own
   30s ceiling is untouched — it still exists for a genuinely wedged single chain, which is a
   different problem.
10. ~~**Colocated jj root: "Abort rebase" reports success, changes nothing, loops.**~~ **SHIPPED.**
    `abortRebase`'s jj branch now checks `rebaseInProgress(gitDir: worktreeGitDir(at: path))` before
    faking success — only a colocated root with no real git-side rebase state gets "Nothing to
    abort"; otherwise it falls through to a real `git rebase --abort` (explicitly against `"git"`,
    never the vcs-derived executable, which would run `jj` with git's flags and fail outright).

Plus one doc correction: `gitLastFetch`'s comment claims `FETCH_HEAD`'s mtime covers "one the user ran in
a terminal". It doesn't, for the terminals this app opens — a fetch inside a worktree writes
`worktrees/<n>/FETCH_HEAD` while the common one stays put (measured), so counts update from the shared
`refs/remotes` while the timestamp doesn't. Either read both and take the max, or stop claiming it.

**Why:** These are the residue of a five-pass review (critical + 4 specialists + Claude adversarial +
Codex) whose P0s — argv option injection and jj push publishing the wrong workspace's commit — are
already fixed. What's left is real but none of it is a security hole or silent data loss.

**Priority:** done. Everything in this list has shipped; the sole remaining item (jj Pull guessing
`trunk()` as the rebase base for an unbookmarked `@`) was dropped 2026-08-14 — its 2026-08-10
correction found the triggering scenario doesn't reproduce (three revsets tried and falsified), and
it was parked rather than fixed pending a fresh repro that never showed up.

### jj `push-<id>` bookmarks accumulate on the remote (macapp) — VCS-toolbar eng-review follow-up

**What:** Decide what happens to the `push-<change-id>` bookmarks that pushing an unbookmarked jj `@`
leaves on the remote.

**Why:** A jj workroom is `jj workspace add`, whose `@` carries no bookmark, so the toolbar's Push runs
`jj git push --change @`. jj creates a bookmark named by `templates.git_push_bookmark` (default
`"push-" ++ change_id.short()`), and **nothing ever removes it**. Verified on jj 0.43 against a bare
origin — two pushes of two different changes left two bookmarks behind permanently:

```
push-rrxukuporqwy
push-slxllnxlmxwz
```

On a shared remote that accrues indefinitely, one entry per change anyone ever pushed from a workroom.

**Not a problem, though it was filed as one:** the review paired this with a suspected
non-fast-forward asymmetry — that re-pushing an amended change would be rejected. It isn't. A change id
is stable across amends, so jj moves its own bookmark with no force flag and no error:

```
bookmark: push-slxllnxlmxwz [move sideways from b7e44fc98f79 to 8f82f551ad69]
```

Don't re-investigate that half.

**Pros:** a shared remote stays legible.

**Cons:** this is jj's OWN behaviour for an anonymous push, not something Workroom invented — bare
`jj git push --change` does exactly this. Diverging from it means inventing a naming or cleanup policy
that jj users won't expect from other jj tools. Doing nothing is defensible.

**Context / how to start:** `CLIVCSWriter.jjPushRevision` and the `--change` push path; the options are
(a) leave it and document it, (b) offer cleanup of merged `push-*` bookmarks, or (c) require a bookmark
before pushing, which costs the one-click Publish a fresh workroom currently gets.

**Depends on:** the VCS toolbar (shipped).

**Priority:** P3 (jj projects only; cosmetic on a personal remote, untidy on a shared one — and the
status quo matches jj's own).

### "New workroom from branch…" (macapp) — the successor to branch switching

**What:** Pick a local or remote branch and create a workroom for it, from the VCS toolbar's branch
segment or the ⌘O picker.

**Why:** Branch *switching* was deliberately cut from the VCS toolbar. A workroom's identity IS its
branch — `internal/vcs/git.go` creates it with `git worktree add -b`, and there is no `branch` field
anywhere in `internal/config` — so switching a workroom's branch makes its directory name permanently
wrong, with nothing to reconcile the two. The jj equivalent is worse: `jj new <bookmark>` on the
bookmark the toolbar already displays was reproduced **removing a file from the working copy** and
leaving the workroom's commit as a nameless dangling head, with no visible change in the UI.

But the underlying need — "I want to work on that other branch" — is real, and creating a workroom is
the answer the product model actually supports. The toolbar's branch segment is **display only** — it
briefly routed to ⌘O, which was dropped because ⌘O lists only workrooms that already exist, so the
click promised more than it delivered. That leaves the segment with no action at all, which is the
honest state until this lands and gives it one worth having.

**Pros:** gives the cut affordance a correct home; makes an existing remote branch a first-class
starting point instead of requiring a manual create-then-checkout.

**Cons:** needs a branch list (the toolbar deliberately stopped enumerating refs when the picker was
cut), and a naming policy for the new workroom.

**Context / how to start:** `Views/OpenWorkroomDialog.swift` is the searchable, project-grouped picker
to clone; the Go CLI's `create` already accepts a branch. `CLIVCSWriter.gitRemoteRefsArgs` shows how to
enumerate remote refs cheaply, and its doc explains why the symref row must be dropped.

**Depends on:** the VCS toolbar (shipped).

**Priority:** P3 (a real gap, but ⌘O plus a terminal covers it today).

## P3 — VCS engine, diffs, and status

### `XDG_CONFIG_HOME` never reaches the `gh` auth probe (macapp) — gh-flap eng-review follow-up

**What:** decide whether `XDG_CONFIG_HOME` (or another way of resolving gh's config dir) should reach
the NON-network `run` path that `WorkroomStatusResolver.resolveGitHubCLI` uses.

**Why:** `XDG_CONFIG_HOME` *is* in `StatusCommandRunner.forwardedAuthKeys`, but that allowlist is only
applied by `networkEnvironment`, i.e. behind `if network` in `run`. The gh auth probe is a plain `run`,
and the comment justifying the split says gh "carries its own token" — true, but gh FINDS that token via
its config dir. A user who sets `XDG_CONFIG_HOME` in `.zshrc` and launches from Finder therefore hands
gh a different config root than their terminal uses. Measured: an empty gh config dir returns
`{"hosts":{}}` on stdout with exit 0, which classifies as `.notAuthenticated` — a permanent false
"GitHub CLI not signed in" for someone who is signed in everywhere else. Same false claim the
cancelled-probe fix removed, reached by a completely different route.

**Pros:** closes the last known cause of a false "not signed in". **Cons:** widening the environment on
an automatic path is a deliberate, documented narrowness (`StatusCommandRunner` explains why a
wholesale transplant is refused for anything that runs without the user asking) — this is a security
posture question, not a one-line fix. A third allowlist ("non-secret, both paths") is probably the right
shape, and `GH_CONFIG_DIR` deserves the same thought.

**How to start:** `StatusCommandRunner.run`, where `if network` selects the environment. Decide the
allowlist question first, then apply to both paths.

**Depends on:** nothing.

**Priority:** P3 — real and measured, but it needs a policy decision, and the affected configuration is
uncommon.

### The other `CommandResult` consumers don't know about `signaled` (macapp) — gh-flap eng-review follow-up — SHIPPED (2026-08-10)

**Shipped:** all three sites now consume `CommandResult.signaled`, exactly as scoped below.
`AgentRunner.classify` returns `.interrupted` (checked after `timedOut`, before `commandNotFound`,
per the ordering note below) instead of `.failed(exitCode: 9, ...)`. `FileTreeModel.list` returns a
new `ListResult.interrupted` case (distinct from `.unavailable`) so a killed probe leaves the
existing tree/state alone instead of blanking it as "not a repo". `RustJJProvider.run` throws
`VCSError.io("\(exe) was interrupted")` before its generic exit-code guard. Each site has a
regression test.

**What:** consume `CommandResult.signaled` in `AgentRunner.classify`, `FileTreeModel`, and
`RustJJProvider.runCLI`.

**Why:** the gh-flap fix added `signaled` (a killed child reports its SIGNAL in `terminationStatus`, so
9 or 15 is not an exit code) and wired it into the gh classifiers plus both `CLIVCSWriter` failure
classifiers. Three consumers still read a raw exit code as evidence. `AgentRunner.classify` is the one
that reaches a user: a killed `claude` diagnosis becomes `.failed(exitCode: 9)` and the agent banner
shows "exit 9", which is exactly the class of nonsense commit `a64e4269` set out to end.
`FileTreeModel` gates on `result.ok`, so a signalled listing renders as a silently empty file tree.
`RustJJProvider` throws `VCSError.io("jj exited 9")`.

**Pros:** finishes the job — every place that reads an exit code as evidence learns that a signal is not
one. Each site is a one-line branch plus a test, since the mechanism already exists and is tested.
**Cons:** none of the three has a reported symptom, and two fail safe (an empty tree, a typed IO error)
rather than making a false claim.

**How to start:** `AgentRunner.classify` first (the only user-visible one): treat `signaled` as its own
outcome before the `exitCode != 0` branch, and mind that `timedOut` implies `signaled`, so the timeout
check must stay first.

**Depends on:** `CommandResult.signaled` (shipped).

**Priority:** P3 — cheap, but speculative until someone reports one.

### `ShellEnvironment` exposes no probe-readiness signal (macapp) — gh-flap eng-review follow-up

**What:** give `ShellEnvironment` a way for callers to know whether the interactive-shell PATH probe has
landed (or to await it), instead of silently degrading to the floor.

**Why:** `ShellEnvironment.path()` returns the probed PATH if the probe finished and the deterministic
floor otherwise, with nothing distinguishing the two. The probe is fired detached in `WorkroomApp.init`
and nothing joins it, while `refreshVCSToolReport` runs from `apply(projects)` — so a launch-time
`--version` probe can genuinely run against floor-only PATH. The floor covers Homebrew but not a
version-manager shim dir, Nix, or MacPorts, so those tools read as missing. `VCSToolVersionCache` no
longer *pins* such a verdict (it refuses to cache a discovered absence — shipped with the gh-flap work),
but that treats the symptom: any future caller reading `path()` early inherits the same ambiguity with
no way to detect it.

**Pros:** removes a whole class of "it depends when we asked" bugs, and would let the few callers that
genuinely need enrichment await it rather than guess. **Cons:** the probe is best-effort BY DESIGN — its
failures must degrade to the floor, never block — so a readiness signal must not become a hidden
dependency that stalls launch. Larger and more delicate than it first looks.

**How to start:** `ShellEnvironment.ProbeState` already tracks a generation; surface "has a probe
completed" from it, then audit `path()` callers for who should wait versus who should keep degrading.

**Depends on:** nothing.

**Priority:** P3 — the honest fix for a family of PATH-timing bugs, none currently reported.

### `VCSToolVersionCache` pins a tool verdict for the whole process (macapp) — gh-flap follow-up — SHIPPED (2026-08-10)

**Shipped, with one revision from this entry's original proposal.** The `GitHubAuthCache` shape
(freshness lease, generation-stamped in-flight, per-`ProjectStore` instance ownership) is lifted, as
proposed — but NOT as one combined `Report`/`probedJJ` slot. Tracing the actual reentrancy bug during
implementation showed a single combined slot doesn't structurally stop a `probeJJ: false` (jj-blind)
completion from overwriting a `probeJJ: true` (jj-aware) cached verdict — `GitHubAuthCache` has no
analogous coverage axis to protect, so a literal transplant only imports the temporal generation
stamp, not the fix. Revised to two fully independent cache slots (git, jj), each its own
`GitHubAuthCache`-shaped instance — a jj-blind caller now never touches the jj slot at all, closing
the clobber class structurally rather than by ordering. TTLs match `GitHubAuthCache`'s exact numbers
(60s `.ok` / 10s `.belowFloor`) as this entry proposed. `.notInstalled` is still never cached, per the
existing (already-shipped) reasoning quoted below.

**What:** give the `git`/`jj` version cache the three contracts the `gh` cache got in the same area and
this one never did: a freshness lease, a generation-stamped in-flight slot, and per-`ProjectStore`
ownership instead of `static let shared`. `Core/VCSToolVersions.swift` (the cache is the actor at the
bottom); the shape to copy is `Core/GitHubAuthCache.swift`.

**Why (the user-visible half first):** `report(probeJJ:)` caches every verdict except `.notInstalled`
**forever** — the only thing that clears `cached` is the tests-only `reset()`. So `.belowFloor` is
permanent for the process: the user reads "Git 2.41 or newer is required", runs `brew upgrade git`, and
fetch/push/pull stay disabled with the toast still standing until they relaunch the app.
`refreshVCSToolReport` does re-run on every `apply(projects)`, but it gets the pinned answer back, and
dismissing the toast (`dismissedToolWarnings`) only hides it — nothing re-probes. `gh` got a monotonic
60s/10s TTL *and* a manual Refresh; the tool whose warning names an action the user is expected to go
perform got neither.

Two structural gaps behind it, both fixed in `GitHubAuthCache` and both still live here:

- **Reentrancy loses the single-flight and can downgrade the cache.** `await task.value` suspends the
  actor with `inFlight` set, and the `inFlight = nil` after it is unconditional and unstamped. A
  `probeJJ: false` caller finishing clears a concurrent `probeJJ: true` caller's slot, so the next jj
  caller forks a third `--version` pair; and if the jj-blind lane resumes *last* it overwrites the
  jj-aware report, because `probe(probeJJ: false)` returns `jj: .notInstalled` outright and
  `hasMissingTool(probedJJ: false)` doesn't count it. Narrow (both windows normally compute the same
  `probeJJ` from the same config) but exactly the class the `gh` generation stamp exists to kill.
- **`static let shared` plus an injected `runner:` is the hazard `GitHubAuthCache` documents rejecting**
  — `make app-test` runs classes in parallel, so one test's fake runner can answer another's probe, and
  `reset()` cannot stop an in-flight task repopulating afterwards. Cheap to close here:
  `VCSToolVersionsTests` already builds fresh instances, so `AppStore` is the *only* `.shared` caller.

**How to start:** lift the `GitHubAuthCache` shape wholesale — `ContinuousClock` freshness with
injectable TTLs, generation-stamped `inFlight`, instance ownership. Only the TTL is new policy: refusing
to cache `.notInstalled` already ships, so pick a shortish lease for `.belowFloor` (an upgrade is the
expected repair and it should be noticed) and a long one for `.ok`.

**Depends on:** nothing. Adjacent to the `ShellEnvironment` probe-readiness item above — that one is
about a verdict taken too early, this one about a verdict kept too long — but neither blocks the other.

**Priority:** P3 — self-repairing on relaunch, and no report of it in the wild. The stale `.belowFloor`
alone justifies it.

### N-in-flight concurrency accounting test for status sweeps (macapp) — Muxy test-practices review follow-up — FIXED

**What:** Add an injectable seam to `WorkroomStatusResolver.resolveGit`/`resolveJJ` (they called
`GitProvider().workingStatus(root:)` and the native jj core directly, with no way to substitute a
double — `workingStatus` isn't on `VCSProviding`, so this was never `StatusCommandRunning`'s job),
then write a counting test on `runLocalSweep`'s `cap`-bounded `withTaskGroup` fan-out
(`AppStore+WorkroomStatus.swift:457-529`) that asserts the number of concurrent local-status probes
never exceeds `cap`.

**Fixed, the `runLocalSweep` half:** `GitStatusReading`/`JJStatusReading` (`WorkroomStatusResolver.swift`)
are the new seams, injected via `WorkroomStatusResolver.init(gitStatus:jjStatus:)`, defaulting to the
real `GitProvider`/`RustJJProvider`. `WorkroomStatusConcurrencyTests.testLocalSweepNeverExceedsItsConcurrencyCap`
drives a real `AppStore` with 8 throwaway git projects and a counting `GitStatusReading` double,
asserting peak-concurrent calls stay ≤ 5 (`AppStore.localConcurrency`) and that the fan-out actually
overlapped (>1) — so the test can't pass vacuously against a fully serial sweep.

**Fixed, the `runCISweep` half:** it fans out over `resolveCI`/`gh`, which already had an
injectable `StatusCommandRunning` (see `GatedGHRunner` in `WorkroomStatusTests.swift`) — the seam
problem this entry was filed for was only ever `resolveGit`/`resolveJJ`'s, so this half was a
counting double, not a new seam. `WorkroomStatusConcurrencyTests.testCISweepNeverExceedsItsConcurrencyCap`
drives 8 throwaway projects through a `CountingGHRunner` (counts concurrent `gh`/`git` calls while
returning enough of a real answer to keep `resolveCI`'s chain moving), asserting peak-concurrent
calls stay ≤ 2 (`AppStore.ciConcurrency`) and that the fan-out actually overlapped (>1).

**Priority:** done.

### Repo-level meta-test for Makefile/CI test invariants (macapp) — FIXED

**What:** Add a check — in the existing dependency-free script tier alongside
`Scripts/build-helper_test.sh`/`Scripts/channel-helper_test.sh` (run via `make app-test-scripts`), not a
new XCTest class — that pins two invariants: the `APP_UITEST_FLAGS` skip list in `Makefile:67`, and
that CI/release/nightly workflows actually invoke `app-test` somewhere (not just that the Makefile's
dependency graph excludes it from `app-release`).

**Fixed:** `Scripts/test-invariants_test.sh` — pins the skip list literally (want vs. got string
compare) and greps `ci.yml`/`release.yml`/`nightly.yml` for a bare `make app-test` invocation (word-
bounded so it can't match `app-test-scripts`/`app-test-supervisor`). Overridable via
`TEST_INVARIANTS_MAKEFILE`/`TEST_INVARIANTS_WORKFLOWS_DIR`, and both cases proven to actually fail
against a dropped skip entry / an emptied workflow (not just pass vacuously). Wired into
`app-test-scripts`.

**Priority:** done.

### Cross-launch navigation history (macapp) — issue #26 / #46 follow-up

**What:** Back/forward (⌘[ / ⌘]) does nothing immediately after a relaunch. Session restore (issue #46)
brings the panes back but not the history that led to them, so the first ⌘[ in a restored window has
nowhere to go.

**Why:** It is the one part of "pick up exactly where you left off" that #46 deliberately left out, and
the reason is structural rather than lazy — worth writing down so the next person meets it instead of
rediscovering it. `NavLocation` keys on `TerminalTab.ID`, and restore **mints fresh tab ids on purpose**
(a tab id is unique across windows at runtime, and `WindowRegistry.ownerOf(tabID:)` routes OS
notification clicks by it). So every persisted history entry would point at a tab that no longer exists,
and naively reviving the old ids would trade a dead-history bug for a duplicate-id one.

**How to start:** `Core/NavigationHistory.swift`. `NavLocation` already carries a content identity
beside the tab id (the `FocusedTabSelection`-shaped payload), so the path is to re-key replay on content
rather than on the tab — then persisting the stack is a small addition to `WindowSession`. Note that
`NavPayload` normalises `isPreview` and `selectedPath` out, which persistence would need back.

**Depends on:** issue #46 landing first (restore has to exist before there is anything to replay into).

**Priority:** P3 — a nicety, and the window it affects is the first few keystrokes after a launch.

### Deterministic tab lookup for content panes (macapp) — nav-history follow-up

**What:** `TerminalSessions.contentTab(matching:)` and `previewTabID(in:)` both resolve with
`.first { … }` over `tabsByTarget`, which is a **Dictionary** — unordered, so which tab they return is
not deterministic when two match. Resolve through `orderByTarget` (the strip order) instead, so "first"
means leftmost.

**Why:** `newPaneTab` deliberately bypasses the same-file dedup ("so the same-file dedup doesn't
collapse it back onto the anchor"), so ⌘D on a diff or changeset pane genuinely creates two tabs with
identical content identity. Back/forward replay now resolves through these lookups, which makes the coin
flip user-visible: replay could focus the pinned twin instead of the pane you were browsing in. Today
only two things hide it — replay prefers the tab the location was recorded in (step 1 of
`AppStore.applyLocation`), and the ≤1-preview invariant keeps `previewTabID` incidentally unique.

**How to start:** `previewTabID` and `contentTab(matching:)` in `Core/TerminalSessions.swift`; both have
`orderByTarget` to hand. Pin it with a test that builds twins via `splitFocusedPane` on a diff pane and
asserts *which* tab a lookup returns.

**Depends on:** nothing. Independent of the nav-history fix, which is what made it matter.

**Priority:** P3 (latent; replay's prefer-the-recorded-tab step shields the common path, and
`AppStoreContentNavigationTests.testReplayPrefersTheRecordedTab` pins that shielding).

### Structured diff model (`FileDiff` hunks) for the diff viewer (macapp) — 47b / VCS-foundation follow-up

**What:** Give `VCSProviding` a structured per-file diff (a `FileDiff` of hunks/lines) instead of the
current git-format unified-diff **text**, and rewrite `DiffViewer` to consume it — unlocking
ignore-whitespace, word/intra-line diff, per-hunk/line staging, and diff-edit (the jayjay feature set).

**Why:** The diff viewer today parses git-format text (`UnifiedDiff.parse`) fed by `GitProvider`
(SwiftGitX `Patch` → text) and `RustJJProvider` (`jj diff --git` CLI text). That's the deliberate
Option-1 first cut — it works and keeps one renderer — but text is a lossy intermediate for the
features above. Both backends already expose structured diffs natively (libgit2 hunk callbacks;
jj-lib diff regions / a `computeNativeDiff` over old+new content, as jayjay does), so a structured
model would be lib-native end-to-end. Deferred because no shipped feature needs it yet, and the
rewrite touches the whole diff UI (regression surface).

> Note: the earlier "evaluate libgit2 for git diffs" framing is obsolete — git already reads through
> SwiftGitX/libgit2 (status, changeset, working + commit diff, `fileContent`). The open question is no
> longer *which* git library, but *text vs structured hunks* at the `VCSProviding` seam.

**How to start:** Add a structured `FileDiff`/`Hunk`/`Line` model + a `VCSProviding.structuredDiff`
(or evolve `fileDiff`/`workingFileDiff` to return it); git via `git_diff`/`git_patch` hunk callbacks,
jj via jj-lib regions or `compute(old,new)` fed by `fileContent`. Reuse the existing `DiffCache` +
`maxDiffBytes` gate. Rewrite `DiffViewer` (and `IntraLineDiff`/side-by-side pairing) to consume hunks.

**Depends on:** the shipped Option-1 diff pipeline (`VCSProviding.fileDiff`/`workingFileDiff` +
`DiffResolver` + `DiffViewer`). Touches `Core/VCSProviding.swift`, `GitProvider`, `RustJJProvider`,
`jj_backend.rs` (+ UniFFI), `Core/DiffResolver.swift`, `Views/DiffViewer.swift`.

**Priority:** P3 (build when a feature — ignore-whitespace / word-diff / staging / diff-edit — needs it).

### Unify `workingStatus` onto the `VCSProviding` protocol (macapp) — VCS-foundation follow-up

**What:** `workingStatus` is the one VCS read that never made it onto the `VCSProviding` protocol.
`GitProvider.workingStatus` returns a git-shaped `GitWorkingStatus`; `RustJJProvider.workingStatus`
returns the app `WorkroomStatus`. Both are concrete, off-protocol, and differently-shaped, so
`WorkroomStatusResolver` bridges each backend by hand (`resolveGit` maps `GitWorkingStatus` →
`WorkroomStatus`; `resolveJJ` calls the jj one directly).

**Why:** Every other read (log/changeset/fileDiff/workingFileDiff/fileContent/currentRef) is on the
protocol with one app-native return; `workingStatus` is the odd one out. Unifying it removes the
special-casing in the resolver and lets a future backend (or a mock) satisfy status through the same
seam. `GitWorkingStatus` (`GitProvider.swift:335`) is explicitly a placeholder — its own doc says the
jj status "unifies onto a shared `VCSProviding.workingStatus` in the follow-on."

**How to start:** Define a backend-neutral working-status return (the app already has `WorkroomStatus`
+ the jj `@`/`@-` disclosure model; give git the same shape, `.parent`/`jjWorkingCopy` fields nil for
git). Add `func workingStatus(root:) async throws -> …` to `VCSProviding`; have both providers return
the unified type; drop the `GitWorkingStatus` bridge in `WorkroomStatusResolver`.

**Depends on:** the VCS read foundation (shipped). Touches `Core/VCSProviding.swift`, `GitProvider`,
`RustJJProvider`, `Core/WorkroomStatusResolver.swift`.

**Priority:** P3 (consistency/cleanup; the hand-bridged path works today).

### Git-side errors still flatten to `.io` (macapp) — error-taxonomy follow-up

**What:** `GitProvider` throws `VCSError.io("\(error)")` from every catch, so nothing on the git path
can reach `.lockContention` / `.notFound` / `.unsupportedRepo`. The jj path is now classified at the
source; git isn't.

**Why it wasn't done with the jj half:** the blocker is deliberate and documented in `GitProvider`'s
own header — binding SwiftGitX's typed error (`catch let e as SwiftGitXError`) trips a **Swift 6 SIL
ownership error** across the async boundary, so the provider catches untyped on purpose. Classifying
would mean sniffing error *strings* (fragile, locale-adjacent) or getting the typed catch to compile.
Note the status path depends on today's behaviour: `.io` → `.notRepository` is the honest answer for
git's most common failure (a path that isn't a repo), so this is not a silent lie the way the jj cases
were — it's a missing distinction (`index.lock` contention in particular, which would map to `.busy`).

**How to start:** re-test the typed catch on the current toolchain (the SIL bug may be fixed); if it
still crashes, isolate the typed binding in a small synchronous helper the async path calls. Then map
libgit2's `GIT_ELOCKED`/`GIT_ENOTFOUND`/`GIT_ENOTREPO`-shaped cases onto the taxonomy.

**Depends on:** nothing. Touches `Core/GitProvider.swift`.

**Priority:** P3 (no wrong diagnosis today, only a coarse one).

### Git diff shows one side when a file is both staged and re-modified (macapp) — FIXED

**What:** `GitProvider` working diff/status use `entry.workingTree ?? entry.index`, so a file that is
staged AND further modified in the worktree renders only the working-tree (index→worktree) delta, not
the combined HEAD→worktree change.

**Fixed:** `workingFileDiff` now detects when a status entry carries BOTH an `.index` and a
`.workingTree` delta and, in that case, builds the diff from the file's HEAD blob (`nil` if it's new
since HEAD) to its current on-disk content (`GitProvider.combinedWorkingDiff`) — the same technique
`workingPatch`'s `.conflicted` case already used for a HEAD→worktree read. Covered by
`VCSProviderConformanceTests.testWorkingFileDiffCombinesStagedAndFurtherModifiedEdits` (staged-modify
+further-edit, and staged-add+further-edit).

**Priority:** done.

### The jj snapshot ignores the user's real jj/git config (macapp) — VCS-foundation eng-review

**Status: the config stack itself has LANDED.** `wr-vcs-core/src/jj_config.rs` now layers the user's
real configuration (`$JJ_CONFIG`, else `~/.jjconfig.toml` + `$XDG_CONFIG_HOME`/`~/.config/jj/config.toml`
+ `conf.d/*.toml`) over jj's defaults, and all three call sites (`open`, `snapshot_working_copy`,
`materialize_options`) read it. That fixes the two consequences this entry never named, both of which
were live for **every** jj user rather than only non-default configs:

- **Every snapshot stamped an EMPTY committer.** `for_rewrite_from` sets
  `commit.committer = settings.signature()` unconditionally, and defaults-only settings carry
  `user.name = ""` / `user.email = ""`. Mostly invisible (`jj log` shows the author) and self-healing
  on the next real `jj` command, but NOT if `@` is pushed as-is — which the app's Push button does via
  `jj git push --change @`. Pinned by `tests/committer_identity.rs`, which fails with `<>` against the
  old code.
- **Signatures were dropped.** `Signer::from_settings` read `signing.backend = "none"`, so
  `can_sign()` was false and a rewrite of an already-signed `@` discarded its signature under the
  default `behavior = "keep"`. Now works for free, since the signer is built from these settings.

**What remains** (the original scope of this entry — the settings now reach jj-lib, so these follow,
but none is verified): `core.fsmonitor`, `working-copy.eol-conversion`, `working-copy.exec-bit-change`
and `ui.conflict-marker-style` are all derived from `TreeStateSettings::try_from_user_settings`, so
they should now be honoured — but no test covers them. The custom `core.excludesFile` chaining in
`base_ignores` is genuinely still missing. **Repo-level config is also still unread**: jj 0.43 keeps it
under `~/.config/jj/repos/<hash>` rather than `.jj/repo/config.toml`, which the current chain does not
resolve.

Original description follows.

**What:** `snapshot_working_copy` built its settings from jj's **built-in defaults only** —
`UserSettings::from_config(StackedConfig::with_defaults())` — and jj-lib derives
the whole of `TreeStateSettings` from those settings (`local_working_copy.rs`
`try_from_user_settings`): `ui.conflict-marker-style`, `EolConversionMode`
(`working-copy.eol-conversion`), `working-copy.exec-bit-change`, and `FsmonitorSettings`. So on the
one code path that *mutates* the repo, our snapshot can behave differently from the user's own `jj`:

- **fsmonitor is always off.** A user with Watchman configured (`core.fsmonitor`) still gets a full
  filesystem crawl — on every 15s status sweep, fanned out per workroom. The perf cost scales with
  repo size and is invisible to us.
- **EOL conversion / exec-bit policy are the defaults**, so a repo configured otherwise gets an `@`
  rewritten on different rules than `jj` itself would use.
- Originally filed narrower (custom `core.excludesFile`): the base_ignores fix (b7dd9b7d) chains
  git's default XDG global excludes (`~/.config/git/ignore`) + repo `.git/info/exclude` but never
  reads a custom `core.excludesFile`, so those patterns are skipped by the auto-status snapshot.

**Not affected (checked):** per-file conflict detection. `ui.conflict-marker-style` is only consumed
when *materializing* conflicts to disk (the checkout path), which this core never does; snapshot's
marker parse-back goes through `conflicts::update_from_content`, which keys on the stored
`materialized_conflict_data` marker length, not the style.

**Second site, added later:** the native ± line counts (`changed_files` → `materialize_options()`)
materialize a conflicted file to count its marker lines, so `ui.conflict-marker-style` and
`merge.hunk-level`/`merge.same-change` DO change that number. It reads jj's defaults today, on purpose
and for the same reason as the snapshot; when this entry lands, both call sites want the real settings,
not just the snapshot.

**How to start:** the config stack is loaded (`jj_config.rs`). What is left is chaining a custom
`core.excludesFile` in `base_ignores`, resolving jj 0.43's repo-level config under
`~/.config/jj/repos/<hash>`, and testing that the fsmonitor / EOL / exec-bit settings actually take
effect now that they reach jj-lib. Test on throwaway repos only — this is the lock-taking,
`@`-rewriting path.

**Depends on:** the base_ignores fix (shipped) and the config stack (shipped). Touches `jj_config.rs`
and `jj_backend.rs` (`base_ignores`).

**Priority:** P3 for what remains (only bites non-default configs); the identity + signing half that
bit everyone has shipped. The fsmonitor half is still a real perf item on large repos.

### Offer to repair a stale jj working copy from the app (macapp) — error-taxonomy follow-up

**What:** When a workroom reports `.staleWorkingCopy`, offer the repair inline (a button that runs
`jj workspace update-stale`) instead of only naming it in the Changes panel's text.

**Why:** the taxonomy work made the state *visible* and *honest* — the row no longer claims "not a
repository", and the panel says what to run — but the fix is still a manual trip to a terminal. The
state is reachable in ordinary use: workrooms of one project are jj **workspaces** of one repo, so a
`jj rebase`/`jj abandon` in workroom A can rewrite workroom B's `@` and leave B stale until B is
updated — often surfacing as a confusing error in a *different* workroom from the one the user
actually acted in, with nothing on screen connecting cause to effect. Deliberately not done with the
read work: recovering a working copy is a **write**, and every VCS write belongs to the Phase-2
write-actions chunk (its own confirmation + undo story), not to a status probe. jj-lib exposes
`Workspace::recover`/`RecoverWorkspaceError` for it.

**Detection needs no new plumbing — checked 2026-08-14, folded in from a since-deleted duplicate
entry that assumed otherwise.** `AppStore.statusWorkItems()` already builds one status-read item per
workroom per project, unconditionally — not just the focused one — and the sweep it feeds
(`refreshWorkroomStatuses`, triggered on load/app-focus/selection) already runs `resolveJJ` for every
open workroom, which already maps jj's stale-snapshot error onto `VCSStatusFailure.staleWorkingCopy`.
So a sibling left stale by a rebase is already caught on its own next routine sweep, with no proactive
cross-workspace scan and no per-op cost added. The only gap this entry needs to close is presentation
(the button) plus the write op itself — not detection.

**Depends on:** the shipped `StaleSnapshot` classification (`jj_backend.rs` `snapshot_working_copy`)
and `VCSStatusFailure.staleWorkingCopy`. Relates to "VCS write actions — Phase 2".

**Priority:** P3 (the state is now self-explaining; this saves the trip to a terminal).

### Background fetch — cadence policy + Settings toggle (macapp) — PARTIALLY SHIPPED

**Status:** the on-focus half has **shipped** with the VCS toolbar. `RemoteStateModel.autoFetchIfDue`
fetches when the inspector gains focus, interval-guarded (5 min per project), gated on the inspector
being visible with the Changes section active, skipped entirely under the UI-test fixture, and silent
on failure — it sets the toolbar's inline error but raises no alert and never blocks a read.

**What's LEFT:** the two things this entry originally said were the reason not to "just add a fetch" —
a real cadence policy (a periodic timer, not only focus) and a **Settings toggle** to turn it off. The
5-minute interval is currently a hardcoded constant with no UI. Also worth revisiting: whether an
unattended machine should auto-fetch at all, which is a preference question, not a technical one.

**Why the staleness reasoning below still stands:** it is the clearest writeup of the problem in the
repo, and the toolbar's ahead/behind counts inherit it exactly — they are computed from local
remote-tracking refs, so they are only as fresh as the last fetch. That is why the toolbar shows "last
fetched N ago" beside the counts rather than presenting them as fact.

---

**What (original):** A periodic / on-focus `git fetch` (and `jj git fetch`) so remote-tracking refs —
and therefore the History pane's unpushed badge — reflect the server rather than the last manual fetch.

**Why:** Every push-state answer in the app is local knowledge: `GitGraph` walks
`HEAD --not refs/remotes/origin/*` and the jj core evaluates `ancestors(<tracked @origin tips>)`.
Neither touches the network. So a commit pushed from another machine keeps its badge until you fetch,
and a commit that was force-pushed away still reads as pushed. The badge tooltip is honest about this
("based on your local remote-tracking refs"), but admitting it isn't fixing it.

**Pros:** The badge (and anything later built on the same reads — ahead/behind counts, a push action)
becomes truthful without the user doing anything.

**Cons:** This turns a pure local read into a network feature: auth prompts for private remotes, rate
limits, timeouts, and partial failures on a path that today cannot fail. It needs a cadence policy and
almost certainly a Settings toggle — "just add a fetch" is the wrong shape.

**Context / how to start:** The read path itself needs no change — a fetch only has to write refs; the
per-project watcher (`AppStore.handleRootBranchChange`, which watches each project's `.git`/`.jj`) then
repaints History automatically, exactly as it does after a local push. So the work is entirely about
*when* to fetch and how to fail quietly: pick the trigger (app focus + an interval), keep it off the
synchronous log-read path, decide the credential story (the status sweep already shells `gh`, so there
is precedent for network reads), and surface failure without a modal. Deliberately NOT done as part of
the badge: see the "Staleness" trap in the unpushed-badge plan.

**Depends on:** the unpushed badge (shipped) and on-focus auto-fetch (shipped). Wants a `Defaults` key
+ Settings row, and `RemoteStateModel.autoFetchInterval` lifted out of a constant.

**Priority:** P3 (on-focus fetch covers the common case; a user who wants it OFF currently can't).

### Three independent change-badge palettes (macapp) — jj conflict-status follow-up

**What:** the same change-kind badge is coloured by three separate mappings: `ChangeBadge`
(`Core/ChangeBadge.swift`, theme tokens — extracted from `ChangesPanel` when the conflict badge was
fixed), `ChangesetDetailView.badgeColor` (hardcoded `.green`/`.yellow`/`.red`/`.orange`), and
`DiffViewer.changeColor` (same hardcoded set).

**Why:** this split is *why* the conflict badge diverged in the first place — the panel had no orange
to reach for, so `.conflicted` borrowed deletion's red and a conflict read as a removal. Two of the
three mappings also ignore the active theme entirely.

**How to start:** have `ChangesetDetailView` and `DiffViewer` adopt `ChangeBadge.letter`/`.color` (and
the `tokens.conflict` colour) instead of their own switches. Note this restyles *every* kind in both
views, so it wants a deliberate visual pass rather than a drive-by change.

**Depends on:** `ChangeBadge` (shipped). Touches `ChangesetDetailView.swift`, `DiffViewer.swift`.

**Priority:** P3 (consistency + theme correctness; no functional bug).

## P3 — Terminal, panes, and focus

### Consolidate terminal focus authority + cross-window reconciliation (macapp) — focus-desync follow-up

**What:** (1) Collapse the ~5 duplicated "make first responder + `setSurfaceFocused`" call sites in
`GhosttySurfaceView`/`TerminalContainerView` into one guarded helper; (2) add window key-gain focus
reconciliation so the focused pane's surface reclaims first responder when the app window
reactivates (Cmd-Tab / Mission Control) and first responder had drifted to a non-terminal view.

**Current state:** The reported bug — arrows/letters dead when a TUI selection prompt appears in a
freshly-mounted/unfocused-looking pane — is **fixed**: `createSurface` now re-syncs the libghostty
focus flag when the surface is created while the view already holds first responder
(`GhosttySurfaceView.adoptFocusIfFirstResponder`, tested by `TerminalFocusAdoptionTests` +
`TerminalFocusAdoptionLiveSurfaceTests`). Focus-set logic still lives in several places
(`becomeFirstResponder`, `mouseDown`, search hand-back `:171`, `viewDidMoveToWindow`, `applyFocus`),
and `WindowRegistry`'s `didBecomeKeyNotification` observer still only updates `lastActiveStore`, not
terminal focus.

**Why:** The duplication has produced repeated focus-race fixes (#3 splits, the diff-pane fix, the
`viewDidMoveToWindow` backstop, and now this one) — each patch adds another copy and the next race
slips through the gap. One guarded helper removes that class. Cross-window reconciliation is the one
drift trigger the createSurface fix does not cover (surface already exists; first responder moved
away). Surfaced by `/plan-eng-review` (DRY finding) and the Codex outside-voice pass, deliberately
deferred to avoid refactoring focus timing before the root cause was confirmed.

**How to start:** Extract `focusTerminal(surface:)` with a single guard set; route the existing call
sites through it. For reconciliation, extend the `WindowRegistry` `didBecomeKeyNotification` handler
(`Core/WindowRegistry.swift:50`) to restore first responder to the focused pane **only** when no
sheet is open AND the current first responder is nil/the window/a removed responder (NOT a live text
field or sidebar table — codex's caveat: "no sheet" alone is insufficient). Unit-test the guard as a
pure decision.

**Depends on:** the shipped createSurface focus-sync; also relates to the queued first-responder
stale-state recheck noted under "Workroom split: deferred follow-ups" (`TerminalContainerView`
`applyFocus`) — fold both into the one helper.

**Priority:** P3 (primary bug fixed; this is the DRY/robustness follow-up that prevents the next
focus race).

### Workroom split: deferred follow-ups (macapp) — #23

**Shipped:** drag a workroom tab onto a pane edge → a nested, resizable side-by-side split of full
terminal UIs, same feel as the ⌘D terminal panes (`Views/WorkroomSplitView.swift`,
`Core/AppStore+WorkroomSplit.swift`, generic `PaneLayout<Leaf>` / `PaneTreeLayout`). The bar always
shows; `RootView` always routes the detail through `WorkroomSplitView` (single = `.leaf(selected)`).
The pieces below were explicitly deferred — each small, none blocking.

- **⌥⌘-arrow focus between workroom panes** — `PaneTreeLayout.adjacentPane` is already generic and
  ready; only the key-monitor wiring is missing. Deferred to avoid clashing with the terminal-level
  ⌥⌘arrows (which navigate the focused workroom's *terminal* split) — needs a precedence decision.
- **Drag-a-pane-out-to-dissolve** — removal today is the per-pane ✕ (strip trailing) + clicking a
  non-member tab; the terminal split's "drag the grip up out of the panes" gesture isn't wired for
  workroom panes.
- **Per-pane activity border-flash** (partial) — the *terminals hosted inside* a workroom pane flash
  via `PaneLeafView`'s `activityPulses` handler, but the workroom **pane itself** doesn't flash the way
  a terminal split pane does; workroom-level activity surfaces via `WorkroomTabChip` tinting instead. A
  presentation difference, not a missing signal.
- **Queued first-responder stale-state recheck** (`Views/TerminalContainerView.swift:78`) — `applyFocus`
  enqueues `makeFirstResponder(view)` on `DispatchQueue.main.async` and re-checks only
  `firstResponder !== view`, not a *fresh* focus condition, so a stale enqueue could in theory flip
  focus cross-target. Largely defused already by the `surfaceActive` gate (a non-focused workroom pane
  passes `isFocusedPane=false` → never enqueues); this is the residual race within terminal-pane splits.
  Fix would re-read live focus state inside the async block rather than relying on the captured value.

**Priority:** P3 (polish on a shipped feature).

### Two split paths still bypass the pane floor (macapp) — pane-min-width follow-up

**What:** `TerminalSessions.fits` is the single floor guard (`minPaneWidth` 300 / `minPaneHeight` 120,
`eb762b87`). Two paths don't consult it, and can't today, because it measures a
`GhosttySurfaceView`'s bounds and neither path has one:

- **`AppStore.insertWorkroomSplit`** (`Core/AppStore+WorkroomSplit.swift`) — no fit guard at all, and
  workroom panes are the one place each pane renders its *own* `TerminalTabStrip`, whose diff toolbar
  alone is ~145pt (the measurement 300 was derived from). With ~700pt of content, dragging a third
  workroom chip in nests a split at `total: 348`, which trips `lengths`' even-split fallback and
  yields two 172pt panes.
- **`TerminalSessions.fits` exempts content panes** — `guard let surface else { return true }`, so
  every diff / file / changeset pane is outside the floor that exists *because of* the diff toolbar.
  ⌘D on a diff pane in a 400pt split is permitted and gives two ~198pt panes.

**Why it's still open:** both need a measured pane rect where only a surface is available today. The
views already compute one (`PaneTreeLayout.plan(_:in:)` → `plan.panes`), so the fix is to pass the
destination pane's size in at the call site rather than store frames in the model — but the workroom
drop path threads its target through a `dropTarget: (CGPoint) -> (sid, edge)?` closure owned by
`RootView` and handed down through `WorkroomSplitView` → `WorkroomPaneLeaf` → the tab bar, so it's a
signature change across several files on a drag path that only XCUITest can exercise.

`splitTab` and `moveTabIntoSplit` — the two that only needed the surface already in hand — are fixed.

**Priority:** P3 (bad layout, recoverable by resizing; no data loss).

### Pane-footer truncation is manual-verify only (macapp) — #136 follow-up

**What:** The pane footer's path segment (`TerminalStatusBar.pathSegment`) carries two deliberate
layout decisions that **no test covers**: `.truncationMode(.head)` (keep the tail, because a
repo-relative path's discriminating part is its filename and immediate directory) and
`.layoutPriority(1)` (the branch yields space before the path does).

**Why it's open:** neither test layer can see it.

- The **unit gate** can't assert SwiftUI text at all: macOS only materializes SwiftUI's a11y elements
  for a live AX client, so an `NSHostingView` in a test process reports an `AXGroup` with 0 children
  (documented at `macapp/WorkroomAppTests/HistoryCommitCardTests.swift:9-13`). `PaneRenderingTests`
  works only because `GhosttySurfaceView` is a real `NSView` it can count.
- **XCUITest** reads the accessibility *label*, which carries the full untruncated string no matter
  what is actually drawn — so a test passes while the branch has collapsed to nothing on screen.

Automating it would need image-snapshot testing, which this repo has none of and which would churn
on every theme and font change. So it's an eyeball check in the #136 verification steps: split a diff
pane narrow and confirm the path keeps its filename while the branch truncates first.

**Depends on:** nothing, but the entry above shrinks it — content panes are exempt from the 300pt
pane floor (`TerminalSessions.fits` returns `true` when there's no surface), which is what makes a
~198pt content pane reachable in the first place. Fix that and this gap mostly stops mattering.

**Priority:** P3 (degraded legibility in a narrow split; no data loss, no wrong information).

### AppKit tracking-handle divider for an even wider resize target (macapp) — #83 follow-up

**What:** Replace the SwiftUI invisible-`Rectangle` resize divider (`SplitDivider` in
`Views/PaneTreeView.swift`, `WorkroomSplitDivider` in `Views/WorkroomSplitView.swift`) with a
dedicated AppKit tracking/drag handle (pattern: the existing `InspectorResizeHandle`) so the grab
target can extend *over* the terminal surface without stealing its mouse input.

**Why:** Issue #83 widened the hit zone to `PaneTreeLayout.dividerHitThickness` (8pt = the 4pt gutter
plus the 2pt pane padding on each side). That's the safe ceiling for the overlay approach — any wider
would overhang the live libghostty surface and intercept text selection, OSC8 link clicks, the
right-click menu, and TUI mouse reporting near the gutter. A real AppKit handle owns its own tracking
area, so it can be larger and still not fight the terminal NSView.

**How to start:** Model it on `InspectorResizeHandle`; mount one per `PaneDividerFrame`, positioned on
`d.rect`, calling the same `onRatio`/`setRatio` path the current divider uses. Keep the visual gutter
invisible (the panes' own borders mark the boundary).

**Depends on:** shipping #83 first, then real-use feedback that 8pt still feels fiddly. Surfaced by the
Codex outside-voice pass during `/plan-eng-review`.

**Priority:** P3 (8pt already doubles the old 4pt target; only revisit if users still find it tight).

### Memory / live-surface diagnostics (macapp)

**What:** Lightweight instrumentation of live `ghostty_surface_t` count and process memory, to
catch leaks/growth at high tab counts.

**Why:** Each surface is a GPU-backed Metal layer; the plan flags the 50–100-tab surface budget as
"measure, don't assume." Occlusion is wired (A4) so off-screen surfaces idle, but magnitude at
Workroom's tab counts is unverified. Muxy ships a 458-line `MemoryDiagnostics` for this reason.

**How to start:** A periodic sampler logging `tabsByTarget` leaf count + `mach_task_basic_info`
resident size via `os.Logger`; optionally a debug overlay. Keep it far lighter than Muxy's — a
counter + a memory read, not crash-crumb recovery (D1). (None of this exists yet — no
`mach_task_basic_info` read, no surface-count logging.)

**Depends on:** `TerminalSessions` (surface inventory), `GhosttyApp` (`os.Logger` already set up).

**Priority:** P3 (diagnostic aid; pair with the manual surface-budget QA pass).

### OSC 52 clipboard-confirmation policy (macapp)

**What:** A real policy/UI for terminal-app clipboard access (OSC 52) — the runtime's
`read_clipboard_cb` / `write_clipboard_cb`. Today writes are gated to `text/*` mime and reads use
Ghostty's permissive default (auto-allow); `confirmReadClipboard` is a stub, so a deliberate
prompt/allowlist is deferred.

**Why:** Code-review finding #7. OSC 52 lets a remote program read/write the system pasteboard;
the permissive default is fine for a beta (it matches Ghostty's own default) but a security-minded
user should be able to require confirmation.

**How to start:** Implement `confirm_read_clipboard_cb` to surface a prompt (or consult a
`Defaults.Keys` policy: allow / prompt / deny); gate `write_clipboard_cb` similarly. Decide the
default (Ghostty = allow).

**Depends on:** the clipboard callbacks already wired
(`macapp/WorkroomApp/Core/GhosttyRuntimeAdapter.swift`, `Core/GhosttyApp.swift`).

**Priority:** P3 (permissive default is acceptable for the beta).

### Quick-switcher deferrals (macapp) — #132 follow-ups

**What:** Five things the ⌥Tab / ⌃Tab switcher shipped without, deliberately. Independent of each
other; take them one at a time.

- **MRU order in the ⌘O Open Workroom picker.** `SwitcherRecency` already answers "what did I use
  last", so `OpenPickerModel` could rank by it instead of alphabetically. Cheap, but it reorders a
  shipped, tested surface (`OpenPickerModelTests`) — hence deferred until we've lived with MRU in the
  switcher and know it feels right there first.
- **Scope ⌥Tab to the current Space.** A cross-window commit to a window on another Space animates the
  Space switch for ~0.5–1s. Nothing is wrong, but it's a jarring result for a keystroke that reads as
  instant. Either filter `QuickSwitcher.workroomSlots` by `hostWindow?.isOnActiveSpace` (and lose the
  ability to reach those workrooms at all) or leave it; decide from use, not from taste.
- **The shared `UnreadBadge` still draws the RAW accent.** The rail passes its own corrected pair
  (`Palette.nsBadgeFill` == `nsRing`, ink measured), because a themed accent can sit close to the
  surface it's on — the sidebar and toolbar badges have the same exposure and no correction. Now a
  small change: `ThemeTokens.contrastRatio` is genuinely WCAG since `dfcc0bd8`, so
  `legible(accent, on: host, target: 3.0)` at the component's own call sites means what it says.
- **The 10s session ceiling cancels silently.** A stuck modifier can't leave the rail up forever, so
  `QuickSwitcherReducer.sessionCeiling` ends the session — with **no commit**, so a user who held ⌥ for
  eleven seconds while reading the rail gets nothing. Arguably the timeout should commit the cursor
  instead. A product call, not a bug: pick one and say so in the reducer's doc comment.
- **⌃-click on the pane rail is unverified.** ⌃-click is a secondary click, and the rail panel is never
  key, so it may not deliver a `.onTapGesture` at all. Needs a **real mouse** — this repo has twice
  been lied to by synthetic input (`macapp-textselection-swallows-taps`,
  `macapp-hover-slide-release-only`), so an XCUITest pass here would prove nothing.

**Why:** each of these was written down in the #132 plan's out-of-scope table and would otherwise be
lost with it. Two other entries from that table are now **moot**: the window-capture layer was built
and then removed (an aspect-fit terminal thumbnail at card size is a grey smudge that looks like every
other terminal), so "a libghostty damage callback for thumbnail freshness" and "per-pane sensitive
marking / screen-sharing auto-suppress" no longer have a subject — `Core/Snapshots/` is gone and the
rail draws marks and miniatures instead.

**Depends on:** nothing. The badge item wants `dfcc0bd8` (the contrast-metric fix), which has landed.

**Priority:** P3 for all five.

### A live "all terminals" mini-viewer — revisit, the old premise was wrong (macapp), filed 2026-08-14

**What:** re-examined the standing belief that a live dashboard of many running terminals ("show every
pane, with a detail view") isn't possible because libghostty doesn't support it. **That's not what
happened, and it's worth correcting in place rather than re-citing.** The only thing actually built and
shipped under #132 was OS-level capture (`8a1d2547`, "rail thumbnails via own-window capture") —
`SCShareableContent.currentProcess`, no TCC/permission, real pixels confirmed end-to-end. It was
**reverted** (`455d28e8`) and replaced by hue+monogram marks (`8de09cba`) for a UX reason — "an
aspect-fit terminal thumbnail at card size is a grey smudge that looks like every other terminal" — not
a technical block. **libghostty was never in that path at all**; the capture happened entirely at the
AppKit/ScreenCaptureKit layer, over the window's on-screen pixels.

**Hard requirement (stated explicitly, 2026-08-14): the mini view must be identical to the full pane,
not a resized/reflowed one.** Ruled out on that basis: shrinking a pane by calling
`ghostty_surface_set_size`/reducing font-size recomputes columns/rows, which reflows text and sends a
real resize signal to whatever's running in the pane (confirmed existing behavior at this pin —
`QA-libghostty.md:18-19`, "resize the window → reflows cleanly"). That's a different render of the same
session, not a miniature of the current one, and it's structurally exclusive with the real pane (same
NSView, one superview at a time — can't show both at once). Ruled out for that reason, not revisited
below.

**Validated path: a continuous `SCStream`, not the one-shot capture #132 used.**
`ScreenCaptureKit` has two capture modes; #132/T12 only used the weaker one (`SCScreenshotManager`,
single frame per call). `SCStream` is a persistent stream that pushes fresh frames as the source
changes, with **output width/height set independently of the source's real point size**
(`SCStreamConfiguration`) — the compositor scales server-side. **Confirmed empirically, not assumed
from docs (2026-08-14):** a standalone compiled Swift binary (`swiftc`, own process, no Xcode project)
opened a real `NSWindow`, fetched `SCShareableContent.currentProcess`, built
`SCContentFilter(desktopIndependentWindow:)`, and started a real `SCStream` against it —
**31 frames delivered over 3s, exit 0, no Screen Recording permission prompt, no TCC error.** Same
own-process carve-out the one-shot method already used, now confirmed to extend to the continuous
streaming API too, which was the actual open question this entry used to carry.

Why this is the right fit for "identical, live, and doesn't monopolize the surface": the source pane's
real `ghostty_surface_t` geometry is never touched — no `set_size`, no font change, no reflow, no
resize signal to the child process. What's captured is the exact same columns/rows/content as the full
pane, continuously, and — since it's compositor pixels, not the `NSView` object itself — the same pane
can be full-size in its tab **and** live in a preview simultaneously (see the hover-preview entry below,
which is the concrete first use of this).

**One real, unremovable constraint:** the source still has to be actually rendering and mounted
on-screen for there to be anything to capture. A tab that libghostty has occluded (or a view AppKit
isn't compositing at all — confirmed the case for a backgrounded tab, see the hover-preview entry) has
no pixels to stream. This is physical, not a technique flaw — every approach that shows a live
background pane costs the same GPU work the occlusion-skip optimization exists to avoid; `SCStream`
only makes delivery continuous and correctly-scaled instead of manually re-polling a screenshot.

**Two options considered and set aside, kept for context:**
- `ghostty_surface_read_text` (VoiceOver's own poll target, live regardless of on-screen visibility) —
  ruled out once "identical" became a hard requirement: `ghostty_text_s` is plain bytes, no
  color/attribute/cursor data, so it can never be visually identical to the real pane.
- Upstream **`libghostty-vt`** (new, unlinked cell/grid/color API) — still real, but a second dependency
  to vendor; `SCStream` gets the same "live and colored" result today with zero new dependency.

**Depends on:** nothing to start. The concrete first application is the hover-preview entry below.

**Priority:** P3 — no user complaint driving this; filed so the next person doesn't re-derive "we looked
into this, wasn't possible" from a premise that was never quite right, and doesn't re-litigate the
capture-mode question this entry just closed out empirically.

### Tab-hover live mini-preview (macapp) — planned 2026-08-14, reviewed 2026-08-14, plan-eng-reviewed

**Superseded by a full plan + eng review** — this entry's original draft (SCStream-only,
pixel-identical framing) is out of date; the reviewed plan corrected the architecture and closed 21
findings (2 architecture, 2 code quality, 17 outside-voice via Codex — 3 cross-model tensions, 14 direct
corrections). Full plan: `~/.claude/plans/ethereal-inventing-wolf.md` (eng review CLEAR, 0 unresolved).
Summary for anyone picking this up without the plan file:

- **Hard requirements unchanged:** live (not a static snapshot), only live while actually hovered, and
  the real pane's geometry (columns/rows) must never change — no `ghostty_surface_set_size` call, ever,
  from this feature.
- **Critical finding the original draft missed:** naively copying `TerminalContainerView.mount`'s
  re-home code sets `view.frame` to the small preview size *before* `addSubview`, which triggers
  `viewDidMoveToWindow` → `updateMetalLayerSize` → a real resize. Any implementation must never write
  `.frame`/`.bounds`/`.autoresizingMask` on the surface.
- **Architecture is now spike-first, two candidates, not SCStream-only:** (A) CALayer
  `sublayerTransform` scale-compositing — mount the real surface untouched, shrink it via a visual
  transform only; no new dependency, no capture pipeline; try this first. (B) The originally-planned
  continuous `SCStream` capture — still validated (no TCC), but requires a dedicated real-size,
  on-screen, unoccluded "parking" window per hover, whose actual unobtrusiveness is unverified (a Stage 0
  spike question, not assumed). A third outcome (shelve the feature, or redefine the "identical"
  requirement) is explicitly on the table if both candidates fail their spikes.
- **Occlusion must go through a single writer:** `TerminalSessions.reconcileOcclusion` stays the only
  caller of `surface.setVisible` — a hover claim is exposed via `beginPreview`/`endPreview(tab:session:
  for:)` methods (per-target, session-tokened, not a bare tab id — two sequential hovers of the same tab
  need to be distinguishable) that route through `reconcileOcclusion` themselves.
- **Testability:** a minimal `Scheduling`/`FrameSource` seam (not a full second-backend abstraction) keeps
  the state machine unit-testable without reopening a swappable-backend design.

**Depends on:** nothing blocking — Stage 0's spike is the very next step.

**Priority:** P3 → actively being implemented (see the plan file's Implementation Tasks, T0-T6).

### Stream the inline terminal agent's diagnosis into the banner — #49 follow-up

**What:** Show the diagnosis appearing live in the banner (claude `--output-format stream-json`)
instead of a spinner during the (blocking) call.

**Why:** Nicer perceived latency. Deferred deliberately, not dropped: (1) the diagnosis output is a
structured JSON object (`{summary, fix, detail}`) — that's what makes the "Insert fix" button
reliable (the on-demand eval validates it) — and streaming emits partial JSON deltas that don't
render nicely; (2) the inline diagnosis now runs on Haiku 4.5 (~2-3s), so the spinner is brief and
the payoff is marginal.

**How to start:** The clean approach that preserves the structured fix is to change the model's
output to "one-line prose summary, then a delimiter, then the JSON fix", stream the prose live while
parsing the JSON tail on completion. Needs: an incremental-stdout streaming runner (the current
`StatusCommandRunner` buffers to completion), a stream-json NDJSON delta parser, the split prompt +
parser, banner partial-text state, and its own entry in `AgentDiagnosisEvalTests`.

**Depends on:** the inline agent (#49, merged). Touches `AgentRunner`, `AgentPrompt`,
`TerminalAgentManager`, `TerminalAgentBanner`.

**Priority:** P3 (polish; marginal over a 2-3s spinner, and must not regress the structured fix).

## P3 — Inspector, window layout, and theming

### Back/forward doesn't reinstate the inspector section (macapp) — nav-history follow-up

**What:** `activeInspectorSection` is not part of a `NavLocation`, so ⌘[/⌘] never moves it. Add it to the
location and map content kinds to sections (`.diff`/`.file` → `.changes`, `.changeset` → the pane holding
History), suppressed under replay so it doesn't write the persisted default.

**Why:** narrower than it first looks, and worth stating so nobody re-scopes it wrongly:
`ActivitySection.changes` stacks `[.changes, .history, .pullRequest]` as sub-sections of **one** pane, so
moving between a diff and a commit needs no section switch at all — both lists are already on screen.
The only real case is **Files ↔ Changes**: open a file from the Files section, press Back to a diff, and
the pane is correct while the inspector still lists files, so no row highlights.

**How to start:** `AppStore.activeInspectorSection` (`@Published`, persisted in its `didSet`) plus the
`FocusedTabSelection` → `ActivitySection` mapping. `withHistorySuppressed` already exists for the
replay-side guard.

**Depends on:** nothing.

**Priority:** P3 (cosmetic — the detail pane, which is what the bug report was about, is correct in every
case; only the inspector's list can be the wrong one).

### Search section for the right activity bar (macapp) — activity-bar follow-up

**What:** A functional Search pane (find in files / content) as a new right-activity-bar section.

**Why:** The activity bar (`ActivitySection` + per-section `subSections`) is built to grow; Search
was the first candidate but has no functionality yet, so it was dropped from the initial bar (v1
shipped Changes + Files) to avoid a visibly-empty icon reading as unfinished.

**How to start:** Add a `.search` case to `Core/ActivitySection.swift` (label +
`systemImage: "magnifyingglass"` + its `subSections`) and a real Search pane body, wired into
`RightInspector.sectionBody(for:)`. A new `InspectorSectionKind` may be needed for the sub-section
identity. The DEBUG-only feature-flag staging pattern (considered and rejected for v1) is one option
to ship the scaffold before the search is real.

**Depends on:** the right activity bar (shipped). Touches `Core/ActivitySection.swift`,
`Views/ChangesPanel.swift` (`RightInspector`), a new `Views/SearchPanel.swift`.

**Priority:** P3 (new feature; not blocking).

### Profile inspector pane body during live divider-drag (macapp) — NSSplitView inspector follow-up

**What:** Verify there's no stutter when dragging an inspector section divider with a large Changes
set. The NSSplitView inspector (shipped) hosts each section body inside a native `NSScrollView`, so
a vertical divider drag changes only the pane's *viewport height* — the body's `NSHostingView` keeps
its intrinsic (content) height and its width is unchanged, so SwiftUI should NOT re-lay-out per
frame. This TODO is to confirm that under profiling, not a known regression.

**Why:** `ChangesPanel` can render up to ~200 non-lazy file rows. (An earlier version of this entry
put the worst case at ~400 across **two** lists — the jj Parent Commit group, its disclosure state and
its `Defaults` collapse flags are all gone; the panel is now one unified working-copy list for both
backends, so the ceiling is back to one list's worth.) The original eng-review of the migration plan
flagged per-frame re-layout as a risk; the scroll-view pane design should avoid it (drag = viewport
change, not document re-layout), but it hasn't been profiled.

**How to start:** Instruments (Time Profiler / SwiftUI body re-evaluation) while dragging the
Changes divider on a fixture with ~200 changed files. Only if jank shows: coalesce
resize → re-layout, or `.drawingGroup()` the body for the drag duration. Note `LazyVStack` won't help
here — the pane scrolls via AppKit `NSScrollView` with an intrinsic-size host, so there's no SwiftUI
clip rect to virtualize against.

**Priority:** P3 (likely already a non-issue by construction; confirm before optimizing).

### Raise the inspector's 520pt width cap (macapp) — column-layout follow-up

**What:** Decide whether `InspectorColumn`'s `maxWidth = 520` (and `SidebarColumn`'s 240-360) is still
the bound we want, now that the layout no longer forces the trade-off.

**Why:** 520 was inherited from the `NavigationSplitView` era, where it was a *safety* ceiling, not a
design choice: the native split shrank the `sidebar | detail` columns **proportionally** as the
inspector grew, so a wide inspector clipped the sidebar's labels even at a 1900px window, and the
private `NSSplitView` subclass refused `setDelegate:`/`setHoldingPriority:`. That machinery is gone —
`RootView.splitView` lays the three columns out itself (`SidebarColumn` | detail | `InspectorColumn` +
`ActivityBar`, inside a detail-only `NavigationSplitView` kept purely for the toolbar/hover context),
each column with its own min/max and its own persisted `Defaults` width. The sidebar holds its floor
and only the detail yields, so a wider inspector is now a one-constant change.

**How to start:** raise or drop `maxWidth` (`Views/InspectorColumn.swift:23`) and check the widest
panes at the new size (`DiffViewer` side-by-side, `ChangesetDetailView`, `HistoryPanel`) against the
detail column's own floor — a usable terminal width is the real constraint now, not the sidebar.

**Depends on:** the hand-rolled column layout (shipped: `RootView.splitView`, `SidebarColumn`,
`InspectorColumn`, `Defaults.sidebarWidth`/`inspectorWidth`).

**Priority:** P3 (only worth changing if a wide inspector is a real workflow need; 520 is a fine
default and the squeeze that made it load-bearing is fixed).

### Keyboard + VoiceOver parity for the edge-hover reveal (macapp) — #56 follow-up

**What:** Make the edge-hover sidebar reveal (issue #56) first-class for keyboard / VoiceOver users:
move keyboard focus into the panel when it reveals, restore focus when it hides, and post a
VoiceOver announcement on reveal/hide.

**Current state:** The reveal ships pointer-first (`Views/EdgeRevealSidebar.swift`). Escape-to-dismiss
is wired (`.onExitCommand`) and the panels carry `sidebar.reveal.{leading,trailing}` accessibility
identifiers, but there's no focus management or VO announce. Persistent keyboard/AX access already
exists via the View-menu toggles (`View ▸ Projects`, `View ▸ Notifications`) and the toolbar
sidebar/inspector buttons, so the docked sidebars remain fully reachable without a pointer — this is
polish, not an accessibility blocker.

**Why:** a hover-only affordance is invisible to keyboard-only and VoiceOver users; focus + announce
make the transient panel behave like a real sidebar for them too.

**How to start:** drive first-responder when `EdgeRevealReducer.revealed` flips (focus the panel's
list, restore the prior responder on hide); post `NSAccessibility.post(element:notification:)` on
reveal/hide. Focus management in a transient overlay is finicky (focus stealing, restore-on-hide
races) — prototype carefully and test with VoiceOver on.

**Depends on:** the #56 reveal panel (shipped).

**Priority:** P3 (polish; persistent keyboard/AX access already exists via the menu/toolbar toggles).

### Theming: auto-pair user `~/.config` themes into families (macapp) — #36 follow-up

**What:** Let loose theme files a user drops into `~/.config/ghostty/themes` surface as first-class
theme *families* (a light + dark pair) in the picker.

**Why:** #36 ships a curated set of pair-complete bundled families only — the picker lists those.
A user with their own theme files in `~/.config/ghostty/themes` currently has no way to pick them
from the picker (ghostty still resolves them for the *terminal* when a bundled name collides, since
`themePreview`/resolution favour `~/.config`, but they aren't selectable). Inferring families from
user files would make them first-class.

**How to start:** In `Core/ThemeService.swift`, add discovery of `~/.config/ghostty/themes` and
infer families from loose user files — e.g. name-suffix heuristics (`X` / `X Light`, `X Dark` /
`X Light`), or read an optional user manifest. Merge inferred families into the picker's family
list. Handle the ambiguous cases: a single-variant user theme (no obvious partner); a name that
collides with a bundled family.

**Depends on:** the #36 families model shipping first (done).

**Priority:** P3 (bundled families cover the common case; this is for users with custom schemes).

**Prior art (2026-08-06):** the 27→58 family expansion built and threw away exactly this heuristic
offline — suffix pairing (`X Dark`/`X Light`, `X`/`X Light`, `X Night`/`X Day`) over 604 candidate
files, plus dark/light classification by `perceivedBrightness(background) > 0.5`. It found 58 pair-
complete clusters. It also showed what a naive version adopts: another product's brand pair (`Muxy`),
a theme that fails the rail's contrast floor (`Violet Dark`, 3.94:1), six stock black-on-white
terminal defaults, and a byte-identical duplicate (`Zenbones` ≡ `Zenbones Light`). So the heuristic is
the easy half; the deny-list and a contrast gate are the real work.

### Use ghostty's native `theme = dark:<X>,light:<Y>` syntax (macapp) — RE-PRICED, not a fit for this batch

**What:** Replace our rewrite-the-conf-on-every-appearance-change path with the engine's own
per-appearance theme selection.

**Why we thought this:** libghostty accepts `theme = dark:<X>,light:<Y>` and picks the variant
itself. We instead write a single `theme = "<name>"` and, on every appearance change, rewrite
`~/Library/Application Support/Workroom/ghostty.conf`, then `ghostty_config_load_file`,
`ghostty_app_update_config`, then `updateConfig` on every surface
(`GhosttyApp.swift` `writeThemeConfig`, `TerminalSessions.applyThemeToAll`). Muxy already uses the
native form (`muxy/Muxy/Services/ThemeService.swift` `parseThemeSelection`).

**What verification against the pinned engine (sha `35e1a016`) actually found:** the two-variant
syntax itself works (`Config.zig:9837` `Theme.parseCLI` — `light:`/`dark:` keys, both required,
order-independent). But "the engine picks the variant itself" is false for a *live* surface:

- Which variant applies is resolved once, at config-derive time, from `_conditional_state.theme`
  (`Config.zig:4457`).
- `ghostty_app_set_color_scheme`/`ghostty_surface_set_color_scheme` (App.zig `colorSchemeEvent`,
  Surface.zig:4716 `colorSchemeCallback`) only **flip that state and fire a
  `.reload_config{.soft=true}` action** — neither one re-derives the config itself.
- `apprt/embedded.zig:267` `performAction` forwards every action straight to the host `action_cb`;
  there is no internal embedded-apprt handler that re-derives on our behalf.
- `GhosttyRuntimeAdapter.swift:127` doesn't handle `GHOSTTY_ACTION_RELOAD_CONFIG` — it falls into
  `default:` → `logUnhandled` → returns `false`.

So adopting this syntax needs either (a) implementing that action for both the app-scoped and
surface-scoped case, which means calling `ghostty_app_update_config`/`ghostty_surface_update_config`
back into the engine from inside `action_cb` while it's mid-`colorSchemeEvent` — the same kind of
reentrancy-off-callback-stacks hazard flagged for surface teardown (see the libghostty-surface-free
memory note) — or (b) keeping our own explicit `updateConfig` calls, where scheme-flip-before-derive
becomes a newly load-bearing ordering invariant (today's `applyThemeToAll` calls `reloadConfig`
*before* `setColorScheme`, which is harmless only because today's single-name theme has no
conditional state to get stale).

**Verdict:** not a fit for a pre-release stability batch. There's no bug behind the current
single-name-per-appearance path — it's shipped and correct — and the two ways to land the native
syntax are either an engine-callback reentrancy change or a same-risk reorder of existing calls, both
only verifiable by manually flip-testing OS appearance against live terminals. Re-pricing from "emit
both names once, drop `force:`" to "action-handling change with a re-entrancy hazard and a new
ordering invariant."

**Priority:** P2 → hold. Re-open only alongside deliberate engine-callback work, not as a drive-by.

### Profile and fix the theme picker's invalidation storm (macapp) — MEASURED, MOOT (2026-08-13)

**What:** Measure the picker's per-keypress cost, then stop every row re-rendering on every apply.

**Why we thought this:** `FamilyRow` holds `ThemeService.shared` and reads `theme.tokens`, while
each ↑/↓ calls `applyFamily`, which replaces `tokens` — so one arrow press invalidates every
instantiated row. The 2026-08-06 change cached bundled theme previews, which removed the disk reads
(up to 116 synchronous file reads per keypress at 58 families) but **not** the re-render. This is
the shape of the logged WORKROOM-2B App Hang, and the repo already has the proven remedy: pass the
needed values down instead of observing the service, then `Equatable` + `.equatable()` on the row.

**What measuring first actually found:** the storm is real (it does invalidate every row currently
materialized, by construction — `ThemeService` is `@Observable` and every row reads `tokens`) but
not remotely perceptible. `ThemePickerInvalidationTests.testArrowKeyReapplyRendersUnderTimeCeiling`
hosts the real `ThemePicker` at its production popover size (300×420, ~8 rows materialized by the
`LazyVStack`) and drives one `applyFamily` call with no terminal registered (isolating the picker's
own render cost from the separate, already-shipped engine-reload path). Measured: 8 row rebuilds,
~0.07s elapsed — three orders of magnitude under the multi-second WORKROOM-2B hang threshold this
test family exists to catch, and most of that is `settle()`'s own poll granularity rather than row
work. No fix applied — the known remedy (hoist values + closures, `Equatable`/`.equatable()`) would
be real code churn to a subsystem that isn't the problem, for a payoff nobody would feel.

**Priority:** P3 → closed. The regression test (asserts `< 0.3s`) stays as the tripwire if the
preview cache or something else on this path regresses later.

### Ship the remaining vetted theme families (macapp)

**What:** Three accessibility families — `GitHub Colorblind`, `Pierre`, `Adwaita` — and ten
same-family shade variants: Catppuccin Frappé + Macchiato, Tokyo Night Storm + Moon, Rosé Pine Moon,
Kanagawa Dragon, Gruvbox Hard, Modus Tinted, GitHub Dimmed, Nord Wave.

**Why:** all were swept against the real contrast floors during the 2026-08-06 expansion and came back
clean, so the measurement work is already done. The ten variants need only **one** new file each — the
light side already ships.

**Pros:** near-zero cost per family; accessibility is the one need in the recorded inclusion criterion
(`Resources/ghostty/themes/SOURCE.md`) that stays thinly served even after `GitHub High Contrast` and
`Xcode High Contrast` landed.

**Cons:** criterion rule 3 (distinct palette, not a shade of one we ship) argues *against* the ten
variants — they are exactly what that rule was written to exclude. Record that tension rather than
pretending the criterion endorses them. The a11y families' light sides are plain `#ffffff`.

**How to start:** re-run the sweep before shipping — upstream theme files move, and `themes/CHECKSUMS`
pins only what we already vendored.

**Priority:** P3.

## P3 — Pull requests and GitHub

### At-a-glance review status in the sidebar / collapsed PR header (macapp) — #52 follow-up

**What:** Surface a compact review-status glyph (the aggregate `reviewDecision` — approved /
changes-requested / review-required) on the sidebar workroom row or the collapsed "Pull Request"
section header, next to the existing CI glyph — so review state is visible without expanding the
panel. Directly serves issue #52's framing ("so we can go visit the PR when needed").

**Current state (re-verified 2026-07-25):** still expanded-panel only. `#77` added a PR-state badge to
the PR header (`ChangesPanel.swift` `prNumberLink`) and the `reviewDecision` aggregate label sits above
the reviewer rows in the inspector (`PullRequestPanel.swift` `PRPresentation.reviewLabel`) — but the
sidebar workroom row still shows dirty/CI only (`ProjectSidebar.swift`, via `VCSStatusPresentation`),
and the background sweep still skips PR resolution (`resolvePRRaw` is called only from
`scheduleSelectedStatusRefresh`; `refreshWorkroomStatuses` runs local + CI). The aggregate is the
natural feed for a glyph.

**Why:** a glance from the sidebar beats expanding the panel per workroom; matches how CI status
already reads at a glance.

**How to start:** the blocker is data freshness — the PR (and thus `reviewDecision`) is resolved
**only on selection** (`scheduleSelectedStatusRefresh`), not in the bounded background sweep
(`refreshWorkroomStatuses` / `runCISweep` in `Core/AppStore+WorkroomStatus.swift`). A sidebar glyph
needs PR resolution added to the sweep (a third probe stage, bounded like CI, with its own TTL), then
a `VCSStatusPresentation`-style mapper for the review glyph reused by the sidebar row + collapsed
header (`ChangesPanel.prIndicator`).

**Depends on:** the #52 `reviewDecision` aggregate (shipped). Bigger than a UI tweak — it adds a PR
sweep stage.

**Priority:** P3 (strong UX win, but the background-sweep work makes it its own chunk, not part of #52).

### Per-reviewer comment counts in the PR panel (macapp) — #52 follow-up

**What:** Show a per-reviewer comment count next to each reviewer row in the Pull Request panel,
e.g. `iainad approved · 3 comments` — the `[N comments]` part of the issue #52 mockup.

**Current state:** #52 shipped the per-reviewer rows (state + bot-aware "in progress" label) by
riding the existing `gh pr list --head … --json …` probe, which carries `latestReviews` /
`reviewRequests` but **no review-comment counts**. The rows show state only.

**Why:** richer signal at a glance — how much feedback a reviewer left, not just their verdict.

**How to start:** counts aren't in `latestReviews`, so this needs a second call —
`gh api repos/{owner}/{repo}/pulls/{number}/comments` (review/diff comments) grouped by
`user.login` — added to `resolvePR` (`Core/WorkroomStatusResolver.swift`) and surfaced on
`Reviewer` (e.g. an optional `commentCount`). Weigh the extra network round-trip on the already-slow,
TTL-throttled PR probe; consider fetching counts lazily/only for the selected PR. Map counts onto
the existing identity-keyed fold; teams won't have counts.

**Depends on:** the #52 reviewer rows (shipped).

**Priority:** P3 (nice-to-have; deliberately deferred from #52 to keep that change to free data).

## P3 — Notifications and run commands

### OSC 99 desktop notifications (macapp) — blocked upstream, watch ghostty 1.4.0

**What:** support Kitty-style OSC 99 notifications (`printf '\e]99;;done\a'`). Nothing to build here
yet — this entry exists so the gap stays tracked and nobody re-derives the upstream state.

**Why it's a gap:** SwiftTerm parsed OSC 99; libghostty does not, so this is a regression against the
app's own prior behaviour. OSC 9 and OSC 777 work today
(`GhosttyRuntimeAdapter` `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`), which covers the common cases.

**Upstream state (checked 2026-08-05) — the important part:**
- Issue **ghostty-org/ghostty#5634** is open, assigned, milestone **1.4.0**.
- PR **#10467** ("parse the Kitty desktop notification protocol (OSC 99)") is open, rebased and
  described by its author as ready — but it adds **only a parser**. Its one-line `stream.zig` change
  files `.kitty_desktop_notification` in the branch that logs `"unimplemented OSC callback"` and
  discards it. Its own description says: *"This includes only parsing of the OSC. You cannot (yet)
  use OSC 99 to send notifications."*
- Three further pieces are needed before an **embedder** sees anything: stream dispatch, a
  Surface/apprt action (OSC 99's richer model — id, urgency, icon, chunked payloads — does not fit
  the existing 2-field `DesktopNotification`), and a `ghostty_action_*` tag in `include/ghostty.h`.
  **None exists as an open or merged PR.**

**So: the re-check trigger is "ghostty 1.4.0 ships", NOT "#10467 merges".** Merging #10467 alone
changes nothing observable, and cherry-picking it into a fork of our own would not either — this is
why the OSC 99 rationale was struck from CMT-2.

**Depends on:** upstream only. Then the pin bump (or whatever engine source we're on) to pick it up.

**Priority:** P3 — one escape sequence, with two working alternatives already wired.

### Auto-emit OSC notifications on command completion (macapp)

**What:** An opt-in shell hook (zsh `precmd`/`preexec`, or OSC 133 prompt markers) that emits
`printf '\e]9;<cmd> finished\a'` after a command that ran longer than N seconds, so notifications
fire automatically without the user wrapping commands.

**Why:** Notification detection is explicit-only (issue #10 review, decision 1.1b): we notify on
OSC 9/99/777 + bell, not raw output. That's precise but silent for a bare `make test` that emits
nothing. A shell hook closes that gap so the common "my build finished" case just works.

**How to start:** Source a hook into the login shell launched by
`TerminalSessions.makeTerminal` (`-l`), or document it for the user to add. Decide OSC 133 vs a
`precmd` that emits OSC 9. Keep it opt-in (injecting into the user's shell is invasive). Note the
OSC 133 *command-finished* marker is already parsed app-side
(`GhosttyRuntimeAdapter` handles `GHOSTTY_ACTION_COMMAND_FINISHED`, used today to clear the
running-command title) — so this task is about *emitting* OSC 9 on completion, not parsing it.

**Depends on:** the notifications feature (#10) — **now landed**; the OSC 9 desktop-notification
handler exists to receive it (`GhosttyRuntimeAdapter` `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` →
`AppStore.handleActivity`).

**Priority:** P3 (amplifies the shipped feature; the feature is useful without it for tools that
already emit OSC/bell).

### Notification preferences (macapp)

**What:** Per-workroom (or per-terminal) mute, a notification-sound toggle, and respecting macOS
Focus / Do-Not-Disturb.

**Why:** Now that notifications exist, a noisy cooperating tool (a watcher firing OSC on every
rebuild) will need silencing without losing notifications from other terminals. Focus/DND respect is
largely automatic via `UNUserNotificationCenter` (the system honors Focus at delivery time);
per-workroom mute is app logic.

**How to start:** A mute set keyed on `TerminalTarget.ID`, checked in
`NotificationCenterStore.record(...)` before creating an item / posting. Persist with a
`Defaults.Keys` entry in `Core/DefaultsKeys.swift` (the app uses `sindresorhus/Defaults` now —
consistent with `theme` / `copyOnSelect`, not `@AppStorage`). A sound toggle gates `content.sound`
in `SystemNotifier.post()` (today hardcoded to `.default`).

**Depends on:** the notifications feature (#10) — **now landed**
(`macapp/WorkroomApp/Core/NotificationCenterStore.swift`, `Core/SystemNotifier.swift`).

**Priority:** P3 (the feature is usable without it; add when a real terminal proves too chatty).

### Run-terminal persistence / auto-restart across relaunch (macapp) — #7 follow-up

**What:** Restore (or auto-restart) a workroom's run command when the app relaunches, rather than
losing it. Optionally remember which workroom had a running run command and offer/auto-run it on next
launch.

**Why:** The run-command feature (#7) keeps run terminals in-memory (consistent with all terminals —
`TerminalSessions` is session-only), and auto-run fires only at workroom *creation*. So quitting the
app with a dev server running loses it, and there's no auto-restart on launch. For a long-lived
"always have my dev server up" workflow that's a gap.

**How to start:** Persist a small per-target marker (e.g. `Defaults` set of target ids that had a
running run command), and on launch — after the project list loads and a workroom is selected — offer
or auto-start its run command. Decide the policy (auto vs prompt) and how it interacts with the
existing creation-time auto-run. Reuse `AppStore.startRunCommand(for:)` and the run-state model
(`runTabIDByTarget` / `runningTargets`).

**Depends on:** the #7 run-command feature shipping first (`macapp/WorkroomApp/Core/AppStore.swift`
run-command actions, `Core/TerminalSessions.swift` `addRunTab`).

**Priority:** P3 (deferred from #7 — the feature is useful without it; surfaced by the eng-review).

### Stopped run-tab silently closes instead of warning when its command is cleared (macapp) — #127 follow-up — FIXED

**Fixed:** `respawnRunCommand`'s `hasRunCommand` guard now mirrors the `.armed`/`.none` branch —
same non-clobber `pendingProjectSettings == nil` check, same warning sheet — and returns without
touching `oldTab` at all, so the stopped pane stays open instead of being closed. Covered by
`RunCommandTests.testRestartWithClearedCommandWarnsInsteadOfClosing` (confirmed it fails against
the prior behaviour via a temporary revert, passes with the fix).

**What:** `runOrFocusRunCommand()`'s `.stopped` case routes through `restartRunCommand` →
`respawnRunCommand`, which checks `hasRunCommand` and — if false — just closes the stopped-but-open
run tab and returns. No settings sheet, no warning, nothing.

**Why:** #127 gave the `.armed/.none` case (nothing has ever run) a "no command configured" warning
sheet instead of a silent no-op. `.stopped` never got the same treatment, so the gap is now
inconsistent: repro is run command configured → it stops (pane stays open) → user clears the command
via Project Settings → next ⌘R on that target silently destroys the stopped pane instead of
explaining why nothing (re)started. Found by the outside-voice adversarial review during #127 (Codex);
this branch predates #127 and wasn't touched by it, so it's a pre-existing gap in the original #7
feature, not a regression — but #127 makes the inconsistency more visible.

**How to start:** Mirror the `.armed/.none` branch's `hasRunCommand` check + `pendingProjectSettings`
routing inside `respawnRunCommand` (`AppStore.swift`, guard at line ~1465) before it unconditionally
closes the tab. Needs care around issue #67's focus-preservation semantics (`wasFocused`) — that
logic wasn't reviewed against this change.

**Depends on:** #127 shipping first (`AppStore.swift`'s `PendingProjectSettings` +
`pendingProjectSettings`).

**Priority:** done.

## P3 — Tests and tooling

### `AppStore`'s default `cli` isn't hardened against a forgotten test double (macapp) — filed 2026-08-16

**What:** `AppStore.init(cli: WorkroomCLIProtocol? = nil, ...)` defaults an un-injected `cli` to the
real `WorkroomCLI.shared` — including under XCTest. A test that constructs a bare `AppStore()`,
leaves `projectStore.projects` empty, and calls `bootstrap()`/`reload()` would silently shell out to
the real bundled `workroom` binary and read the developer's actual `~/.config/workroom/config.json`.

**Why not fixed now:** traced every current call site (`AppStoreSessionRestoreTests`'s two
`bootstrap()` calls) — both pre-seed `projectStore.projects`, so `bootstrap` takes the
`apply(projectStore.projects)` branch and never reaches `cli.list`. Nothing is broken today; this is
defense against a future test, not a current bug. See the 2026-08-16 "Recently done" entry above for
the actual bug this session found and fixed (the shared window's own bootstrap, not this).

**How to start:** default the un-injected `cli` to a `WorkroomCLIProtocol` conformer, active only
under `XCTestConfigurationFilePath != nil`, whose every method throws immediately — a test that
forgot to inject a fake gets a loud, specific failure instead of a silent real-data read.

**Depends on:** nothing blocking.

**Priority:** P3 — hardening, not a known bug.

### Deferred UI workflow tests (macapp) — FIXED

**What:** The two workflow UI tests left to write on top of the now-landed fixture seam:
1. **Notification badge + click-to-navigate** — drive a terminal to `printf '\e]9;…\a'`, assert the
   sidebar/tab badge appears, click it, assert it navigates to (and clears on) the right terminal.
2. **Delete-workroom-clears-badges** — assert deleting a workroom withdraws its notifications/badges.

**Fixed, #1 — `WorkroomWorkflowUITests.testLiveNotificationBadgeAppearsAndClickNavigatesToTheRightTerminal`:**
uses `-WorkroomUITestTwoTabs` for a second, off-screen workroom to raise the OSC from (firing it while
selected would hit `handleActivity`'s `selected + cursor → SEEN: suppress` rule, so the command sleeps
1s and the test switches away before it lands). Verified 3× clean.

**Found and fixed along the way — a real bug in `AppStore.loadFixture()`:** it unconditionally set
`projects = UITestFixture.projects()` on every reload, with none of `apply`'s tombstone filtering
(`applyingDeletionTombstones`) — a file-watcher-triggered reload mid-delete-teardown could resurrect a
just-tombstoned fixture workroom (and its notifications) straight back. Now filtered the same way.

**#2 — NOT done as a `WorkroomWorkflowUITests` XCUITest; done as `AppStoreDeleteRaceTests.testDeletingAWorkroomWithdrawsItsNotifications` instead:**
investigated first as a UI test and hit a real architectural wall, not a flake: fixture-mode
workrooms are never registered with the real CLI, so `deleteWorkroom`'s teardown call
deterministically FAILS in this harness (confirmed live — a real `presentTeardownFailure` alert
appears) — and a failed teardown is *supposed* to restore the workroom and its notifications
(`testFailedTeardownRestoresWorkroom` already covers exactly this). There is no stable "withdrawn"
state to assert via XCUITest here, only a transient one racing a real CLI subprocess round-trip.
`AppStoreDeleteRaceTests` already has `DeleteRaceFakeCLI`, a fake CLI whose `delete` can be made to
succeed — the right, fast, deterministic venue for this specific invariant.

**Priority:** done.

### `ChangedFileRowInvalidationTests` flaked only inside the full serial `app-test` run — FIXED (beta.24 gate)

**Fixed:** `ChangedFileOpenTests.swift`'s two `.filePathEditor` tests restored the key in `defer` but
never drained the run loop, so the restore's `@Default` change notification (delivered async — see
`ChangesPanel.swift`'s `filePathEditorID` comment: `@EnvironmentObject`/`@State`/`@Default` invalidate
PAST the row's Equatable gate by design) could land inside the very next test class's window. In the
2258-test full serial suite that landed inside `ChangedFileRowInvalidationTests`'s tight 0.6s `settle()`
and ticked `ChangedFileRow.bodyPasses` — reproduced twice in a row during the beta.24 release gate,
clean every time in isolation. Both restores now drain the run loop first
(`restoreFilePathEditor(_:)`), closing the leak at its source rather than papering over the symptom.

### `WindowDragUITests.testDraggingWorkroomTabReordersTwoChips` is a known gesture-timing flake — IMPROVED, still flaky, still skipped

**What:** Reproduced a pass then a fail on two consecutive back-to-back reruns of the identical test
against the identical binary during the beta.24 release gate — nothing else running, same machine,
same window geometry. Not caused by the beta.24 geometry fixes (fixture window 1200→1450pt): the
test computes its drag distance from the chips' own on-screen positions, so it's width-independent.

**Real bug found and fixed along the way:** `WorkroomTabBar.commitDrag`/`TerminalTabStrip.commitDrag`
computed the reorder's drop index from the `dragTranslation` **state**, which is only ever written
inside `onChanged` — so a drag whose LAST `onChanged` sample landed short of the true release point
(any coarse/fast delivery, synthetic or real) commits off a stale, under-shot translation instead of
the gesture's own accurate final `value.translation` at `onEnded`. Fixed in both strips (they
deliberately mirror each other's reorder math) to read `value.translation` directly at commit time.
Correct regardless of whether it's THE cause of this flake — verified via the full `WindowDragUITests`
+ `WorkroomStatus*`/`VCSProviderConformanceTests` suites, no regressions.

**Measured, three iterations, ~30 back-to-back reruns total:**
1. The `commitDrag` fix alone: 1/5 passed. Ruled out as a full fix on its own.
2. + polling `chipsByX` until two reads agree (ruling out a race against the strip's own 0.2s
   reorder-settle `withAnimation`): 3/5.
3. + switching the gesture from the touch-oriented `press(forDuration:thenDragTo:…)` to the
   macOS-native mouse `click(forDuration:thenDragTo:…)` (same API family, `XCUICoordinateMouseEvents`,
   available on macOS): **9/10 in clean, uncontaminated batches** (one batch's first two runs were
   invalidated by an unrelated concurrent edit to `WorkroomStatusResolver.swift` mid-build — excluded).

**Still flaky — deliberately left skipped.** ~90% is a real improvement over the original coin-flip,
but not deterministic, and a ~1-in-10 spurious red X right before a release is its own cost. The
`APP_UITEST_FLAGS` skip entry (`Makefile:67`) stays as-is.

**How to fix further (not attempted):** the TODO's original two ideas — a manual multi-step drag
giving the reorder logic more interpolated samples, or loosening the swap threshold's dependency on
event count — remain open, on top of whatever residual gap the native-mouse switch didn't close.
Low priority: single test, single known flake mode, not client-facing.

**Still open regardless of state-machine cleanup elsewhere:** the bug class this entry is about (an
under-shot final sample) is real-mouse-only — no synthetic test can prove a fast real flick commits
the true endpoint. Run a manual fast-flick drag test in both `TerminalTabStrip` and `WorkroomTabBar`
before trusting this beyond the automated numbers above.

### `SessionByteQueue`'s `wouldBlock` path has no dedicated test (macapp) — FIXED, 2026-08-16

Moved `SessionByteQueue` + `SessionIO` + the two outcome enums from `WorkroomSession/SessionSupport.swift`
into `WorkroomSessionProtocol/SessionIO.swift` (marked `public`) — the module already shared by
`WorkroomApp`, `WorkroomAppTests`, and `workroom-session`, per the second option this entry named.
`WorkroomAppTests/Session/SessionByteQueueTests.swift` now drives `drain`'s `wouldBlock` path against
a real, unread, non-blocking pipe (not a mock): a short write that would block, the queue left
correctly positioned, then a full flush once the reader catches up.

**Trap while writing the test:** the first version set only the pipe's WRITE end non-blocking. The
read-back loop's `SessionIO.read(readFD)` then blocked for real once the currently-buffered bytes
were drained — hanging the test host (`Workroom Dev.app`, beach-balling) rather than failing, since
the block happens deep inside a real `read()` syscall on the main test thread. Both ends of a pipe
used for this kind of poll-until-`wouldBlock` loop need `SessionIO.setNonBlocking`.

**Priority:** done.

## P3 — Performance and diagnostics (WORKROOM-2B follow-ups)

### Status-aware avatar image loader (macapp) — FIXED

**What:** Replace `AsyncImage` in `AvatarView` (`Views/Avatar.swift`) with a small loader that reads the
HTTP status, caches decoded images in memory, caches genuine 404s, and retries transient failures.

**Fixed:** `AvatarImageLoader` — an actor-free `@MainActor` class with an injectable `URLSession`, a
bounded (default 256) LRU cache of decoded `NSImage`s / confirmed-404 `URL`s, in-flight de-duplication
per URL, and `nil` (never cached) for anything transient: a network error, a non-200/404 status, or an
undecodable 200 body. `AvatarView` drives it via `.task(id:)` keyed on the URL + the
`.loadRemoteAvatars` privacy gate (unchanged: no request issued while it's off). `AvatarImageFailures`
(the old error-blind, app-activation-cleared mitigation) is deleted — nothing else referenced it.
`AvatarImageLoaderTests.swift` covers it behind a `URLProtocol` stub: success/cache, genuine-404/cache,
transient-network-error/no-cache/retries, non-200/404 status, undecodable body, concurrent-request
de-dup, and LRU eviction — 7 tests, all green, no real network in any of them.

**Priority:** done.

### `FilesPanel` renders up to 4000 rows eagerly (macapp) — FIXED

**What:** `Views/FilesPanel.swift:58-60` builds every visible tree row in an eager `VStack`, capped at
`FileTreeModel.renderCap = 4000`, and each row holds `@EnvironmentObject store` + `@ObservedObject
model`.

**Measured (per this entry's own instruction), then fixed:** `FilesPanelInvalidationTests` added the
same `#if DEBUG bodyPasses` counter `HistoryRow`/`ChangedFileRow` use. Confirmed BOTH suspected
mechanisms on the pre-fix code: an `AppStore` publish saying nothing about the file tree rebuilt all
200 visible rows (`store` was read only inside tap/menu closures, never the rendered body — so this
was the WORKROOM-2B mechanism, not a hypothetical); a 1000-file tree built all 1000 rows on first
layout (the eager `VStack`).

Fixed the same way History/Changes were: `FileTreeRowView` now takes plain values + closures and
observes NOTHING (`FilesPanel` hoists `isExpanded` out of `FileTreeModel` per-row and passes
`onToggle`/`onOpenPreview`/`onOpenPersistent`/`onOpenInEditor`), gets an `Equatable` gate, and the
list is a `LazyVStack` — safe here (unlike `DiffViewer`'s soft-wrapping lines) since rows are
fixed-height and this already lives inside the inspector's own `ScrollView`. Re-measured: the
unrelated-publish case is now 0 rebuilds (was 200); the 1000-file tree now builds ~20-odd rows, not
1000; a 4000-file tree (the render cap) first-layouts in under the same 0.25s ceiling
`HistoryRowInvalidationTests` uses.

**Priority:** done.

### Main-thread timing from a real hang (macapp) — WORKROOM-2B follow-up

**What:** a bounded way to learn *how long* the main thread was held, and by what, from a hang report on
a user's machine. Three candidates: Sentry profiling started and stopped around suspect windows,
`os_signpost` intervals around panel body passes, or a watchdog breadcrumb capturing what the app was
doing when the stall began.

**Why:** WORKROOM-2B cost a full session of inference because the report was a single unsymbolicated
main-thread sample. The dSYM upload fix (`.github/workflows/nightly.yml` + `Scripts/release.sh`) closes
the *naming* half — frames will have function names now. Nothing tells us the duration or the shape of
the stall.

**Verify FIRST, before implementing anything:** whether Sentry's continuous profile chunks actually
attach to macOS **app-hang** events. If they don't, profiling buys nothing for this use case and the
signpost/breadcrumb options win. `Core/SentryConfig.swift` already configures profiling with
`.trace` lifecycle and `sessionSampleRate = 1.0`, but the app opens no transactions, so it never runs —
that is why the option looked free and isn't.

**Known caveat (from the eng review):** sentry-cocoa 9.19's manual lifecycle requires an explicit
`SentrySDK.stopProfiler()`. A launch-start-never-stop profiler is outside documented usage, costs CPU
and upload volume continuously, and could itself stall — which is why it was cut from the fix rather
than shipped on nightly.

**Depends on:** the dSYM upload landing (symbols are a prerequisite for any of this being readable).

**Priority:** P3 — until the next hang report, symbols alone may be enough.

### Focus-responder App Hang on a large diff (macapp) — WORKROOM-2T — CLOSED (2026-08-11)

**What:** Sentry WORKROOM-2T, nightly build 596 (macOS 26.5.2), 5 occurrences. **Pulling all events
showed Sentry grouped two different bugs into one issue** (fingerprinted on `culprit: main` + "App
Hanging", not on stack signature) — treat this as two separate findings:

- **4 of 5 events share an identical 93-96-frame stack**, entirely inside the SwiftUI/AppKit runtime:
  `NSAnimationContext.runAnimationGroup` → `NSHostingView.layout` → `ViewGraphRootValueUpdater.render` →
  `AccessibilityNode.updateFocusResponder` → `ViewRendererHost.focusResponder` →
  `ResponderNode.visitFocusResponders` → 10+ nested `MultiViewResponder.visit` →
  `swift_conformsToProtocol2` → `dyld4::APIs::_dyld_find_protocol_conformance` →
  `SwiftHashTable::getIndex` — the same slow-dyld-conformance-lookup family behind the toolbar App Hang
  this app already fixed once (empty AppKit `NSToolbar`, no SwiftUI `.toolbar*`), this time hit from
  SwiftUI's **accessibility focus-responder walk**, which runs on every `NSHostingView.layout` pass.
- **The first event (21:15:07) has a completely different 36-frame stack** — `GraphHost.runTransaction`
  → `AG::Subgraph::update` → `DynamicPreferenceCombiner.value.getter`, an AttributeGraph stall with no
  focus-responder frames at all. Belongs with the `DiffViewer`/`sbsRows` AttributeGraph App Hang family
  (commit `5194b614`), not this entry — split into its own tracked item if it recurs with more samples.

**Root cause, confirmed by a live user repro:** the 5th occurrence fired the moment Joel opened a large
Git diff of a CSS file — a direct, deterministic trigger, not archaeology off breadcrumbs. This lines up
exactly with `DiffViewer.unifiedBody`/`sideBySideBody` (`Views/DiffViewer.swift:381-436`): both
deliberately render **every line of every hunk in one eager `VStack`**, not a `LazyVStack` — the code
comment explains why (line 382-393): diff lines soft-wrap via `fixedSize(vertical:)`, so a lazy stack
would cache a wrong height estimate for a not-yet-materialized wrapping row and leave a visible blank
band mid-scroll. `UnifiedDiff.parse`'s 2000-line cap was believed to make eager layout "affordable" —
and it is, for layout and for AttributeGraph (after the `sbsRows` box fixed WORKROOM-2S, a near-cap diff
tripping an AG walk). It is **not** affordable for SwiftUI's accessibility focus-responder walk: each
`lineRow`/`sideBySideRow` is already its own `.accessibilityElement(children: .ignore)` (`DiffViewer.swift:496,542`)
— correct for VoiceOver (one element per line, not per glyph run) but it means a near-cap diff puts up to
~2000 individual accessibility nodes in the tree that `ResponderNode.visitFocusResponders` walks on every
layout pass, and that walk is what's hitting the cold conformance-lookup path repeatedly.

This also explains the earlier reactivation-triggered occurrences in this same issue (events 2/3, see
history in git blame if needed): `RootView.swift:405-416`'s `didBecomeActiveNotification` handler calls
`store.refreshHistoryIfActive()`, and a repopulated History `LazyVStack` is the same shape of problem —
many per-row accessibility elements materializing at once. Diff and History are two instances of one
mechanism: **a wide, eagerly-accessible content view appearing in one layout pass.**

**Why no fix yet — real tradeoff, not just unverified:** the obvious "make it lazy" fix is the one this
file's own comment already rejected, for a correctness reason (blank bands) that's independent of this
bug — reintroducing it to chase 2T would trade one visible bug for another. The other candidate —
collapsing multiple diff lines into fewer accessibility elements to shrink the responder tree — is a
real accessibility regression, not a free win: it would cost VoiceOver users per-line diff navigation,
and `diff.line`/`diff.side.left`/`diff.side.right` identifiers are likely load-bearing for existing UI
tests (grep before touching). Neither is a small, obviously-safe change; both are product tradeoffs, not
mechanical fixes. Flag to Joel before implementing either.

**How to confirm/measure:** reproduce locally — open a large CSS (or any near-2000-line) diff, and
profile with Instruments' Hangs + Time Profiler template watching `ResponderNode.visitFocusResponders`.
Worth measuring how the hang duration scales with line count (200 lines vs 2000) — if it's linear, the
2000-line cap itself is also a lever (lowering it trades diff completeness for hang avoidance, its own
tradeoff, but a cheap one to quantify).

**Depends on:** "Main-thread timing from a real hang" above — the same profiling/signpost infrastructure
would turn the next occurrence into a real trace, and would let Sentry fingerprint the AttributeGraph and
focus-responder hangs as separate issues instead of one.

**Priority:** P2 — confirmed deterministic repro (open a large diff), recurring (5 occurrences), one
real user hit it live. No longer "one hang report, unconfirmed mechanism."

**Update (live diagnostic, 2026-08-11):** ran a throwaway experiment (collapsed each hunk's per-line
accessibility elements into one via `.accessibilityElement(children: .combine)`, no other change) against
the real codaset `workroom.css` diff that originally reproduced the hang. Result: **partial** improvement,
not a full fix — the hang is "a bit better," but unified⇄side-by-side mode switching is still noticeably
delayed and scrolling the large diff still isn't smooth. Reverted the throwaway edit (needs its own
VoiceOver-granularity tradeoff sign-off if ever pursued for real, not something to smuggle in as a
diagnostic).

**Conclusion:** accessibility-node count is A real contributing factor (grouping measurably helped) but
NOT the only one — the eager `VStack` also pays a separate, real cost from sheer materialized-view count
(no virtualization), which grouping AX elements alone doesn't touch and which fully explains the
still-slow mode-switch and scroll. Confirms neither the `List` spike (Phase -1) nor the pre-measured
`LazyVStack` fallback (Phase 0) can be skipped — actual laziness/virtualization is necessary, not just an
accessibility-tree optimization. Proceeding to Phase -1.

**RESOLVED (2026-08-11) — Phase -1 `List` spike: GO, adopted.** Spiked `List` directly inside
`DiffViewer.unifiedBody`/`sideBySideBody` (`.listStyle(.plain)` + `.listRowInsets(EdgeInsets())` +
`.listRowSeparator(.hidden)` + `.environment(\.defaultMinListRowHeight, 0)` to suppress macOS List
chrome — the `.listRowSpacing(0)` modifier is unavailable on macOS at this deployment target, the
`defaultMinListRowHeight` environment override closed the same inter-row gap instead). All 4 spike
questions confirmed against the real codaset repro: hang gone, scrolling smooth, mode-switch instant,
`.listStyle(.plain)` chrome matches the prior look once the row-gap was closed, text selection/copy and
keyboard nav unaffected, and `DiffViewerUITests`/`DiffHighlightUITests` (10 tests) pass unmodified —
the `diff.line`/`diff.side.left`/`diff.side.right` accessibility identifier/label/value contract
survived the rewrite intact. Full `make app-test` unit suite also green. This **replaces** the
pre-measured `LazyVStack` engineering entirely (`DiffLineMetrics`, the boxed height cache, the debounce/
generation-check machinery) — none of it shipped or is needed; `List`'s `NSTableView` backing
virtualizes both rendering and accessibility natively. Doc comments in `DiffViewer.swift` updated to
describe `List` as the permanent fix, not a spike.

**CLOSED (2026-08-11) — hang-regression test written and passing.** Added
`macapp/WorkroomAppTests/DiffViewerLazyRenderingTests.swift`, mirroring
`HistoryRowInvalidationTests`'s host()/settle()/body-pass-count/wall-clock-ceiling shape:
`DiffViewer.lineRowBodyPasses`/`sideBySideRowBodyPasses` `#if DEBUG` counters added (same convention as
`HistoryRow.bodyPasses`/`ChangedFileRow.bodyPasses`); `UITestFixture.hugeDiff()` synthesizes a
2000-line, 20-hunk, minified-CSS-shaped diff behind a `huge.css` magic path (forced active in the test
via `UserDefaults.standard.set(true, forKey: UITestFixture.defaultsKey)`, reset in `tearDown`). Three
tests, all passing: `testHugeDiffDoesNotBuildEveryLine` (laziness bound), `testHugeDiffRendersUnderTimeCeiling`
(< 1s, well under the 2s watchdog), `testHugeDiffKeepsMultipleHunks` (pins the multi-hunk shape so the
`ForEach`-in-`ForEach`-in-`List` nesting is exercised, not assumed to virtualize). Full `make app-test`
green. WORKROOM-2T is fully closed.

### Diff line-height cache doesn't invalidate on Dynamic Type change (macapp) — WORKROOM-2T follow-up — MOOT

**Superseded 2026-08-11:** the `List` spike (Phase -1) was adopted instead of the pre-measured
`LazyVStack` fallback this TODO depended on — there is no hand-rolled font-tracking height cache to
invalidate. `List`/`NSTableView` handles Dynamic Type changes as part of its own native row-sizing, not
a bespoke mechanism this codebase would need to maintain. No action needed; keeping this entry (rather
than deleting it) as a record of why it was proposed and why it no longer applies.

**What:** If the WORKROOM-2T fix ships via the pre-measured `LazyVStack` fallback path (not the `List`
spike), `DiffLineMetrics.measurementFont()` resolves Dynamic Type once per recompute, but nothing
observes a live system text-size change and re-triggers a recompute while a diff is already open — the
cached heights go stale until some unrelated trigger (a resize, a mode toggle, reloading the diff)
happens to fire a fresh one.

**Why:** a user who changes their system text size (System Settings ▸ Accessibility, or a hardware
shortcut) with a large diff open would see rows sized for the OLD font until something else nudges a
recompute — a silent, accessibility-adjacent correctness gap, and currently nothing (test or otherwise)
would catch a regression here.

**Pros:** small, well-understood fix once the underlying recompute machinery exists — observe
`NSApplication`-side Dynamic-Type/content-size-category change (or the SwiftUI environment
`\.dynamicTypeSize`, if adopted) and fold it into the existing `heightCacheKey` the same way `loadToken`/
`mode`/`widthBucket` already are.

**Cons:** genuinely rare interaction (change text size AND have a large diff open AND no other recompute
trigger fires in between); another small addition to an already-multi-part cache-invalidation surface.

**Context:** surfaced during `/plan-eng-review` of the WORKROOM-2T fix plan, in the "NOT in scope"
section — not solved there to keep that plan's scope to the hang fix itself. Only applies if that plan's
fallback (pre-measured `LazyVStack`) path ships; moot if Phase -1's `List` spike succeeds instead, since
`List`/`NSTableView` row-sizing wouldn't depend on a hand-rolled font-tracking cache the same way.

**Depends on:** the WORKROOM-2T fix landing via the fallback path (the cache this would extend doesn't
exist otherwise).

**Priority:** P3 — rare edge case, no user report of it yet.

## P3 — CLI

### Harden `vcs.Detect` to validate a real repo (CLI) — #103 follow-up — RE-PRICED, not a fit for this batch

**What:** `vcs.Detect` (`internal/vcs/vcs.go`) currently treats a directory as a repo if `.jj` is a
dir OR `.git` merely *exists* (file or dir). A bogus/empty `.git` therefore registers as a project
via `add-project` and only fails later, at workroom creation.

**Why we thought this:** Surfaced by the Codex outside-voice pass during `/plan-eng-review` of issue
#103 (the create-project work). It's a pre-existing robustness gap — the existing-path `add-project`
already has it; #103's create flow inits a real repo so its happy path is unaffected — but a
stricter check would fail fast with a clear error instead of a confusing late failure. Re-confirmed
by the Codex pass during the jj→git stale-vcs fix: the new reconcile-on-list (`Service.effectiveVCS`)
also uses marker-file truth, so a *present-but-broken* `.jj` dir would still reconcile as jj —
hardening `Detect` fixes both the late-failure gap and the reconcile accuracy in one place.

**What checking the actual call sites found:** `vcs.Detect` has exactly two callers
(`internal/workroom/workroom.go`) — `detectVCS` (line ~103, registration-time: `add-project`/create)
and `effectiveVCS` (line ~160, `Service.effectiveVCS`, which runs on **every `list`**, not just
registration). The dual-purpose framing above is real, but it cuts the other way from how it reads:
hardening `Detect` doesn't just gate new registrations, it changes what a healthy, already-registered
repo reconciles to on every list. `effectiveVCS` fails soft today (`err != nil` → falls back to the
stored type), so a hardened check wouldn't hard-fail `list` — but it would introduce a new case where
a real repo whose `.git/HEAD` is momentarily unreadable (mid-`git gc`, a permissions blip, an
NFS/sync stall) silently reconciles away from "git" for that one list, a failure mode that doesn't
exist against today's bare `os.Stat(.git)` check.

Separately, ~58 existing test-fixture sites across `vcs_test.go`, `reconcile_test.go`,
`workroom_test.go`, `list_data_test.go` fake a repo with `os.Mkdir(dir/.git, 0o755)` / `.jj` and
nothing inside — exactly the bare-marker shape a hardened check would reject. There's no way to catch
the bug without invalidating all of them; that's the change's actual semantics reaching every test
that ever faked a repo, not incidental churn. And `.git`-as-file (git worktrees) needs its own
validated pointer-file path — worth flagging because a *workroom* is itself a git worktree, so
getting that one subtly wrong would hit the product's core object, not an edge case.

**Verdict:** not a fit for a pre-release stability batch. "Keep it cheap" in the original framing was
about CPU cost (stat-level over forking git) and didn't anticipate this blast radius. A correct
version of this needs: confirming both call sites' fail-soft behavior stays correct under the new
check, updating the fixture set deliberately (not as a mechanical find-replace), and a validated
`.git`-as-file path — real work, not a drive-by.

**How to start (unchanged from the original framing, for whenever this is picked up):** In `Detect`,
validate beyond existence — e.g. `git rev-parse --git-dir` (or read `.git`/`HEAD`) for git, and
confirm `.jj/repo` for jj.

**Depends on:** nothing; touches all VCS consumers (`create`, `list`, `delete`, `add-project`).

**Priority:** P3 → hold. Re-open as its own deliberate pass (fixtures + both call sites + the
worktree-pointer path), not folded into an unrelated batch.

### The config lock can be stolen from a live holder (CLI) — `withLock` audit — SHIPPED (2026-08-10)

**Shipped, via a different mechanism than the one this entry proposed.** Rather than adding a nonce +
heartbeat to the hand-rolled `O_CREATE|O_EXCL` + mtime scheme, `withLock` now takes a real cross-process
OS advisory lock via `github.com/gofrs/flock` (`flock(2)` on Unix, `LockFileEx` on Windows). This
structurally eliminates every failure mode this entry describes — there is no elapsed-time staleness
window to reason about or steal from a still-live holder at all, because the kernel releases the lock
the instant the holding process dies or crashes, not after some elapsed-time guess. Every scenario in
this entry's own diagram (a slow-but-live holder mistaken for stale; the two mismatched constants;
the unlocked-for-10s-after-a-crash window) is a consequence of measuring staleness by CLOCK TIME, which
an OS advisory lock simply doesn't do. Verified with new concurrency tests: a live holder that runs
past the OLD 10s "stale" threshold is never stolen from (`TestWithLockSerializesAgainstALiveSlowHolder`),
20 concurrent writers never lose an update (`TestWithLockConcurrentWritersNeverCorruptTheFile`), and a
simulated crashed holder's lock releases immediately, not after any wait
(`TestWithLockReleasedImmediatelyWhenHolderDies`). **Rollout caveat, deliberately not addressed here**:
an old, un-upgraded standalone CLI binary still runs the previous scheme against the same `.lock` path,
and the two mechanisms don't recognise each other — no worse than the pre-fix status quo for that
pairing, but not fully closed either. Left as an explicit decision for whoever cuts the next release tag.

**What:** give the config's advisory lock (`Config.withLock`, `internal/config/config.go`) an
*ownership token* and a heartbeat, so a lock is only ever removed by the process that holds it, and
"stale" measures time since the holder last made progress rather than time since it started.

**Why:** the lock file carries no identity — it is created empty with `O_CREATE|O_EXCL` and released
by an unconditional `defer os.Remove(lockPath)` that deletes *whatever* file is at that path, not the
one this process created. So a steal silently unlocks a live holder:

```
  A: creates lock ─────── fn (stalls > staleAfter) ────────► defer Remove  ← deletes B's lock
  B:                       stat says stale, Remove + create ──── fn ─────────────► (unprotected)
  C:                                                    creates lock ── fn ──► interleaves with B
```

Two read-modify-write cycles then interleave on `config.json`, and because each one `Read`s the whole
map and `Write`s its own snapshot back, the loser's edit vanishes — a workroom or project silently
disappearing from the sidebar, which is precisely what this lock exists to prevent. There is no error
on any path: both writes "succeed".

The staleness rule makes that reachable rather than theoretical. The lock file's mtime is stamped at
creation and never refreshed, so `time.Since(info.ModTime()) > staleAfter` is really "has been held
for 10s", not "has been abandoned" — any holder that genuinely takes longer (a home dir on a synced
or network volume, a machine under heavy load, a CLI paused under a debugger) is declared dead while
it is still working.

Two constants that don't agree, worth settling in the same pass: the wait loop gives up after
200 × 10ms ≈ **2s** while `staleAfter` is **10s**, so a waiter can never actually reclaim a lock
orphaned by a crash *during its own wait* — it spins for two seconds and then proceeds **unlocked**.
The unlocked fallback is deliberate (documented: never fail an operation over the lock), but it means
that after a crash every writer for the next 10s runs with no mutual exclusion at all, and that is
when the app and the CLI are most likely to be writing together.

**How to start:** write a nonce (pid + a random token) into the lock file; release with a
read-compare-then-remove, and steal only after re-reading the same nonce you judged stale. Refresh the
mtime periodically from the holder (or record a deadline in the file) so staleness tracks liveness.
Then make the wait cap and `staleAfter` consistent. Testable without concurrency by injecting the
clock and the nonce — today's only lock test (`TestWriteAtomicLeavesNoTempOrLockFiles`) asserts
cleanup, not exclusion.

**Depends on:** nothing. Pure `internal/config`; no caller signature changes.

**Priority:** P3 — every `withLock` body is a short read-modify-write today, so the >10s stall that
opens the window is rare. Cheap to close, and the failure it produces (a silently lost entry, no
error) is one of the hardest to diagnose from a bug report.

## Recently done

Condensed from the long status notes this file used to carry at the top; the full write-ups are in git
history. Kept here for the parts that stay useful: what changed, and the traps found doing it.

**2026-08-16 — `make app-test` was silently reading and acting on the developer's real config.**
`WorkroomApp`'s top-level `WindowGroup` scene has no test-mode branch of its own — `WorkroomAppTests`
hosts the real app to get `@testable import Workroom`, so this real window rendered and its
`.task { await store.bootstrap(...) }` ran on every `make app-test`, against the SHARED `AppStore`
(production default `cli: WorkroomCLI.shared`, never a fake). Confirmed via the test log: an
`io_exec: started subcommand path=/usr/bin/login` line — a real terminal opened in a real project
directory — appeared on every run. Fixed with the same `XCTestConfigurationFilePath == nil` guard
`WorkroomApp.init` already uses for `ShellEnvironment.refresh()`; verified the fix by rerunning the
suite and confirming zero `io_exec`/`login` spawns. No unit test reads `ProjectStore.shared`
directly (grepped first), so nothing depended on this window having bootstrapped. Manual
`make app-run`/⌘R are unaffected by construction — `XCTestConfigurationFilePath` is set only by
`xcodebuild test`, never a normal launch — so no new flag is needed to keep testing against real
config by hand.

**2026-08-10 — the last two `## P1` entries shipped, so that section is now empty.** Both were filed
before GA and are fully landed; retired out of the priority sections per this file's own rule (open
work only lives there) rather than left to read as still-outstanding.

- **Terminal *content* accessibility (CMT-3).** `isAccessibilityElement()`/`accessibilityValue()` are
  real now (no longer gated behind the UI-test fixture); a new `accessibilitySelectedText()` reads
  the existing `readSelectionText()`; a 400ms `Timer` poll posts coalesced
  `.valueChanged`/`.selectedTextChanged` only when the read content actually changed, checking
  `NSWorkspace.shared.isVoiceOverEnabled` FIRST on every tick so the real cost (materializing the
  viewport into a `String`) is paid only while VoiceOver is actually listening. The no-password-leak
  safety property was verified empirically, not by reasoning about terminal semantics:
  `TerminalAccessibilityUITests.testPasswordPromptWithEchoDisabledRendersNoTypedCharacters` drives a
  real `stty -echo` + `read` prompt in a real pane and asserts the typed secret never appears in the
  read viewport.
- **Every shipped beta had an arm64-only CLI inside a universal app.** `ARCHS` is a space-separated
  list (`"arm64 x86_64"`), and `build-helper.sh` matched it as a single token, falling through to a
  `warn:`-and-default-to-arm64 branch — buried in xcodebuild output, and codesign/notarization/
  Gatekeeper are all happy with a thin nested binary. Present since `8bae1b2a` (beta.1 through
  beta.23); the standalone CLI's own `darwin_amd64` tarball was always fine, only the embedded copy
  was thin. Fixed in `build-helper.sh` (per-arch build + `lipo`), asserted at release time by
  `release.sh check_universal()`, and regression-tested by `build-helper_test.sh` (proven to fail
  against the old logic). Confirmed released: `ff7bbb7f` is an ancestor of the `v2.0.0-beta.24` tag.

**2026-08-05 — four caches and surfaces that asserted stale or wrong things.** The three user-noticed
findings from the VCS-toolbar review ((5), (6), (7) — see that entry) plus `DiffDescriptor.change` going
stale on an open tab. What each turned on:

- **A "freshest first" cache needs a way to be retracted.** `resolvedBranchNames` led `branchName(for:)`
  because the toolbar read is normally freshest, but only the FOCUSED target is ever written and only
  while the inspector shows Changes — so nothing could ever say "not any more", and `git switch` in a
  terminal left every surface on the old name indefinitely. Fix is one line at the sweep
  (`pruneResolvedBranchNameIfDrifted`): a lower source that disagrees retracts the higher one. An
  empty/absent swept branch is NOT a disagreement — a detached HEAD and an unbookmarked jj `@` both
  legitimately report none.
- **An identity guard that's right for rendering is wrong for reporting.** `finish` guards its published
  state on target identity because the toolbar renders whatever is selected NOW — correct — but the
  failure DIALOG was behind the same guard, so a push that failed after a workroom switch was reported
  nowhere at all. Raised ahead of the guard now, with the workroom named
  (`VCSFailureReport.workroom`) when it isn't the current selection.
- **A failure described into a `String` is a dead end.** `state.failed(String)` carried the read's
  failure but nothing rendered `state` and nothing could classify a description, so a read blocked by
  `packed-refs.lock` reached the bar as a nil snapshot and rendered "No repository" — a wrong diagnosis
  of a healthy repo. Publishing it typed (`readFailure`) is what let the presenter add tier [13b].
- **Refreshing content must not look like navigating to it.** `TerminalSessions.setContent` fires
  `onTabContentChange`, which RECORDS a back/forward entry — so refreshing an open diff tab's change kind
  through it would have logged a history step every time a file changed under the user. The refresher
  mutates in place, fires nothing, and returns `false` for an unchanged kind so a 15s sweep publishes
  nothing (WORKROOM-2B). Also: `DiffDescriptor.change` was KEPT, not removed as filed — `.commit` diffs
  need a kind that live status can't supply.

**2026-08-05 — the ⌥Tab / ⌃Tab quick switcher (#132), and the contrast metric it exposed.** ⌥Tab steps
open workrooms across every window by most-recent use, ⌃Tab steps the current workroom's panes; a tap
flips, a 250ms hold reveals a screen-centred rail of cards, release commits. `Core/SwitcherRecency.swift`
(pure `RecencyList` + `WindowToken`), `QuickSwitcher{,Reducer,Controller}.swift`, `SwitcherPanel.swift`,
`SwitcherRailLayout.swift`, `SwitcherMark.swift`, `Views/SwitcherRailView.swift`, plus Go-menu items and
two Keyboard Shortcuts rows. Deferrals are filed above ("Quick-switcher deferrals"). The traps:

- **`ThemeTokens.luminance` was never WCAG.** It weighted *gamma-encoded* sRGB instead of linearizing,
  so `contrastRatio` under-reported every dark colour (`#2E3440` read 0.20 against a true 0.033). Across
  the 56 bundled themes the rail's name text scored under 4.5:1 for **43** of them by that formula and
  **4** by real WCAG, and the "this theme is unreadable, drop the material" fallback was firing for 38
  legible themes. Fixed app-wide: `luminance` linearizes, the old formula survives as
  `perceivedBrightness` for light/dark classification only (WCAG luminance is not perceptual), and
  `contrastingForeground` picks ink by **measuring both candidates** instead of a luminance-0.6 switch —
  that threshold is what left a monogram at 1.77:1 where black gave 11.8:1.
- **Contrast tests must pin their theme, and then sweep the real ones.** Three "failures on untouched
  code" were tests reading the ambient theme via `ThemeTokens(preview: nil)`, which follows the machine's
  appearance. Pinning them to fixtures exposed two real bugs; sweeping all 56 bundled themes
  (`SwitcherThemeSweepTests`) exposed the metric. Two hand-made fixtures prove nothing about the
  fiftieth theme.
- **A borderless non-opaque `NSPanel` casts no shadow at all** (measured: zero darkening at 6/14/26/44pt
  out with `hasShadow = true` + `invalidateShadow()`). The rail draws its own — which needs the window
  padded by a halo (a drawn shadow clips at the window edge), the shadow in a *second* `.background`
  after `.clipShape` (a clip applies to a view's background), and the caster's own footprint punched out
  with `destinationOut`, because an opaque layer anywhere beneath a glass view annihilates the material
  (interior variation and backdrop correlation both fall to exactly 0).
- **Compacting a live item list silently retargets the commit.** `filter`ing dead items shifted every
  later index down one while the reducer only *clamped* the cursor, so losing an item before the cursor
  committed the highlighted card's neighbour — and the rail was never re-pushed, so a click indexed a
  stale array. `.itemsChanged` now carries a cursor remapped by item **identity**.
- **A commit must re-check `hasModalPresentation`.** It was enforced at open and in the liveness check,
  which only runs on a window *close* — a sheet going up posts no notification the session watches, so
  releasing over a window that had since become modal performed exactly the write the gate exists to
  prevent.
- **Raising a window fires the recency hook for the selection it's leaving**, so MRU[1] became somewhere
  the user had never been and the ⌥Tab⌥Tab ping-pong broke. `SwitcherRecency.suppressingRecord` wraps the
  raise.
- **There is no VoiceOver-status notification in AppKit.** `isVoiceOverEnabled` is KVO-only
  (`NSAccessibility.h`), which is how a live session now ends when VoiceOver arrives mid-gesture.
- **`UserDefaults` is not isolated by a throwaway `$HOME`** — cfprefsd resolves the login session's home,
  so QA can isolate `~/.config/workroom` but never `Defaults`-backed state (theme, inspector, channel).
  Use a `UITestFixture` flag instead.
- **Window captures were built (T12) and removed.** At card size an aspect-fit terminal thumbnail is a
  grey smudge that changes every time and looks like every other terminal — it carried the least
  information while being the loudest element. Replaced by a learnable per-workroom mark (hue + monogram,
  hues rotated so no two visible cards collide) and a per-pane type miniature. `Core/Snapshots/` is gone;
  own-process ScreenCaptureKit needing no TCC was proven on the way and is in git history if it's ever
  wanted again.

**2026-07-26 — the shared inspector prefs are out of the test suite, and the fix went one class further
than filed.** The entry this retires was about three classes writing `Defaults[.showInspector]` /
`inspector.activeSection` into a domain all the parallel workers share.

- **The two History classes now pin both halves of the gate per store** —
  `AppStore.inspectorVisibleOverrideForTesting` (routing the two `Defaults[.showInspector]` reads in
  `handleRootBranchChange` / `refreshHistoryIfActive` through `inspectorIsVisible`) and
  `isolatesInspectorSectionForTesting` (which suppresses the `activeInspectorSection` didSet's persist).
  `EmptiedWorkroomSelectionTests` was a fourth writer the entry hadn't spotted, and takes the same flag.
  Both hidden `Defaults` sides keep a test, for the reason `resolveConfirmOnClose` has one.
- **`HistoryLiveRefreshTests`' save/restore couldn't have worked anyway:** it restored
  `"activeInspectorSection"`, and the key is `"inspector.activeSection"`. A save/restore pair is only as
  good as its key string, and nothing type-checks that string.
- **The entry's carve-out was wrong.** It said the fixture class "should keep writing the real keys",
  which is fine in isolation but not while `ActivitySectionTests` also wrote
  `inspector.activeSection`: **two** legitimate writers race each other just as badly. That reproduced —
  a `.files` write landing between the fixture seam's write and its read failed
  `testUnknownSectionArgumentFallsBackToChanges` about once in five 8-iteration parallel batches. So the
  real invariant is *one* writer per key, and XCTest parallelises per **class**, which makes it
  structural rather than documentary: all of it now lives in `SharedPrefDefaultsTests` (the old
  `UITestFixtureDefaultsTests`, absorbing the visibility + persistence guards), and
  `ActivitySectionTests` asserts the raw-string round-trip and the unknown-value fallback against a
  private probe key — those are properties of the *type*, so a key nobody reads proves them identically.
- **The verification that matters** (the shape the diff-mode fix used): pin the Dev domain to the values
  the tests used to overwrite — `showNotificationsInspector=0`, `inspector.activeSection=files` — and run
  the affected classes 8× parallel. Green, and the two keys still read `0`/`files` afterwards, so the
  tests are hermetic *and* no longer leak. Full unit suite **1292 passed / 0 failed / 1 skipped**.

**2026-07-26 — the red tests were both a shared-state bug, not the bug they looked like.** Two entries
retired from *P3 — Tests and tooling*; the diagnosis in each was wrong, which is the part worth keeping.

- **Five diff UI tests were red because they read the developer's preferences.** The filed suspicion was
  an accessibility regression — `diff.line` leaves swallowed by a parent container. It wasn't: dumping
  `XCUIApplication.debugDescription` for an open diff showed a fully populated tree of
  `diff.side.left`/`diff.side.right` cells and `tab.toolbar.diffSideBySide` marked `Selected`. The app was
  simply **in side-by-side**, and `diff.line` is emitted only by the *unified* renderer. Cause:
  `Defaults[.diffViewMode]` is a Settings picker persisted in the app's real (Dev) UserDefaults domain,
  this machine's held `sideBySide`, and the tests asserted on "the global default" without pinning it.
  Fixed at the source — `UITestFixture.applyInspectorDefaults` (which already existed to stop exactly this
  leak for the inspector) is now `applyFixtureDefaults` and pins the diff layout too, defaulting to
  unified with a `-WorkroomUITestDiffViewMode` opt-out; `DiffViewerUITests` passes the layout on **every**
  launch, and `DiffHighlightUITests` pins unified. All 7 + 2 tests in the two classes pass.
  Verification that matters: set the Dev domain **back** to `sideBySide` and re-run — still green, so the
  tests are hermetic rather than merely agreeing with the machine. Trap: three of those tests were filed
  as red and the other two were never noticed, because the UI suite needs a GUI login session and is
  excluded from the `make app-test` gate — the exact way tests rot unseen. Cost of pinning: a fixture
  launch overwrites these keys in the **Dev** domain (the release app's are untouched), so a UI-test run
  resets the Dev app's inspector + diff-mode choices. Deliberate trade, documented on the seam.
- **The `confirmOnCloseTerminal` race is closed** by `AppStore.confirmOnCloseOverrideForTesting` — a
  per-store override the close-behaviour tests set instead of writing the shared key. `AppStoreCloseTabsTests`,
  `EmptiedWorkroomSelectionTests` and `RunCommandTests` no longer touch `Defaults` for it at all (both
  classes' save/restore `setUp`/`tearDown` pairs are gone; the value now lives in each `makeStore`), leaving
  `ConfirmOnCloseTerminalTests` — which legitimately asserts the shipped default — as the only writer. The
  four-class × 20-iteration `-run-tests-until-failure` repro that used to fail on a *different* test almost
  every run is now clean, and the mechanism is gone, not just quiet. The residual same-shape hazard on
  `showInspector` was filed as P3 and is now closed too — see the 2026-07-26 entry above it.

Full unit suite after both: **1279 passed / 0 failed / 1 skipped** (+3 tests — `UITestFixtureInspectorTests`
became `UITestFixtureDefaultsTests`, since renamed again to `SharedPrefDefaultsTests`, and covers the
diff-mode half of the seam, including the assertion that would have caught this: a persisted `sideBySide`
must not survive a fixture launch).

**2026-07-25 — two timing flakes killed (a unit one and a UI one).** Both were the same mistake in two
dialects: a *fixed* wait standing in for an event that has no fixed arrival time.

- **`RunCommandTests`' graceful-teardown tests** asserted "the tab closed" / "the completion ran" after a
  flat `settle(0.2)`, but `AppStore.pollUntilExited` only notices an exit on a 0.1s main-queue timer, and
  under the parallel suite that timer can slip past the sleep. A new `waitUntil` helper pumps the runloop
  until the outcome holds (5s ceiling), and all four positive assertions in the section now use it; the
  one *negative* assertion keeps its dwell, because showing nothing happened needs one. Also raised that
  test's `gracefullyStopAllRunCommands(timeout:)` from 2s to an unreachable 300s: the test is about the
  wait ending because the processes exited, so a slow machine hitting the fallback was a second way to
  fail (and, on the last assertion, a way to pass for the wrong reason). The timeout path has its own test.
- **`TabActionsUITests.openDiffPreview`** clicked the Changes row as soon as it *existed*, which isn't the
  same as being hit-testable — an early click is swallowed silently. It now waits for hittability
  (advisory), retries the click once if no diff tab appears, and allows the tab the same 10s as every
  other wait in the helper (6s was the tightest budget in the sequence and the first to give under load).

Traps worth keeping: **CPU starvation does not reproduce this class of flake** — 12 hogs × 25 iterations
left the *old* code green, because timer slippage here comes from main-queue coalescing in a
non-foreground test host, not from CPU pressure. What does verify the fix is a probe of the property
itself: schedule a flag 1.2s out, confirm `settle(0.2)` can't see it and `waitUntil` can. And once fixed,
the UI test held up in the exact three-class batch that had flaked it.

**2026-07-25 — git commit diffs detect renames.** `Core/GitCommitDiff.swift` builds a commit's diff on
raw libgit2 (`git_diff_tree_to_tree` + `git_diff_find_similar`, renames only, matching git's
`diff.renames=true` default) and `GitProvider.changeset`/`.fileDiff` both read through it, so History's
file list and its patch text can't disagree. The stated blocker in the old entry was stale — the
`libgit2` product was already linked directly for `GitGraph`; what's real is that a SwiftGitX `Diff`
can't be post-processed (deltas materialized in an `internal` init, the `git_diff` freed in a `defer`,
repo pointer `internal`). `Core/LibGit2.swift` now owns the single `git_libgit2_init` for both raw
readers. Two things fell out of replacing that call: a rename's `+N −M` shrinks to git's numbers, and
**root commits list their files at all** — SwiftGitX diffs a first commit against itself, so History had
been showing none. The cross-backend divergence test is now
`testColocatedCommitRenameMatchesAcrossBackends` (parity, both directions, patch text included).

**2026-07-25 — git working ± line counts moved off SwiftGitX.**
- The badge counts read `git_diff_get_stats` through raw libgit2 (`Core/GitDiffStats.swift`) instead of
  summing a SwiftGitX `Diff`. The cost wasn't the diff — that's irreducible, it's what
  `git diff --shortstat` costs too — it was that **SwiftGitX's `Diff.init` is eager**: it builds a
  `Patch` per delta and materializes every hunk line into a Swift `String` before the caller sees the
  value. So two integers cost one `String` + a `Line` struct per changed line of the whole worktree, on
  every status refresh (sweep/focus/appear). libgit2 counts in C and allocates nothing Swift-side.
  **Measured, don't estimate: 1.7× (115ms → 68ms)** on 300 files × 200 lines with every line changed
  (60k insertions / 60k deletions), both engines returning identical counts. Modest on purpose — the
  diff dominates and can't be removed; what's gone is the Swift materialization on top of it. On a
  small dirty tree the saving is proportionally small, which is why the entry was scoped to large ones.
- **It was also wrong, and that's the part worth remembering.** The hand-rolled sum counted SwiftGitX's
  `.additionEOF`/`.deletionEOF` — the `\ No newline at end of file` markers — as real lines. They're
  always paired with a genuine addition/deletion, so a file whose trailing newline changed reported
  **2 deletions where git reports 1**. libgit2's `git_patch_line_stats` skips them and says why in its
  own source comment; `git diff --numstat` agrees. This landed alongside the rename work above, which had
  already moved the `changeset` counts onto the same C call, so `diffLineStats` — the hand-rolled sum, and
  the last EOFNL over-counter — lost its final caller and is **deleted**: no `+N −M` in the app is summed
  off SwiftGitX hunk lines any more. Pinned by two tests that assert against real `git --numstat` output
  rather than against arithmetic in the test.
- `GitDiffStats` opens its handle through `Core/LibGit2.swift` (the rename work's shared owner of
  `git_libgit2_init`), now serving three raw readers. **Residual, deliberately not chased:**
  `workingStatus` opens two repo handles per refresh (SwiftGitX's for the file list, ours for the counts).
  Cheap next to the diff, and it collapses on its own if that read ever goes raw-libgit2 — SwiftGitX keeps
  its `git_repository` pointer `internal`, so there's no way to borrow one today.
- Trap: an unborn HEAD has no tree to diff, and libgit2 spells "empty tree" as a NULL `git_tree *` —
  the same choice SwiftGitX made, kept so a just-initialized project's badge doesn't go blank. There's
  no git answer to check it against (`git diff HEAD` is fatal without a HEAD), which is exactly why it
  needs its own test.

**2026-07-25 — tab strips (#129 follow-ups) and the pane floor.**
- **`WorkroomTabChip`'s title is capped** at 180pt like the terminal chip, with the full title in the
  tooltip. Trap: the workroom title is two `Text`s plus a separator, so the cap goes on the wrapping
  `HStack` — per-`Text` caps truncate the halves independently and eat the workroom name first. A cap test
  needs a *lower* bound too, or it passes vacuously whenever the long-name fixture fails to apply.
- **The overflow scaffolding is one container** (`Views/OverflowingTabScroller.swift`): both strips'
  width measurements, the predicate, the fade and the load-bearing modifier order now live in one file.
  The content closure still receives `overflowing` because both strips gate a hairline on it.
  `WindowMovableController` stays in `WorkroomTabBar`, outermost. The one real change was unifying on
  `.frame(maxWidth: .infinity)` for the terminal strip, which its two geometry tests confirm is inert.
- **Panes have a per-axis floor:** `minPaneWidth` 300, `minPaneHeight` 120, threaded through
  `PaneTreeLayout.minPane(along:)`. One 120pt constant had been serving both axes, which put the width
  floor below the width the strip needs for its own chrome — measured, a diff tab's toolbar alone is
  ~145pt and the whole strip needs ~293pt. Trap: measure this furniture, don't estimate it; the AX frames
  report the *glyph*, so each toolbar button is glyph + 8pt of padding. Side-by-side splits now need
  604pt of pane, which is the honest number.
- **A selected chip is scrolled into view** in both strips, on selection change *and* on mount (a strip
  that appears with a selection already set would otherwise render at the start of its run). No
  per-shortcut plumbing was needed: every path funnels through `TerminalSessions.setFocused` /
  `AppStore.selectedTargetID`, so one `.onChange` sees them all. The mount reveal hangs off the width
  measurements, not `onAppear` — before layout, `scrollTo` is a silent no-op. Traps, both found by
  running rather than reasoning: `window.contains(chip.frame)` is the WRONG visibility test for the
  terminal strip (its visible trailing edge is far inside the window, so the assertion passes on a chip
  that is scrolled away — anchor to the pinned "+" instead), and the chips' `.isSelected` trait is not
  queryable as an AX attribute on macOS, so a test can't ask which chip is selected.

**Dropped, so they don't get re-proposed (2026-07-25):**
- **Collapsing the terminal tab toolbar into a `⋯` menu at narrow widths.** Its whole premise was the
  120pt pane; with the 300pt floor there are no degenerate panes, so it only bought chip room on a
  diff/markdown tab in a narrow split. Not worth the native-menu semantics and the ten UI tests that
  query the toolbar as real buttons. If the diff toolbar grows, the cheap slice is dropping `closeAll`
  from it — that action already exists in File ▸ Close All Tabs and the chip context menu.
- **Drag-edge auto-scrolling** the tab run. The scroll-on-select half shipped and covers the actual
  complaint ("the shortcut did nothing"); auto-scroll would perturb `TabReorder`'s translation math and
  `clampReorder`, which has no unit tests.
- **Signalling the refused `⌘D` split.** The refusal is silent and now fires more often (604pt, up from
  244pt), but it tested fine by hand. Revisit only if "⌘D did nothing" is actually reported.

**2026-07-25 — jj native reads (all five in `vcs/crates/wr-vcs-core/src/jj_backend.rs`).**
- **± line counts** now come from ONE `materialized_diff_stream` per read, so the change kind and the
  counts are the same entry, first-parent-anchored by construction. Deliberately **no** aggregate field
  on `WorkingStatus`/`CommitChanges` — a stored total beside the rows is the second representation that
  caused the bug. `None` counts mean *not counted, never zero* (binary, >4 MiB, non-file). Conflicts
  **do** count their markers, matching `jj diff --stat`, a git worktree diff, and our own commit header;
  `VCSStatusPresentation.lineCountsHelp` says so in both the tooltip and the VoiceOver label. Deleted
  `parseDiffStat`, `commitStatArgs`, and `changeset`'s `--stat` pair: **3 fewer `jj` processes**.
- **Log + branch-label order** go through one `ancestors_revset` helper (jj-lib's `::@`, descending
  commit position = topological). Timestamps were never a graph order; the old max-heap could surface a
  commit above its own descendants. `first_bookmark_in_log_order` shares that walk, so the sidebar can't name a
  bookmark History doesn't show — and it now stops at the first bookmark instead of deserializing every
  ancestor. git's side keeps libgit2 `GIT_SORT_NONE` (= `git log`'s own default), so each backend
  matches its own CLI; do not "unify" them.
- **Error taxonomy** is classified at the source instead of one `fn io()`. Two were latent bugs, not
  labels: `FileLock::lock` blocks on `flock` forever (a `jj` command in a terminal used to stall the
  status sweep and hold a `JJSnapshotGate` slot) — now a non-blocking `try_lock` probe; and
  `WorkingCopyFreshness::check_stale` now runs, so a working copy another workspace rewrote reports
  `StaleSnapshot` instead of being snapshotted from a stale base. App side: `VCSStatusFailure.busy` /
  `.staleWorkingCopy` replace "not a repository" for both.
- **Rename detection** via `diff_stream_with_copies` + the backend's copy records: one `Renamed` row
  with `old_path`, in the Changes panel and History. Backend-dependent by design (jj's `simple_backend`
  returns no records). `Conflicted` beats rename, but defensively only — a conflicted path can't carry a
  copy record, so a conflicted rename decomposes into `Added` + `Conflicted`.
- **Per-file conflict status** classifies an unresolved `after` value as `Conflicted` *before* the
  presence tests (an unresolved merge never satisfies `is_absent()`, which is a *resolved* `Some(None)`
  — why conflicts read as `Modified`). UI: `"!"` in `tokens.conflict`, mapped in `Core/ChangeBadge.swift`.
  CI now runs `cargo test` at all.
- **Merge working-copy diffs**: `jj diff -r @` diffs a merge against its *auto-merged* parents while the
  file list is a tree diff against the FIRST parent, so any file differing only from the first parent
  listed but showed "No changes". `workingFileDiff` resolves `@`'s first parent and diffs `--from <id>
  --to @` (`--from @-` can't express it — `@-` on a merge is several revisions).
- **Chrome glyph buttons' `isHittable == false`** — closed as an environmental XCUITest artefact, not an
  a11y defect; nothing in the app was wrong. Two misleading comments removed, replaced by real guards
  (`testChromeGlyphButtonsAreHittableWhenInline` / `…WhenPinned`).

**Traps worth knowing before touching the same code:**
- A **single-parent or linear fixture cannot expose** the merge/ordering bugs at all — the two bases
  coincide, the heap frontier is size one. Ordering tests need a merge AND skewed timestamps
  (`JJ_TIMESTAMP`); merge tests should assert `parents.len() == 2`.
- `jj diff --stat` prints its summary line even when nothing changed, so a test asserting the *absence*
  of "insertions" passes for the wrong reason — assert the file count.
- No jj fixture may address commits **by bookmark**: with `experimental-advance-branches` (as in the
  author's config) `jj commit` advances the bookmark onto the new commit, collapsing the two merge sides
  and silently producing no conflict. Also: don't `unsafe set_var("JJ_CONFIG")` from parallel `#[test]`s.
- XCUITest's `isHittable` uses **accessibility** hit-testing: neither a covering non-AX overlay nor a
  `0×0` frame turns it false — only a real AX element or another window over the point. A window that
  wasn't frontmost explains the original sighting.
- Conflict-marker counting depends on marker **style**, so "The jj snapshot ignores the user's real
  jj/git config" must fix `materialize_options()` too, not just `snapshot_working_copy`.

**2026-07-24.** `JJSnapshotGate` (per-project-root chain-of-tails actor) serializes every jj-mutating
snapshot across the status fan-out — status sweep, selection refresh, file-watch, `.jjWorkingCopy`
diffs, and `FileTreeModel.list`'s ungated `jj file list`; `maxChainWait` (30s) stops one hung native
call wedging a project's whole queue. `add-project --pretend` is a real dry-run on the non-create path.
Pending sheets clear in `removeProjectLocally()` when they target the deleted project.

**2026-06-24 audit.** Shipped: workroom tab-chip management actions (#23), hardened `gh` auth (#86),
live branch-label refresh (per-project FSEvents on each root's `.git`/`.jj`). Narrowed: at-a-glance
review status (label + PR badge shipped; glyph + sweep stage remain), per-pane activity flash.
**Dropped (won't do):** per-file diff view-mode persistence — the in-memory per-tab toggle is enough.

**2026-06-09.** Splits (A5), the UI-test fixture seam, and terminal notifications (#10) landed.
