# TODOs

> Grouped by priority, then by area. Within a group, cheaper/higher-leverage first. Each entry states
> what it is, why, how to start, what it depends on, and its priority. Completed work is summarised in
> **Recently done** at the bottom — including the traps found while doing it, which are the parts worth
> reading before touching the same code. Full write-ups for finished items live in git history.

## P1 — before GA

### Own the GhosttyKit xcframework (macapp) — CMT-2

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

### Terminal *content* accessibility (macapp) — CMT-3

**What:** VoiceOver support for the terminal's *rendered text* on `GhosttySurfaceView` — accessible
value (screen text), selected text, and change notifications — so the terminal content is navigable
with assistive tech.

**Done so far:** the **UI-tree** a11y has landed (commit `f3859f9`) — `PaneTreeView` exposes each
leaf as `terminal.pane` with a label ("Terminal <title>, pane N of M"), a focused/selected trait, and
an adjustable split divider (`pane.grip`). That claim is unqualified: the one caveat raised against it
(the tab strips' glyph buttons reporting `isHittable == false`) was investigated and closed as an
XCUITest artefact — see **Recently done**. What's still missing is the *content* layer: the
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

## P2 — perf, correctness, and the next VCS phase

### VCS write actions — Phase 2 (macapp) — roadmap pointer

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
first where they'd otherwise bite the write UI. All three that gated this — jj **rename detection**,
**conflict status**, and the **error taxonomy** — have now shipped, so nothing in the read layer blocks
Phase 2. What's left of the taxonomy is one-sided (git still flattens to `.io`) and the stale-working-copy
**repair** is itself a write, so it belongs to this phase, not before it.

**Depends on:** the VCS read foundation (shipped, Phase 1). Spans `vcs/` (Rust), `WrVcs` UniFFI,
`Core/VCSProviding.swift` + both providers, and new write-flow UI.

**Priority:** P2 (the product direction; large, sequenced after the read follow-ups — see the plan for the real breakdown).

### `withTimeout` doesn't observe the CALLER's own cancellation (macapp) — VCS-foundation eng-review, /review follow-up

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

## P3 — VCS engine, diffs, and status

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

### Git diff shows one side when a file is both staged and re-modified (macapp) — VCS-foundation eng-review

**What:** `GitProvider` working diff/status use `entry.workingTree ?? entry.index`, so a file that is
staged AND further modified in the worktree renders only the working-tree (index→worktree) delta, not
the combined HEAD→worktree change.

**How to start:** Diff HEAD-tree → worktree directly for the file (or combine index + worktree deltas)
rather than picking one status delta.

**Depends on:** VCS read foundation. Touches `Core/GitProvider.swift`.

**Priority:** P3 (partial-staging is uncommon in the workroom flow; content still shown, just one side).

### The jj snapshot ignores the user's real jj/git config (macapp) — VCS-foundation eng-review

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

**Second site, added later:** the native ± line counts (`changed_files` → `materialize_options()`)
materialize a conflicted file to count its marker lines, so `ui.conflict-marker-style` and
`merge.hunk-level`/`merge.same-change` DO change that number. It reads jj's defaults today, on purpose
and for the same reason as the snapshot; when this entry lands, both call sites want the real settings,
not just the snapshot.

**How to start:** load the real config stack (user + repo) into `UserSettings` the way the jj CLI
does, instead of `with_defaults()`, and chain a custom `core.excludesFile` in `base_ignores`. Test on
throwaway repos only — this is the lock-taking, `@`-rewriting path.

**Depends on:** the base_ignores fix (shipped). Touches `jj_backend.rs` (`snapshot_working_copy` +
`materialize_options`).

**Priority:** P3 for correctness (only bites non-default configs), but the fsmonitor half is a real
perf item on large repos.

### Offer to repair a stale jj working copy from the app (macapp) — error-taxonomy follow-up

**What:** When a workroom reports `.staleWorkingCopy`, offer the repair inline (a button that runs
`jj workspace update-stale`) instead of only naming it in the Changes panel's text.

**Why:** the taxonomy work made the state *visible* and *honest* — the row no longer claims "not a
repository", and the panel says what to run — but the fix is still a manual trip to a terminal. The
state is reachable in ordinary use: workrooms of one project are jj **workspaces** of one repo, so a
`jj rebase`/`jj abandon` in workroom A can rewrite workroom B's `@` and leave B stale until B is
updated. Deliberately not done with the read work: recovering a working copy is a **write**, and every
VCS write belongs to the Phase-2 write-actions chunk (its own confirmation + undo story), not to a
status probe. jj-lib exposes `Workspace::recover`/`RecoverWorkspaceError` for it.

**Depends on:** the shipped `StaleSnapshot` classification (`jj_backend.rs` `snapshot_working_copy`)
and `VCSStatusFailure.staleWorkingCopy`. Relates to "VCS write actions — Phase 2".

**Priority:** P3 (the state is now self-explaining; this saves the trip to a terminal).

### Background fetch so push state isn't stale (macapp) — unpushed-badge follow-up

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

### Stopped run-tab silently closes instead of warning when its command is cleared (macapp) — #127 follow-up

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

## P3 — Tests and tooling

### Deferred UI workflow tests (macapp)

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

**Also: stabilise a known flake (observed 2026-07-25, during #129).**
`TabActionsUITests.testContextMenuSplitRightCreatesTwoPanes` failed once at
`WorkroomAppUITests/TabActionsUITests.swift:62` ("diff tab should open") when run in a batch with two
other classes, then passed in isolation and passed again on a batch re-run — so it's timing, not a
regression. The suspect is visible in the helper: `openDiffPreview` waits **10s** for the Changes row to
exist, then `row.click()`s it and waits only **6s** for the diff tab. Two thin spots in that sequence —
existence is not the same as being hit-testable, so the click can land before the row accepts it and be
swallowed silently; and 6s is the tightest budget in a helper that otherwise allows 10s, which is the
first thing to give under batch load. Fix by waiting for the row to be interactive before clicking (or
retrying the click once) and raising the diff-tab wait to match the 10s used elsewhere. Worth doing
because a flaky UI test erodes trust in the whole suite, and this one gates several toolbar tests.

**Depends on:** the fixture seam + accessibility identifiers already in place
(`macapp/WorkroomApp/Core/UITestFixture.swift`, `Views/ProjectSidebar.swift`,
`Views/TerminalTabStrip.swift`).

**Priority:** P3 (the smoke + opportunistic suites cover the basics; these harden the notification
flows).

## P3 — CLI

### Harden `vcs.Detect` to validate a real repo (CLI) — #103 follow-up

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

## Recently done

Condensed from the long status notes this file used to carry at the top; the full write-ups are in git
history. Kept here for the parts that stay useful: what changed, and the traps found doing it.

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
  commit above its own descendants. `nearest_bookmark` shares that walk, so the sidebar can't name a
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
