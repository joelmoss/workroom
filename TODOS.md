# TODOs

> Status note (2026-06-09): the **splits** feature (A5) and the **UI-test fixture seam** have
> shipped, and the **terminal notifications** feature (#10) has landed — so its dependent items
> below (auto-emit OSC, notification preferences) are now unblocked. Items are ordered
> roughly by priority: the before-GA work (CMT-2, CMT-3) first, then the P3 niceties.

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

## Live branch-label refresh (macapp)

**What:** Update each sidebar root row's branch/bookmark the moment it changes, rather
than on the throttled app-reactivate refresh.

**Why:** Today the root label resolves on load and refreshes (throttled, ~3s min interval) when the
app regains focus. If you switch branches in the root terminal and stay in the app, the label is
stale until you alt-tab away and back.

**How to start:** Per-project watcher — FSEvents on `<repo>/.git/HEAD` (git) and a `jj op
log` / `.jj/` watch (jj), debounced, re-running `BranchResolver` for that one project and
writing `AppStore.rootRefs[project.id]`. Tie the watchers' lifecycle to the project list.

**Depends on:** the `BranchResolver` + `rootRefs` machinery already in place
(`macapp/WorkroomApp/Core/BranchResolver.swift`, `Core/AppStore.swift`) — there's no file watcher
yet; resolution is only triggered by the throttled focus refresh.

**Priority:** P3 (nicety — the throttled focus refresh covers the common case).

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
- **Per-pane activity border-flash** — workroom panes don't flash on background activity the way
  terminal split panes do (`activityPulse`); workroom activity still surfaces via bar-chip tinting.
- **Queued first-responder stale-state recheck** (`Views/TerminalContainerView.swift:78`) — `applyFocus`
  enqueues `makeFirstResponder(view)` on `DispatchQueue.main.async` and re-checks only
  `firstResponder !== view`, not a *fresh* focus condition, so a stale enqueue could in theory flip
  focus cross-target. Largely defused already by the `surfaceActive` gate (a non-focused workroom pane
  passes `isFocusedPane=false` → never enqueues); this is the residual race within terminal-pane splits.
  Fix would re-read live focus state inside the async block rather than relying on the captured value.

**Priority:** P3 (polish on a shipped feature).

## Workroom tabs: tab-chip management actions (macapp) — #23 follow-up

**What:** Quick workroom management straight from the tab bar — a `WorkroomTabChip` context menu
("Delete…", and maybe "New Terminal" / "Reveal in Finder"), and optionally a create-workroom
affordance — so common actions don't require reaching for the sidebar.

**Why:** #23 keeps create/add-project/delete in the Projects sidebar. The tab bar sits above the
terminal and the sidebar is a ⌃⌘S toggle away, so the original "never toggle back to manage" motivation
is mostly moot. What remains is a small ergonomic win: right-click a tab to act on that workroom
without hunting for its sidebar row. The add-project importer (`⌘O`) and the delete confirmation are already re-homed
to `RootView` (they present regardless of sidebar visibility), which is the prerequisite for any
in-tab trigger; the run-command config sheet (`ProjectSettingsSheet`) is still sidebar-only.

**How to start:** Add a `.contextMenu` to `WorkroomTabChip` in `Views/WorkroomTabBar.swift`:
"Delete…" → `store.pendingDeletion = …` (reusing RootView's re-homed confirmation dialog), plus
optional "New Terminal" / "Reveal in Finder". A create affordance has no obvious home on the bar today
(the picker and its "+" were removed), so scope it to the context menu first. Guard delete from a tab
carefully — it reaps the workroom's terminals (destructive).

**Depends on:** the #23 tab bar shipping first (done); the importer/delete presenters already re-homed
to `RootView` (done).

**Priority:** P3 (deferred from #23 — infrequent vs the monitoring use-case; the sidebar already
covers management).

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

## Harden `gh` auth detection — robust gate (macapp) — #50 follow-up

**What:** Replace the exit-code-based global GitHub-auth gate with a more robust design — either
parse `gh auth status --json hosts` (always exits 0; classify the active account's `state` in
Swift) or de-gate so the per-workroom PR/CI probes self-classify their own auth failures (they
already return `.absent` on `!r.ok`) and the global `githubCLIStatus` becomes advisory.

**Current state:** #50 was fixed by adding `--active` to `gh auth status`
(`Core/WorkroomStatusResolver.swift` `resolveGitHubCLI`). That is correct for current gh but leans
on `gh`'s exit-code behavior and carries a **gh ≥ 2.57.0** floor (where `--active` was added).

**Why:** removes the dependency on `gh`'s exit-code quirk and the version floor, and closes the
residual multi-host case the `--active` fix leaves open — the global probe runs host-agnostic in
`NSTemporaryDirectory()`, so a broken *active* account on an unrelated host (e.g. a GHE server the
user still has configured) still trips a false "not signed in". `--json hosts` lets the check be
host-aware without pinning `--hostname` (which would break GitHub Enterprise users).

**How to start:** prototype `gh auth status --json hosts` parsing in `classifyGitHubCLI` (note the
`--json` field set + `state`/`active` schema also has a gh version floor — confirm it). Or, for the
de-gate route, relax `guard self.githubCLIStatus == .available else { return }`
(`Core/AppStore+WorkroomStatus.swift:74`, `:121`) — but weigh the deliberate "don't spawn a `gh`
per workroom when logged out" optimization it currently buys (`:70-73`), and rework the
`PullRequestPanel` "not signed in" warning, which is driven by the global status.

**Depends on:** nothing — pure follow-up to the #50 `--active` fix.

**Priority:** P3 (the `--active` fix covers the reported bug and current gh; revisit only if
multi-host or old-gh false-negatives get reported).

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

**Current state:** #52 shows reviewers (and the kept `reviewDecision` aggregate) only in the
**expanded** Pull Request inspector panel. The aggregate is the natural feed for a glyph.

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
