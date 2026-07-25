# TODOs

> Status note (2026-07-25): **Done & removed:** jj vs git **rename detection** divergence. A renamed
> file now reads as one `Renamed` row carrying `old_path` instead of delete-old + add-new, in both the
> Changes panel and History. `changed_files` (`jj_backend.rs`) drives
> `diff_stream_with_copies` and feeds it the backend's copy records (new `copy_records` helper), so
> jj-lib owns the rename-vs-copy call: a surviving source is `Copied`, a vanished one `Renamed`, and
> jj-lib suppresses the paired delete entry itself. Backend-dependent **by design** — the git backend
> implements records (gix rewrite tracking, 50% similarity, 1000 candidates), jj's own
> `simple_backend` returns none, so a non-colocated repo keeps reporting delete+add rather than
> erroring; a per-record error is skipped for the same reason (it costs the rename *label*, never a
> file). `Conflicted` still wins over rename, but that ordering is **defensive only**: probing showed a
> conflicted path can't carry a copy record at all, because records come from each commit's *git* tree
> and jj exports a conflict as `.jjconflict-*` sidecar trees — so a conflicted rename decomposes into
> `Added` + `Conflicted` (pinned, with the reason, by `a_conflicted_rename_does_not_pair_into_one_row`).
> App side: `ChangedFile` gained `oldPath` (filled by BOTH providers — git's was being dropped), the
> changeset detail row and its tooltip read `old → new` via a new testable `ChangeBadge.pathLine`, and
> the single-line panel row carries the old path in its tooltip + VoiceOver label. Coverage: 4 cargo
> tests (working copy, committed rename with an edit, copy-not-rename, the conflict decomposition), 2
> conformance tests, 2 `ChangeBadge` unit tests, 1 XCUITest — all negative-checked. **Found on the
> way:** git *commit* diffs never had rename detection either (`repo.diff(commit:)` with no
> `find_similar`), which inverts the divergence for History; that's now its own TODO below, with the
> conformance test pinning the gap instead of asserting a parity that doesn't hold.
>
> Status note (2026-07-25): **Done & removed:** the working-copy diff for a **merge** `@`. Reported
> live right after the conflict badge shipped — clicking a conflicted row opened a tab reading "No
> changes". Root cause was NOT conflict-specific: `jj diff -r @` diffs a merge against its
> *auto-merged parents*, while the Changes list comes from `changed_files`, a tree diff against the
> FIRST parent. Any file differing only from the first parent therefore listed but reported no diff —
> every conflicted file (a conflict *is* the auto-merge result, so the diff is always empty) and also
> an ordinary file arriving from the other side of a *clean* merge, which reproduced on a
> non-conflicted fixture. `RustJJProvider.workingFileDiff` now resolves `@`'s first parent
> (`firstParentID`, one read-only `--ignore-working-copy` log) and diffs `--from <id> --to @`;
> `--from @- --to @` can't express it, since `@-` on a merge resolves to several revisions and jj
> errors. Identical to `-r @` for a single-parent `@`, and it falls back to `-r @` if the parent can't
> be read. Covered by `testMergeWorkingCopyFileDiffsAreNotEmpty` (conflict markers render AND the
> other-side file renders — both empty before the fix) plus an args unit test. The `.parent` axis has
> the same latent ambiguity and is left as-is: it's unreachable from the UI.
>
> Status note (2026-07-25): **Done & removed:** jj per-file conflict status now reaches the UI.
> `jj_backend.rs` `changed_files` classifies an unresolved `after` value as
> `ChangeKind::Conflicted` **before** the presence tests (an unresolved merge never satisfies
> `is_absent()`, which is a *resolved* `Some(None)` — that's why conflicts read as `Modified`). Kept in
> the shared `changed_files`, so conflicted *commits* report it too (jj stores conflicts in the tree;
> git can't, so `VCSProviderConformanceTests.testColocatedConflictedCommitDivergesByDesign` now pins
> that allowed divergence — a colocated git repo sees jj's `.jjconflict-*` sidecar trees, not the
> conflicted path). Coverage: 4 new cargo tests (per-file kind + a **no-corruption guard** proving the
> conflict survives the lock-taking snapshot, both-added → `Conflicted`, conflict-then-deleted →
> `Deleted`, conflicted changeset) and `WorkroomStatusIntegrationTests.testJJConflict` (the jj twin of
> `testGitConflict`, covering Rust → UniFFI → `WorkroomStatus`). Two harness fixes found on the way:
> the cargo tests no longer `unsafe set_var("JJ_CONFIG")` from parallel `#[test]`s (passed per
> `Command` instead), and **no fixture addresses commits by bookmark** — with jj's
> `experimental-advance-branches` enabled (as in the author's own config), `jj commit` advances a
> bookmark onto the new commit, which collapsed the two merge sides and silently produced no conflict
> at all. Also **UI**: `ChangesPanel` rendered `.conflicted` as `"C"` in `diffRemoveFg` — deletion's
> red — so it's now `"!"` in a new palette-derived `tokens.conflict` orange, with the letter/colour/word
> mapping extracted to `Core/ChangeBadge.swift` and unit-tested (7 kinds). And **CI now runs
> `cargo test`** (`.github/workflows/ci.yml`); the entire `wr-vcs-core` suite had never run there.
>
> Status note (2026-07-24): **Done & removed:** serialize jj working-copy snapshots across the
> status fan-out (VCS-foundation eng-review) — added `JJSnapshotGate` (a per-project-root
> chain-of-tails actor, `macapp/WorkroomApp/Core/JJSnapshotGate.swift`), threaded through every call
> site that reaches a jj-mutating snapshot: `WorkroomStatusResolver.resolveJJ` (covering the status
> sweep, selection refresh, and file-watch lanes), `DiffResolver`'s `.jjWorkingCopy` diff, and
> `FileTreeModel.list`'s `jj file list` (found ungated by adversarial review after the initial fix —
> it has no `--ignore-working-copy` either). Fixed the stale "one probe at a time" comments that
> only ever described one lane. Also closed a real "self-inflicted deadlock" risk both a Claude
> adversarial pass and Codex independently flagged: a genuinely-hung (never-returning) native jj-lib
> call would otherwise permanently wedge a project's whole queue — `JJSnapshotGate.maxChainWait`
> (30s, injectable) bounds this: a new call gives up waiting on a stuck predecessor after the
> ceiling and proceeds anyway, so the queue self-heals instead of blocking forever.
>
> Status note (2026-07-24): **Done & removed:** `add-project --pretend` for the non-create path is
> now a real dry-run — gated the `Config.AddProject` write behind `!pretend`, mirroring the
> `--create` dry-run envelope shape (`would_create: false`). Also **done & removed:** pending sheets
> (`pendingProjectSettings`/`pendingWorkroomLabel`) now clear in `removeProjectLocally()` when they
> target the deleted project — closes the #127-follow-up stale-config-leak gap.
>
> Status note (2026-06-24): re-audited against the codebase. **Done & removed:** workroom tab-chip
> management actions (#23 follow-up — context menu + "+" button shipped in `8eee2b0`), harden-`gh`-auth
> (#50 follow-up — `#86`/`60af731` added the `--json hosts` + transient-vs-real classification the item
> asked for), and **live branch-label refresh** (per-project FSEvents watchers on each root's
> `.git`/`.jj` now update the sidebar label live; `BranchResolver` resolves jj read-only via
> `--ignore-working-copy`). **Narrowed (partial):** at-a-glance review status (the `reviewDecision`
> label + PR-state badge shipped; only the sidebar glyph + PR sweep stage remain), and the
> workroom-split per-pane activity flash. **Dropped (won't do):** persist per-file diff view-mode — the
> in-memory per-tab toggle is enough; per-file persistence isn't worth the unbounded-map upkeep. Items
> are ordered roughly by priority: the before-GA work (CMT-2, CMT-3) first, then the P3 niceties.
>
> Earlier (2026-06-09): the **splits** feature (A5) and the **UI-test fixture seam** shipped, and the
> **terminal notifications** feature (#10) landed — unblocking auto-emit OSC and notification preferences.

## Own the GhosttyKit xcframework (macapp) — CMT-2

**What:** Stop depending on the third-party `libghostty-spm` (Lakr233) package as the source of
truth. Build our own universal `GhosttyKit.xcframework` (`macos-arm64_x86_64`) + version-matched
resources from a ghostty ref *we* pin, and point `project.yml` at it.

**Current state:** `macapp/project.yml` still pins `libghostty-spm` at `exactVersion: 1.2.3`.

**When (trigger-based, lean sooner than "vague pre-GA"):** Not needed for the beta — `1.2.3` works
with our fixes (see the keyboard-input + terminal-input commits). Do it when the **first concrete
trigger** hits, and treat it as the **next infra task after the beta stabilizes**:
- We want an **unreleased ghostty change** — concretely **OSC 99** (PR #10467), the backspace-keycode
  fix, or the libghostty OSC fallback-handler — none of which exist in any ghostty *release*, so no
  libghostty-spm release can ever deliver them.
- We want to be on **ghostty 1.3.x** (see lag below).
- libghostty-spm stalls or makes a pin choice we don't want.
- **GA** — do it regardless of features: shipping GA on a single-maintainer repackaging of an
  explicitly-unstable API is a supply-chain risk; owning the pin is the control.

**Why (reinforced by observed facts, 2026-06-05):**
- The embedding C API is explicitly unstable/internal ("breaking changes are expected").
- **The packager already lags upstream.** ghostty has released **v1.3.0 and v1.3.1**, but
  libghostty-spm is still on **`1.2.3`** (published 2026-06-01; tags 1.2.1→1.2.3 only). So "just use
  new libghostty-spm releases as they arrive" means trailing ghostty by ~2 versions on a single
  maintainer's cadence — the exact "packager lags" risk, now real, not hypothetical.
- Everything we'll want next (OSC 99 etc.) lives **upstream of any release** — only the owner-of-the-pin
  path can reach it. Muxy forked for exactly this reason.

**How to start (cheaper than a full fork — reuse the packager's tooling):**
- libghostty-spm ships a **`build.sh`** that builds the xcframework from a ghostty source dir
  (`./build.sh --source /path/to/ghostty …`). So: clone `ghostty-org/ghostty` at the chosen ref (a
  release tag, or a branch with PR #10467 cherry-picked), run `build.sh`, and **regenerate
  `terminfo`/`shell-integration` from that same ref** (fixes the SOURCE.md version-skew TODO).
- Vendor the resulting xcframework + a 2-file C shim (`GhosttyKit.c` + `module.modulemap` exposing
  `ghostty.h`), linking the static archive via `.unsafeFlags`, **or** host it as a release artifact in
  a separate repo's CI and point the SPM package there. Zig is needed only to *build*, not to
  *consume*.
- Re-verify signing — still a static archive in the main executable, so no new framework to sign
  (plan §4).

**Depends on:** nothing in-app — it's a dependency-source swap (`macapp/project.yml`,
`macapp/Resources/ghostty/`). Best done when we've picked the target ghostty ref.

**Re-verify after the upgrade (known gaps to recheck):**
- **OSC 99 desktop notifications** — ghostty has no OSC-99 (Kitty notification) parser in any release
  *or* `main` yet (only OSC 9 / 777 notify); `\e]99;;…` parses as invalid and is dropped, so it never
  reaches the app. There's an **open upstream PR — ghostty-org/ghostty#10467** ("parse the Kitty
  desktop notification protocol (OSC 99)"). When building our xcframework, pick a ghostty ref that
  includes #10467 (or cherry-pick it) and confirm OSC 99 fires — the app pipeline is already proven
  via OSC 9. Alternative: ghostty's in-progress libghostty fallback-handler for unknown OSC could let
  us parse OSC 99 app-side instead of patching the engine. OSC 9/777 cover the common cases meanwhile.
  See `macapp/QA-libghostty.md` §H.
- **Backspace keycode encoding** — 1.2.3 mis-encodes the backspace *keycode* (emits a space); we
  work around it by sending DEL as text (`GhosttySurfaceView.filterSpecialCharacters`). If the
  upgrade fixes the keycode path, the workaround can be simplified.

**Priority:** P2 now / **P1 before GA**. Trigger-based: not blocking the beta (ships on the
third-party pin), but it's the next infra task once the beta is stable — and the observed packager
lag (1.2.3 vs ghostty 1.3.1) means leaning sooner beats waiting on the packager.

## Terminal *content* accessibility (macapp) — CMT-3

**What:** VoiceOver support for the terminal's *rendered text* on `GhosttySurfaceView` — accessible
value (screen text), selected text, and change notifications — so the terminal content is navigable
with assistive tech.

**Done so far:** the **UI-tree** a11y has landed (commit `f3859f9`) — `PaneTreeView` exposes each
leaf as `terminal.pane` with a label ("Terminal <title>, pane N of M"), a focused/selected trait, and
an adjustable split divider (`pane.grip`). What's still missing is the *content* layer: the
libghostty surface is Metal-rendered, so its text is pixels — invisible to the accessibility system.
Today the surface view sets `role=.textArea` + a label only; it exposes **no value and no selection**,
so VoiceOver reads nothing inside the terminal. Accepted regression for the beta (CMT-3). This is also
the **enabler for content-level UI tests**: once terminal text is in the a11y tree, XCUITest can
assert on rendered output (backspace deleted, TUI drew, scrollback) on top of the now-landed fixture
seam — see `macapp/QA-libghostty.md` (Bucket 2).

**When:** **sequence with the xcframework upgrade** (CMT-2), not now. Feasible on 1.2.3 today (read
APIs exist), but ghostty upstream has merged a11y plumbing we'd want to ride — e.g.
**ghostty #12902** ("core: send selection_changed notification"), which on macOS posts
`.ghosttySelectionDidChange` → debounced → `NSAccessibility.selectedTextChanged`. On 1.2.3 we'd have
to post that notification ourselves on our own selection events; post-upgrade it comes from the
engine. A before-GA item.

**How to start (minimal-viable, keep light per D1 — crib Muxy's `accessibilitySelectedText()`):**
- `accessibilityValue()` → visible screen text via `ghostty_surface_read_text(surface, <viewport
  ghostty_selection_s>, …)` (reuse the `extractString(from:)` helper).
- `accessibilitySelectedText()` → `ghostty_surface_read_selection` (the same read that powers
  copy-on-select).
- Post `NSAccessibility.post(element:notification:)` `.selectedTextChanged` on selection change
  (we already detect mouseUp / copy-on-select) and a throttled `.valueChanged` on output so
  VoiceOver follows along; keep the role/label and report focus.
- Skip the full `NSAccessibility` text protocol (line/char-range/bounds geometry) — overkill for a
  terminal, and Muxy keeps it minimal too.

**Caveat:** terminal a11y is inherently partial (dynamic output, scrollback, full-screen TUIs);
target "announce output + selection, navigable text", not a perfect document model.

**Depends on:** the read APIs already present in 1.2.3 (`ghostty_surface_read_selection`,
`ghostty_surface_read_text`, `extractString`) in `macapp/WorkroomApp/Core/GhosttySurfaceView.swift`;
best done after CMT-2 to use ghostty's `selection_changed` hook.

**Priority:** P2 (accessibility regression — address before GA, not blocking the beta).

## Auto-emit OSC notifications on command completion (macapp)

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

## Notification preferences (macapp)

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

## Memory / live-surface diagnostics (macapp)

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

## OSC 52 clipboard-confirmation policy (macapp)

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

## Deferred UI workflow tests (macapp)

**What:** The two workflow UI tests left to write on top of the now-landed fixture seam:
1. **Notification badge + click-to-navigate** — drive a terminal to `printf '\e]9;…\a'`, assert the
   sidebar/tab badge appears, click it, assert it navigates to (and clears on) the right terminal.
2. **Delete-workroom-clears-badges** — assert deleting a workroom withdraws its notifications/badges.

**Why:** The fixture seam itself is done (`Core/UITestFixture.swift` + `-WorkroomUITestFixture 1`
gives deterministic, CI-able state — see `AppStore.loadFixture()`), and the split-pane + basic
workflow suites pass deterministically (no `XCTSkip`). These two notification/delete flows are the
remaining gap, called out explicitly in `WorkroomWorkflowUITests.swift` ("Still to add: …").

**How to start:** Add the tests to `macapp/WorkroomAppUITests/WorkroomWorkflowUITests.swift` using
the existing fixture launch arg and the `sidebar.*` / `terminal.tab.*` accessibility identifiers. The
badge assertions need the notification a11y identifiers to be queryable — add them if missing.

**Depends on:** the fixture seam + accessibility identifiers already in place
(`macapp/WorkroomApp/Core/UITestFixture.swift`, `Views/ProjectSidebar.swift`,
`Views/TerminalTabStrip.swift`).

**Priority:** P3 (the smoke + opportunistic suites cover the basics; these harden the notification
flows).

## Run-terminal persistence / auto-restart across relaunch (macapp) — #7 follow-up

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

## Stopped run-tab silently closes instead of warning when its command is cleared (macapp) — #127 follow-up

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

**Priority:** P3 (pre-existing, narrow repro — needs a run to have started and stopped, then the
command cleared before the next ⌘R; surfaced by the #127 eng/outside-voice review, not reported by a
user).

## Workroom split: deferred follow-ups (macapp) — #23

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
- **Cross-relaunch persistence of the split** — `workroomSplit` is session-only (the terminal split
  isn't persisted either). Add a `Defaults` key + restore-on-load if wanted.
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

## Theming: auto-pair user `~/.config` themes into families (macapp) — #36 follow-up

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

## Per-reviewer comment counts in the PR panel (macapp) — #52 follow-up

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

## At-a-glance review status in the sidebar / collapsed PR header (macapp) — #52 follow-up

**What:** Surface a compact review-status glyph (the aggregate `reviewDecision` — approved /
changes-requested / review-required) on the sidebar workroom row or the collapsed "Pull Request"
section header, next to the existing CI glyph — so review state is visible without expanding the
panel. Directly serves issue #52's framing ("so we can go visit the PR when needed").

**Current state (2026-06-24):** still expanded-panel only. `#77` added a PR-state badge to the PR
header (`ChangesPanel.swift` `prNumberLink`) and the `reviewDecision` aggregate label sits above the
reviewer rows in the inspector (`PullRequestPanel.swift` `PRPresentation.reviewLabel`) — but the
sidebar workroom row still shows dirty/CI only (`ProjectSidebar.swift` → `VCSStatusCluster`), and the
background sweep still skips PR resolution. The aggregate is the natural feed for a glyph.

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

## Keyboard + VoiceOver parity for the edge-hover reveal (macapp) — #56 follow-up

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

## Profile inspector pane body during live divider-drag (macapp) — NSSplitView inspector follow-up

**What:** Verify there's no stutter when dragging an inspector section divider with a large Changes
set. The NSSplitView inspector (shipped) hosts each section body inside a native `NSScrollView`, so
a vertical divider drag changes only the pane's *viewport height* — the body's `NSHostingView` keeps
its intrinsic (content) height and its width is unchanged, so SwiftUI should NOT re-lay-out per
frame. This TODO is to confirm that under profiling, not a known regression.

**Why:** `ChangesPanel` can render up to ~200 file rows **per list** — and for jj repos it now shows
**two** lists (Working Copy `@` + Parent Commit `@-`), so the worst case is ~400 non-lazy rows in the
pane (softened in practice: Parent Commit is collapsed by default, rendering 0 of its rows until
expanded). The original eng-review of the migration plan flagged per-frame re-layout as a risk; the
scroll-view pane design should avoid it (drag = viewport change, not document re-layout), but it
hasn't been profiled — and the two-list change raises the ceiling.

**How to start:** Instruments (Time Profiler / SwiftUI body re-evaluation) while dragging the
Changes divider on a jj fixture with both groups expanded (~400 rows). Only if jank shows: coalesce
resize → re-layout, or `.drawingGroup()` the body for the drag duration. Note `LazyVStack` won't help
here — the pane scrolls via AppKit `NSScrollView` with an intrinsic-size host, so there's no SwiftUI
clip rect to virtualize against.

**Priority:** P3 (likely already a non-issue by construction; confirm before optimizing).

## Own the main-window column layout so the inspector can be dragged wide (macapp)

**What:** Let the right inspector resize wider than its current 520 cap without crushing the left
sidebar, by taking the three-column layout (sidebar | detail | inspector) off SwiftUI's
`NavigationSplitView` + `.inspector` and onto a layout we control.

**Why:** `NavigationSplitView` manages its `sidebar | detail` columns through a *private*
`NSSplitView` subclass, and `.inspector` rides the same machinery. When the inspector grows SwiftUI
shrinks that inner split **proportionally**, so the sidebar loses width and its labels clip — even
when there's plenty of room (reproduced at a 1900px window). It can't be overridden: `setDelegate:`
and `setHoldingPriority:forSubviewAtIndex:` both *assert/crash* on the private subclass, and
frame-managed panes ignore Auto Layout width constraints. So 520 is only a safe ceiling, not a fix —
the inspector divider can't go wider without squeezing the sidebar.

**How to start:** Two shapes —
- **3a (most control, recommended):** replace `NavigationSplitView` + `.inspector` with one
  `NSSplitView` we own via `NSViewControllerRepresentable`, hosting three `NSHostingController`s.
  Our own split view accepts per-pane `minimumThickness` + holding priority, so the sidebar holds
  its floor, the detail yields, and the inspector resizes to any width.
- **3b (simpler, less native):** drop `NavigationSplitView` and lay the columns out in pure SwiftUI
  (`HStack` + explicit `@State` widths + drag-gesture dividers), enforcing min/max ourselves.

**Cost / risk:** medium-large, touches the app's primary window layout. `NavigationSplitView` gives
a lot for free that must be rebuilt: the unified toolbar spanning columns (back/forward over the
sidebar, bell over the inspector), native sidebar material + column show/hide animations, the system
sidebar toggle wired to `columnVisibility` (and the `View ▸ Projects` checkmark), `.detailOnly`/
`.all` visibility, and keyboard column nav. The edge-hover reveal (`EdgeRevealSidebar`, issue #56) is
built around `NavigationSplitView` collapse and would need rework. Put the toolbar / reveal /
visibility-menu regressions explicitly on the test list.

**Depends on:** nothing; supersedes the 520 inspector-width cap + the 240–360 sidebar bound, which
are the interim safe state.

**Priority:** P3 (only worth it if a wide inspector is a real workflow need; the current cap is a
zero-risk shipped state).

## Per-workroom collapse persistence for the jj Changes groups (macapp) — Working/Parent-commit follow-up

**What:** Scope the Working Copy / Parent Commit disclosure-group collapse state per workroom, instead
of the two global flags shipped today.

**Why:** The two groups persist their collapse state in global `Defaults`
(`changes.workingCopyCollapsed` / `changes.parentCommitCollapsed`, in `Core/DefaultsKeys.swift`), so
expanding/collapsing in one repo carries to every other repo. The inspector's three *sections* are
already per-workroom (`inspectorPaneStates`), so the inner groups are the odd one out. Surfaced by the
eng-review outside voice (codex).

**How to start:** Either add the two flags to the per-workroom `InspectorPaneState`
(`Core/DefaultsKeys.swift`) keyed by `targetIDString`, or a parallel `[String: …]` map like
`collapsedProjects`. They're global `@Published` flags on `AppStore` today
(`changesWorkingCopyCollapsed` / `changesParentCommitCollapsed`, Defaults-backed via `didSet`);
switch to a per-target lookup keyed by `store.selectedTargetID`.

**Depends on:** the shipped two-group panel (`Views/ChangesPanel.swift`).

**Priority:** P3 (global is acceptable for v1; revisit if the cross-repo carryover annoys).

## Structured diff model (`FileDiff` hunks) for the diff viewer (macapp) — 47b / VCS-foundation follow-up

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

## AppKit tracking-handle divider for an even wider resize target (macapp) — #83 follow-up

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

## Harden `vcs.Detect` to validate a real repo (CLI) — #103 follow-up

**What:** `vcs.Detect` (`internal/vcs/vcs.go`) currently treats a directory as a repo if `.jj` is a
dir OR `.git` merely *exists* (file or dir). A bogus/empty `.git` therefore registers as a project
via `add-project` and only fails later, at workroom creation.

**Why:** Surfaced by the Codex outside-voice pass during `/plan-eng-review` of issue #103 (the
create-project work). It's a pre-existing robustness gap — the existing-path `add-project` already
has it; #103's create flow inits a real repo so its happy path is unaffected — but a stricter check
would fail fast with a clear error instead of a confusing late failure. Re-confirmed by the Codex
pass during the jj→git stale-vcs fix: the new reconcile-on-list (`Service.effectiveVCS`) also uses
marker-file truth, so a *present-but-broken* `.jj` dir would still reconcile as jj — hardening
`Detect` fixes both the late-failure gap and the reconcile accuracy in one place.

**How to start:** In `Detect`, validate beyond existence — e.g. `git rev-parse --git-dir` (or read
`.git`/`HEAD`) for git, and confirm `.jj/repo` for jj. Weigh that `Detect` runs on every
create/list/delete (now also list-reconcile), so keep it cheap (a stat-level check may suffice over
forking git).

**Depends on:** nothing; touches all VCS consumers (`create`, `list`, `delete`, `add-project`).

**Priority:** P3 (pre-existing; create-new path inits a valid repo, so not blocking #103).

## Consolidate terminal focus authority + cross-window reconciliation (macapp) — focus-desync follow-up

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

## Stream the inline terminal agent's diagnosis into the banner — #49 follow-up

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

## Search section for the right activity bar (macapp) — activity-bar follow-up

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

<!-- The following were surfaced by /plan-eng-review of the unpushed VCS-foundation stack
     (2026-07-13), cross-model with a Codex outside-voice pass. The bug cluster (jj CLI pipe
     deadlock, snapshot file-size cap, base_ignores) was fixed in that review (b7dd9b7d); the
     items below were explicitly deferred. -->

## git commit diffs have no rename detection (macapp) — jj-rename follow-up

**What:** `GitProvider.changeset` reads `repo.diff(commit:)` (SwiftGitX → `git_diff_tree_to_tree`)
and never calls `git_diff_find_similar`, so a **committed** rename reports as delete-old + add-new.
`workingStatus` is fine — it passes `.renamesIndex`/`.renamesWorkingTree` — so the same rename pairs
in the Changes panel and splits in History.

**Why:** git's own CLI defaults to `diff.renames=true`, so `git show` on that commit DOES show one
rename row; our History disagrees with git itself. It's now also the ONE remaining cross-backend
rename divergence: jj reports the commit as one `.renamed` row (shipped), pinned by
`VCSProviderConformanceTests.testColocatedCommitRenameDivergesUntilGitDetectsIt` — which should be
rewritten into a parity assertion when this lands, NOT "fixed" by making jj match git.

**How to start:** SwiftGitX exposes no find-similar API and only vends its `SwiftGitX` product, so
this needs either an upstream addition or depending on its `libgit2` package product directly (mind
the modulemap collision noted in `macapp/CLAUDE.md` → VCS core). Then apply
`git_diff_find_similar` to the changeset diff before mapping deltas, and set `oldPath` for the
renamed delta (`mapDelta` already handles `.renamed`/`.copied`).

**Depends on:** nothing in-app. Touches `Core/GitProvider.swift` (+ possibly `project.yml`).

**Priority:** P3 (History file list wrong on committed renames; the diff content itself is correct,
and the Changes panel already pairs them).

## The Changes header's +/- still stats the wrong base for a merge `@` (macapp) — merge-diff follow-up

**What:** `WorkroomStatusResolver.resolveJJ` fills the Changes header's insertions/deletions from
`jj diff -r @ --ignore-working-copy --stat` (`WorkroomStatusResolver.swift:137-144`). For a **merge**
`@` that stats the auto-merged-parents diff, so the totals describe a different set of files than the
list beside them — the same bug fixed for `fileDiff`/`workingFileDiff`/`changeset` (75465a38 + the
commit-path follow-up), left alone here on purpose.

**Why not fixed with the others:** the fix needs `@`'s first-parent id, and this read runs in the 15s
status sweep fanned out per workroom — adding a second `jj` process per row to every sweep is the
wrong trade. The right fix is to stop paying for it at all: `working_status` already loads `@` in
jj-lib, so expose its parent ids on `WrVcs.WorkingStatus` (free) and pass the first one into the stat
args (`RustJJProvider.commitStatArgs` already takes a `from`).

**How to start:** add `parent_ids` to `model::CommitChanges` (or `WorkingStatus`) in
`wr-vcs-model`/`jj_backend.rs`, thread it through the UniFFI surface into `RustJJProvider
.workingStatus`, then anchor the resolver's `--stat` call. Cargo + Swift tests both have merge
fixtures to reuse (`conflicted_repo`, `jjMergeFixture`).

**Depends on:** the merge-base diff fix (shipped). Touches `jj_backend.rs`, `wr-vcs-model`,
`wr-vcs-uniffi`, `RustJJProvider.swift`, `WorkroomStatusResolver.swift`.

**Priority:** P3 (wrong-but-plausible numbers on merge working copies only; the file list and every
per-file diff are now correct).

## Conflicted working copies inflate the Changes header's +/- counts (macapp) — jj conflict-status follow-up

**What:** `WorkroomStatusResolver.resolveJJ` sources the header's insertions/deletions from one
`jj diff -r @ --ignore-working-copy --stat` (`WorkroomStatusResolver.swift:137-144`). A conflicted
working copy has materialized conflict markers on disk, so every marker line counts as a changed
line — a one-line conflict can read as dozens of changes.

**Why:** cosmetic, and invisible until now because jj conflicts never surfaced. With the `!` badge
shipped, the number sitting next to it is confidently wrong.

**How to start:** decide the semantics first — should a conflicted path contribute 0, contribute only
its real hunks, or should the header suppress the delta while `@` is conflicted? Then either exclude
conflicted paths from the stat parse or annotate the header. The counts are already best-effort (a
failed stat just drops them), so suppression is cheap.

**Depends on:** nothing. Touches `WorkroomStatusResolver.swift` + its tests.

**Priority:** P3 (cosmetic, newly visible).

## Three independent change-badge palettes (macapp) — jj conflict-status follow-up

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

## `withTimeout` doesn't observe the CALLER's own cancellation (macapp) — VCS-foundation eng-review, /review follow-up

**Status:** the original version of this entry (a `withThrowingTaskGroup` awaiting a detached
operation child past its own deadline) is **fixed** — `Core/Timeout.swift` now races via a single
`withCheckedThrowingContinuation` + a `TimeoutGate`, exactly the fix this entry used to recommend.
Re-audited during the jj-snapshot-serialization `/review` (2026-07-24, cross-model: Codex found it)
and found a **different, still-live** gap in that same seam.

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
caller still occupies a project's queue slot for up to its full timeout). Not corruption-causing
today: every call site already checks `Task.isCancelled` before merging a stale result
(`runLocalSweep`'s `if Task.isCancelled { break }`, etc.), so state stays correct — this is a
responsiveness/efficiency gap, not a data-integrity one.

**How to start:** Wrap `withTimeout`'s continuation in `withTaskCancellationHandler` so cancelling
the calling task settles the `TimeoutGate` early (same shape `JJSnapshotGate.run` already uses to
propagate cancellation into its own chained `Task`). Verify the existing "operation keeps running,
result dropped" contract still holds — this only makes the WAIT responsive to cancellation, not the
underlying synchronous native call (still uncancellable, unchanged).

**Depends on:** —. Touches `Core/Timeout.swift`. Broad blast radius (every `withTimeout` caller:
`WorkroomStatusResolver`, `BranchResolver`, `JJSnapshotGate`'s own internal use) — needs its own
careful review/testing, not a drive-by fix.

**Priority:** P2 (efficiency/responsiveness, not correctness; no user-visible bug today).

## Git working line-counts recompute the whole-worktree diff per refresh (macapp) — VCS-foundation eng-review

**What:** `GitProvider.workingLineStats` (`GitProvider.swift:~317`) runs `repo.diff(to: [.workingTree,
.index])` — the ENTIRE worktree diff — on every status refresh (focus/appear/manual), just to sum
±line counts for the badge. The per-file diff path was carefully kept per-file; this reintroduces
whole-worktree work for a cosmetic count.

**How to start:** Prefer libgit2's diff stats API if SwiftGitX surfaces it (avoids materializing every
patch), or make the badge counts lazy / cache them per (HEAD, worktree-generation).

**Depends on:** VCS read foundation. Touches `Core/GitProvider.swift`.

**Priority:** P2 (perf on large dirty trees; every refresh).

## jj log/current-ref use timestamp order, not topological order (macapp) — VCS-foundation eng-review

**What:** `jj_backend.rs` orders the log heap by committer timestamp (`HeapItem`, comment: "close
enough for the proof"), and `nearest_bookmark` walks ancestry newest-timestamp-first. Rebased/amended
commits or clock skew make History order (and the "nearest ancestor bookmark" pick) diverge from
`jj log`'s topological/index order.

**How to start:** Order by jj's graph/index position (revset evaluation order) instead of timestamp;
walk the DAG by generation for `nearest_bookmark`.

**Depends on:** VCS read foundation. Touches `jj_backend.rs`.

**Priority:** P2 (History mis-order + wrong branch label under skew/rebase).

## Real `VcsError` taxonomy across the UniFFI boundary (macapp) — VCS-foundation eng-review

**What:** `RustJJProvider.mapError` flattens every `WrVcs.VcsError` to `.io`, so
`WorkroomStatusResolver` reports lock-contention / stale-snapshot as `.notRepository`, and
`DiffResolver`'s `.lockContention`/`.staleSnapshot` handling + messages are dead code.

**How to start:** Map each `WrVcs.VcsError` case → the matching `VCSError` case in
`RustJJProvider.mapError` (and the `GitProvider` catch). Then the resolvers' typed recovery states
light up. This is the "error taxonomy" work from the Phase-1 plan (CQ2).

**Depends on:** VCS read foundation. Touches `Core/RustJJProvider.swift`, `Core/GitProvider.swift`.

**Priority:** P2 (typed recovery UI currently unreachable).

## Git diff shows one side when a file is both staged and re-modified (macapp) — VCS-foundation eng-review

**What:** `GitProvider` working diff/status use `entry.workingTree ?? entry.index`, so a file that is
staged AND further modified in the worktree renders only the working-tree (index→worktree) delta, not
the combined HEAD→worktree change.

**How to start:** Diff HEAD-tree → worktree directly for the file (or combine index + worktree deltas)
rather than picking one status delta.

**Depends on:** VCS read foundation. Touches `Core/GitProvider.swift`.

**Priority:** P3 (partial-staging is uncommon in the workroom flow; content still shown, just one side).

## jj file list + diffstat can skew across two reads (macapp) — VCS-foundation eng-review

**What:** `WorkroomStatusResolver.resolveJJ` reads the working-copy file list via native
`workingStatus` and then the ±line counts via a separate `jj diff --stat --ignore-working-copy`. An
on-disk edit (or a concurrent snapshot) between the two gives files from one `@` and counts from
another.

**How to start:** Return the diffstat from the same native snapshot (add insertions/deletions to
`working_status` in `jj_backend.rs`) so the file list and counts come from one read.

**Depends on:** VCS read foundation. Touches `jj_backend.rs`, `WorkroomStatusResolver.swift`.

**Priority:** P3 (brief count/file skew on a mid-refresh edit; self-heals next refresh).

## The jj snapshot ignores the user's real jj/git config (macapp) — VCS-foundation eng-review

**What:** `snapshot_working_copy` builds its settings from jj's **built-in defaults only** —
`UserSettings::from_config(StackedConfig::with_defaults())` (`jj_backend.rs:380`) — and jj-lib derives
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

**How to start:** load the real config stack (user + repo) into `UserSettings` the way the jj CLI
does, instead of `with_defaults()`, and chain a custom `core.excludesFile` in `base_ignores`. Test on
throwaway repos only — this is the lock-taking, `@`-rewriting path.

**Depends on:** the base_ignores fix (shipped). Touches `jj_backend.rs`.

**Priority:** P3 for correctness (only bites non-default configs), but the fsmonitor half is a real
perf item on large repos.

## Unify `workingStatus` onto the `VCSProviding` protocol (macapp) — VCS-foundation follow-up

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

## VCS write actions — Phase 2 (macapp) — roadmap pointer

**What:** The next VCS phase: turn the read-only foundation into a full in-app VCS UI. Write methods
behind `VCSProviding` — commit/amend, push/pull/fetch, branch (git) / bookmark (jj) management — then
the deep jj ops (undo/op-log, split, absorb, evolog, interdiff). A `CLIVCSProvider` fallback is
introduced here for ops the libraries don't expose ergonomically (each with tests), NOT as a parallel
read path.

**Why:** This is a roadmap phase, not a tactical follow-up — it's tracked in full in the issue #59
plan (Phase 2 section) + the `vcs-foundation-rust-core` design notes. This entry is only a pointer so
Phase 2 is discoverable from `TODOS.md`; the authoritative scope + sequencing live in the plan.

**How to start:** Read the plan's "Phase 2 — VCS write actions" section and issue #59. The read
foundation (this file's other VCS entries) is the prerequisite; land the deferred read follow-ups
first where they'd otherwise bite the write UI — of the three that gated this, jj **rename detection**
and **conflict status** have now shipped, leaving the **error taxonomy** entry below.

**Depends on:** the VCS read foundation (shipped, Phase 1). Spans `vcs/` (Rust), `WrVcs` UniFFI,
`Core/VCSProviding.swift` + both providers, and new write-flow UI.

**Priority:** P2 (the product direction; large, sequenced after the read follow-ups — see the plan for the real breakdown).

## Background fetch so push state isn't stale (macapp) — unpushed-badge follow-up

**What:** A periodic / on-focus `git fetch` (and `jj git fetch`) so remote-tracking refs — and
therefore the History pane's unpushed badge — reflect the server rather than the last manual fetch.

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

**Depends on:** the unpushed badge (shipped). Likely wants a `Defaults` key + Settings row.

**Priority:** P3 (the badge is useful without it; multi-machine users feel this first).

## Collapse the terminal tab toolbar when the strip is cramped (macapp) — #129 follow-up

**What:** Below a strip width of roughly 220pt, collapse `TerminalTabStrip`'s trailing per-tab toolbar
into a single `⋯` overflow `Menu` instead of 3-5 separate icon buttons.

**Why:** A workroom-split member can be dragged to 120pt wide (`TerminalSessions.minPaneSize = 120`,
clamped through `PaneTreeLayout.clampRatio`). At that width the toolbar is ~61pt — three times the
pinned "+" — so it, not the "+", is what leaves the chips with a sliver. #129 shipped the always-visible
"+" and explicitly **accepted** the cramped-pane sliver; this is the change that actually reclaims the
space. Split out of #129 so a two-symptom layout fix didn't have to carry native-menu semantics.

**Current state:** #129 shipped the adaptive "+" and the trailing fade. The toolbar always renders
expanded. `TabStripMetrics`/`TabStripOverflow` (in `Views/TabReorderMath.swift`) are the shared home for
the breakpoint and the predicate.

**How to start (two verified prerequisites, both found the hard way in review):**
- `TabToolbarButton` (`Views/TabToolbarButton.swift:8`) is a concrete `View`, **not** a `ButtonStyle` or
  label style — a `Menu` can't wear it as-is. Extract the glyph + hover-well into a small shared label
  first, used by both the button and the menu trigger.
- A SwiftUI `Menu` on macOS becomes **native menu infrastructure**, so identifiers on inner `Button`s do
  not reliably surface as `app.buttons["tab.toolbar.splitRight"]`. Assert collapsed actions via
  `app.menuItems` by title. Existing `TabActionsUITests` assertions query real buttons and only run at
  normal width, so they stay valid.
- Add `collapsesToolbar(stripWidth:)` to `TabStripOverflow` as a **pure width breakpoint**. Keyed on the
  strip's own width (not on the width of the thing being collapsed), it composes with the existing
  pinning predicate as a DAG with no feedback edge: `stripWidth → collapse → toolbarWidth → available →
  pinsControls`. Do not make it depend on the expanded toolbar's measured width, or it will oscillate.
- The two segmented switches (diff view mode, markdown source/preview) become `Picker`s in the menu.
- Reaching a cramped strip in XCUITest needs a divider drag (flaky); prefer unit-testing the breakpoint
  and verifying the rendering by hand.

**Depends on:** #129 (shipped — owns the shared metrics type and the pinned "+").

**Priority:** P3 (only bites at the divider's minimum width, where the strip is already marginal).

## Scroll a selected tab into view in both tab bars (macapp) — #129 follow-up

**What:** Add a `ScrollViewReader` to `TerminalTabStrip` and `WorkroomTabBar` so (a) a chip selected by
⌘1-9, ⌥⌘1-9 or from the sidebar is scrolled into view, and (b) a chip drag near either edge auto-scrolls
the run.

**Why:** Neither bar has one. Selecting a tab that's scrolled out of view swaps the pane content with no
visible feedback — the strip looks unchanged, so it reads as "the shortcut did nothing". #129 makes this
more noticeable, not less: overflow is now a deliberately designed state, so these bars get scrolled
more. Every other scrolling list in the app reveals its selection.

**How to start:** both entry points are already located. ⌘1-9 is handled by the `AppDelegate` `NSEvent`
monitor (see `macapp/CLAUDE.md`), and ⌥⌘1-9 routes through `AppStore.orderedWorkroomTargets` indexing
(`Core/AppStore.swift:783-791`) — each just needs to publish a scroll target the strip's
`ScrollViewReader` can act on. The two halves are separable: scroll-on-select is cheap; drag
auto-scrolling interacts with `TabReorder`'s translation math and `clampReorder`, so land it separately.

**Depends on:** nothing (independent of #129, though cleaner after its restructure).

**Priority:** P3.

## Cap `WorkroomTabChip`'s title width (macapp) — #129 follow-up

**What:** Cap the workroom chip's title width the way terminal chips already are
(`TerminalTabChip.maxTitleWidth = 180`, `Views/TerminalTabStrip.swift`), with the same truncation +
full-title tooltip treatment.

**Why:** `WorkroomTabChip` has **no** cap at all, so a single long workroom name produces a chip wider
than the window and monopolises the title bar. Terminal tabs got this treatment in `c6a88a75` ("cap
terminal tab titles with truncation + full-title tooltip"); the workroom bar never did.

**Current state:** unblocked. This was briefly load-bearing: an earlier #129 test plan forced tab-bar
overflow with a ~200-character fixture workroom name, which only works *because* the cap is missing —
adding it would have turned that test into one that passes while asserting nothing. The shipped fixture
seeds N workroom targets instead (`-WorkroomUITestWorkroomCount`), so nothing depends on the quirk now.

**How to start:** mirror `TerminalTabChip`'s title `frame(maxWidth:)` + `.help(fullTitle)` in
`WorkroomTabChip`. Note it shifts measured chip widths, which the #129 overflow predicate reads, so
re-check the tab-bar overflow UI test after.

**Depends on:** #129 (shipped) — only to avoid conflicting edits in `WorkroomTabBar.swift`.

**Priority:** P3 (generated workroom names are short adjective-noun pairs; this bites on renamed or long
project-derived names).
