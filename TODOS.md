# TODOs

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

## Evaluate libgit2 for git diffs if the diff viewer needs structured features (macapp)

**What:** Reconsider moving git status/diff off the CLI onto `libgit2` *specifically for the planned
in-app diff viewer*, if and only if the viewer needs structured diff features that parsing
`git diff --git` can't cleanly provide (rename-following, intra-line/word diff, binary handling as
data).

**Why:** The eng-review settled the backend as **CLI for both git + jj** with one shared git-format
unified-diff parser fed by `git diff --git` and `jj diff --git` (jj-lib is unstable with no C/FFI, so
jj diffs must be CLI patches regardless; reusing that parser for git keeps a single diff codepath +
the one `StatusCommandRunning` mock seam). `libgit2` would only de-dupe the git half while splitting
the path, so it's not worth it *unless* the viewer's feature depth makes patch-parsing the bottleneck.

**How to start:** Build the viewer on the shared CLI patch parser first. If a feature (e.g. precise
rename-following or word-diff) proves painful to parse, prototype `libgit2`'s diff API for the git
side only and weigh the second codepath against the gain. Verify `libgit2` worktree support first (the
app's core mechanism).

**Depends on:** the in-app diff viewer plan (in progress).

**Priority:** P3 (conditional — only if the viewer's needs outgrow patch-parsing).

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

## Make `add-project --pretend` a real dry-run for the non-create path (CLI) — #103 follow-up

**What:** With #103, `add-project --create --pretend` is a true dry-run (reports `would_create`,
mutates nothing). But `add-project --pretend` WITHOUT `--create` still writes config — today's
pre-existing behaviour, left unchanged by #103 to avoid an unrelated behavior change.

**Why:** Leaves an asymmetry in the `--pretend` contract: one mode honors it, the other ignores it.
Nobody hits it today (the macOS app never sends `--pretend` to `add-project`), but it's inconsistent.
Surfaced by the Codex outside-voice pass during `/plan-eng-review`.

**How to start:** In `cmd/add_project.go`, gate the no-`--create` path's `Config.AddProject` write
behind `!pretend`, emitting a dry-run envelope instead (mirror the `--create` dry-run shape).

**Depends on:** nothing.

**Priority:** P3 (unused flag combination; consistency cleanup).
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

## jj vs git rename detection divergence (macapp) — VCS-foundation eng-review

**What:** `RustJJProvider`/`jj_backend.rs` `changed_files` classifies only Added/Modified/Deleted;
`GitProvider` emits `.renamed`/`.copied` with `oldPath`. For the SAME colocated commit (or working
copy) containing a rename, jj shows delete-old + add-new while git shows one rename row.

**Why:** Cross-backend inconsistency the hybrid architecture is supposed to hide (both should map to
one app model). The `VCSProviderConformanceTests` asserts the two backends produce equal file lists,
but its fixture has no rename — so this divergence passes the guard falsely.

**How to start:** Add rename detection to `changed_files` in `vcs/crates/wr-vcs-core/src/jj_backend.rs`
(jj-lib exposes copy/rename records via the tree `diff_stream`'s copy sources, or a follow-up
`CopiesTreeDiffEntry`). Add a renamed-file case to the conformance fixture to lock parity. Emit
`old_path` so the UI can show `old → new`.

**Depends on:** the VCS read foundation (shipped). Touches `jj_backend.rs`, `wr-vcs-model`, the UniFFI
surface, `RustJJProvider.map`, and `VCSProviderConformanceTests`.

**Priority:** P2 (user-visible wrong file list on renames; a known "later refinement" in the code).

## jj per-file conflict status never reaches the UI (macapp) — VCS-foundation eng-review

**What:** `jj_backend.rs` `working_status` sets the top-level `conflicted` flag from
`wc_commit.has_conflict()`, but `changed_files` maps every present-before/present-after entry to
`.modified` — no per-file `.conflicted` is ever produced. `GitProvider` does emit per-file
`.conflicted`.

**Why:** In a conflicted jj working copy, the Changes list shows conflicted files as plain "modified",
losing the conflict affordance that git repos get — another cross-backend divergence.

**How to start:** In `changed_files` (or a working-copy-specific variant), detect a conflicted tree
value (jj-lib's `MergedTreeValue`/`Conflict`) and map it to `model::ChangeKind::Conflicted`. Add a
conflicted-`@` case to the cargo `working_status` test.

**Depends on:** VCS read foundation. Touches `jj_backend.rs`, cargo tests.

**Priority:** P2 (conflicts are important state; currently silently downgraded for jj).

## Git History branch/tag decoration — `refs: []` (macapp) — VCS-foundation eng-review

**What:** `GitProvider.map` always returns `refs: []` for commits (comment: "branch/tag decoration: a
later increment"), so the git History panel shows no branch/tag chips. jj provides them and the shared
`VCSCommit` model promises them.

**How to start:** Build a `commit-id → [ref names]` map from SwiftGitX branches + tags (mirror
`jj_backend.rs` `bookmark_map`) and populate `VCSCommit.refs` in `GitProvider.map`.

**Depends on:** VCS read foundation. Touches `Core/GitProvider.swift`.

**Priority:** P2 (History UI parity; empty where jj is populated).

## `withTimeout` doesn't bound a wedged synchronous backend read (macapp) — VCS-foundation eng-review

**What:** `Core/Timeout.swift` `withTimeout` delivers `VCSTimeoutError` to `group.next()` promptly, but
`withThrowingTaskGroup` awaits all children at scope exit, and the operation child is suspended on
`await Task.detached { … }.value` — a detached task isn't cancelled by the group and `.value` doesn't
abandon on cancellation. So a truly wedged jj-lib/libgit2 call blocks `withTimeout` for the FULL
backend duration, not `seconds`. The doc's "one wedged repo abandons only its row" contract is false.

**Why:** `WorkroomStatusResolver`/`BranchResolver` rely on this seam to stay responsive when a repo
hangs. In practice these reads finish in ms so it rarely bites, but the guarantee is not real.

**How to start:** Resolve the deadline against the detached task WITHOUT structurally awaiting it — e.g.
a `withCheckedThrowingContinuation` that the timeout can resolve first, leaving the detached task to
finish and drop its result on the floor. Or fix the doc to state the true (weaker) behavior.

**Depends on:** —. Touches `Core/Timeout.swift`.

**Priority:** P2 (robustness; false safety claim, rare trigger).

## Serialize jj working-copy snapshots across the status fan-out (macapp) — VCS-foundation eng-review

**What:** `AppStore+WorkroomStatus.swift` fans out local status at concurrency 5 with no jj
serialization, while `AppStore.swift:~420` comments claim "one jj probe at a time." Each
`working_status` snapshots + can mutate `@`. Colocated workrooms of the same project share the backing
`.git` (packed-refs) — observed live as a `packed-refs.lock could not be obtained` error while
committing during this review.

**Why:** Concurrent snapshot/export can contend on the working-copy lock (per workspace) and on the
shared git packed-refs (across colocated workspaces of one project), causing transient status errors.

**How to start:** Gate `working_status` calls through a per-project (or global-jj) serial queue /
actor, or confirm the fan-out only ever hits distinct non-colocated workspaces. Reconcile the stale
"one probe at a time" comment with reality.

**Depends on:** VCS read foundation. Touches `Core/AppStore+WorkroomStatus.swift`, `Core/AppStore.swift`.

**Priority:** P2 (transient real-world lock errors on colocated repos).

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

## Honor a custom `core.excludesFile` in the jj snapshot base_ignores (macapp) — VCS-foundation eng-review

**What:** The base_ignores fix (b7dd9b7d) chains git's default XDG global excludes
(`~/.config/git/ignore`) + repo `.git/info/exclude`, but does NOT read a custom `core.excludesFile`
set in git config (that needs a git-config parse). A user who points `core.excludesFile` elsewhere
still gets those patterns skipped by the auto-status snapshot.

**How to start:** Read `core.excludesFile` from the repo's git config (via jj-lib's git backend / a
gix-config read) and chain it in `jj_backend.rs::base_ignores` instead of the hardcoded XDG default.

**Depends on:** the base_ignores fix (shipped). Touches `jj_backend.rs`.

**Priority:** P3 (residual of a fixed P1; only affects users with a non-default excludesFile).
