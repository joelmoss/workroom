# Review: SwiftUI/AppKit view layer and DesignSystem

Status: research. Evidence for the [cleanup plan](../architecture-cleanup-2026-11.md), measured at
`65f01f1fa`; its paths and counts are not updated as the plan is built.

Scope: `macapp/WorkroomApp/Views/` (97 files, excluding PaneTreeView, TerminalTabStrip, WorkroomSplitView, WorkroomTabBar) and `macapp/Packages/DesignSystem`. All counts below are from grep over `macapp/WorkroomApp/Views` unless stated. Nothing was built or run.

## 1. Top complaints (ranked)

### 1. `DesignSystem` is a theme-colour package, not a design system; spacing, radius, type and component styles are hand-typed everywhere
- Evidence: the package is 2 files, 704 lines (`ThemeCatalog.swift` 289, `ThemeTokens.swift` 415). It holds only palette/syntax/status colours (`ThemeTokens`, `ThemeFamily`, `ThemeCatalog`). It has no spacing, radius, font-role, row or sheet primitives. Only 11 of 97 Views files `import DesignSystem`; colour use goes through `ThemeService.shared.tokens` instead (see #2).
- Literal counts in Views: 267 `.padding(...)` calls with numbers, 146 `.frame(...)` with numbers, 103 `cornerRadius:` literals, 97 `.font(.system(size:` calls out of 331 `.font(` calls. The repeats are telling: `RoundedRectangle(cornerRadius: 6` x41, `: 5` x17, `: 8` x15, `: 12` x16; `.padding(.horizontal, 8)` x26, `.padding(.vertical, 6)` x21.
- Several files grew private metrics enums instead: `WorkroomPaneMetrics` (WorkroomSplitView:8), `PaneTitleBarMetrics` (PaneTitleBar:5), `TabStripMetrics` (TabReorderMath:150), `TerminalPanelMetrics` (TerminalContainerView:7), `VCSToolbarMetrics` (VCSToolbar:11). Each is a local answer to a missing shared one.
- Colour is mostly tokenised (367 `tokens.` uses in 67 files). Raw system colours remain in about 10 places: `PullRequestPanel.swift:396-399` (white/green merge button), `HistoryPanel.swift:314`, `ChangesetDetailView.swift:195` (`.blue`), `SettingsView.swift:202,215` (`Color(white: 0.25)`), `DeleteProjectSheet.swift:222` (`.tint(.red)`), `SwitcherRailView.swift:256`, `DialogOverlay.swift:47`.
- Cost: a change such as "tighten the corner radius of inline panels" or "one more type step" is a 40-file edit. Nobody can own "look and feel" separately from features. `DESIGN.md` describes a web "Broadcast Index" brand (yellow/cyan, Barlow); it says nothing about the Mac app's spacing or type, so there is no written contract for contributors to follow.
- Direction: grow DesignSystem into the shared UI package. Add `Spacing`/`Radius`/`FontRole` constants and the shared row, notice, sheet-header, empty-state and toolbar-button styles (see #4). Keep `ThemeTokens` as the colour layer. DesignSystem has no dependency on the app, so ADR 0020's layering holds. Add a short "app design tokens" section to `docs/macapp/ui.md`.
- Size: M for the package and primitives, then a long mechanical migration (S per file, 60+ files). Test churn: low; the package gets its own tests via `make app-package-test`.

### 2. Views read a global singleton for colours: `ThemeService.shared` x170 in 63 files, plus `themeTick` workarounds
- Evidence: `grep -rn 'ThemeService.shared' Views` gives 170 hits in 63 files (5 in Core). Examples: `ErrorSheet.swift:41`, `VCSFailureSheet.swift:62`, `DeleteProjectSheet.swift:134`, `CommitSheet.swift:216`, `DialogOverlay.swift:38` (`private let theme = ThemeService.shared`).
- `ThemeService` is already `@MainActor @Observable` (`Core/ThemeService.swift:7`), so a body that reads `tokens` tracks changes. Yet five views still keep a `@State themeTick` bumped from `NotificationCenter` `.themeDidChange`: `ActivityBar.swift:18,62`, `QuickTerminalContent.swift:11,28`, `SettingsView.swift:38`, `VCSToolbar.swift` (3 hits), `WindowFooter.swift:11,40`. `PaneTreeView.swift:776` documents that plain reads are enough. Candidate: the ticks are leftovers (needs a behavioural check, e.g. AppKit-hosted subtrees may rely on them).
- Cost: no view can be rendered with a different theme, previewed, or snapshot-tested in isolation. There are 0 `#Preview` blocks in Views (`grep -rl '#Preview' Views` is empty). Every change to the theme service is a 63-file blast radius. A contributor cannot see their view without launching the whole app.
- Direction: inject `ThemeTokens` once through a SwiftUI `EnvironmentValues` key (`@Environment(\.themeTokens)`), set at each window root, hosting root and AppKit bridge. Views stop naming `ThemeService`. Then add `#Preview` to the leaf views.
- Size: M (63 files, mechanical). Test churn: low; tests that construct views with the singleton keep working during the migration if the environment key defaults to `ThemeService.shared.tokens`.

### 3. Views take the whole `AppStore` (about 190 distinct members used) instead of narrow inputs; `AppStore` is 9.2k lines
- Evidence: 44 of 97 Views files mention `AppStore`; 36 hold it as a stored/env property (`@EnvironmentObject var store: AppStore`: HistoryPanel:33, TerminalStatusBar:22, ChangesetDetailView:24, ToastStack:13; `let store: AppStore`: DetachedPaneView:25). Views touch 190 distinct `store.` members. Heaviest: RootView 110 `store.` references, ProjectSidebar 57, ChangesPanel 46, WorkroomContextMenu 22, CreationPane 21. `AppStore.swift` plus its 10 `+` extensions total 9,210 lines (`wc -l Core/AppStore*.swift`).
- The good counter-examples show the way: `BoxdSetupSheet` (`setup`, `onCreate`, `onCancel`), `CodingAgentBannerViewModel`, `CreationPanePresentation`, `PaneToolbarPresentation`, `AddProjectSheetModel`, `DeleteProjectSheetModel`, `WorkroomLabelSheetModel` are pure inputs/presenters with their own tests.
- Cost: two people working on the sidebar and on the inspector both edit and recompile `AppStore`; any new feature adds a property to it and widens every view's dependency. A view's tests need a full store (`ViewVCSSeamTests`, `SidebarBenchmarkTests`). Hand-held `@EnvironmentObject` also re-evaluates bodies more broadly than needed (`AppStore` is both `ObservableObject` and `@Observable`, `AppStore.swift:15-21`, a transitional dual state).
- Direction: for each context, a small read model plus an action struct handed to the view (`ProjectSidebar(rows:, actions:)`). `ModalState` (`Core/ModalState.swift`) is the right precedent: modal flags and `Pending*` values already live outside AppStore proper. Start with the leaves that already have a presenter (ToastStack, HistoryPanel, TerminalStatusBar, ChangesetDetailView, DetachedPaneView).
- Size: L across the app, S per leaf view. Test churn: moderate; each migrated view gets cheaper tests.

### 4. The same sub-views are copy-pasted instead of shared (empty/error states, warning headers, notices)
Sites, all verified:
- Empty/error "message" view, byte-for-byte: `DiffViewer.swift:1048-1060` (+ `centered` at 1062), `PlainFileViewer.swift:295-307` (+ `centered` at 309), `ChangesetDetailView.swift:438-446` (same VStack, without `centered`). Two more variants: `placeholder(_:systemImage:)` at `FilesPanel.swift:91` and `HistoryPanel.swift:188`. Callers pass `exclamationmark.triangle` for failures (`DiffViewer:310`, `PlainFileViewer:242`, `ChangesetDetailView:122`, `FilesPanel:30`, `HistoryPanel:62`).
- Warning-glyph header, 30pt triangle + `tokens.warning` + headline: `ErrorSheet.swift:36-41`, `VCSFailureSheet.swift:58-62`, `DeleteProjectSheet.swift:129-134`. A smaller inline notice with the same glyph is repeated in `CommitSheet.swift:212,585`, `CreationPane.swift:347`, `ChangesPanel.swift:325`, `ProjectSidebar.swift:436,513`, `PullRequestPanel.swift:86`, `TerminalStatusBar.swift:211`, `TerminalCodingAgentBanner.swift:60`, `ToastStack.swift:131`, `WorkroomLabelSheet.swift:78`, `ProjectsSettingsPane.swift:162,200`, `RemoteSetupSheet.swift:124`. That is 24 `exclamationmark.triangle` sites in 20 files.
- Sheet chrome (Cancel/Default action footer): 11 files each declare `keyboardShortcut(.cancelAction)` once (AddProjectSheet, HostOptionsPanel, NewWorkroomDialog, CommitSheet, DeleteProjectSheet, DialogOverlay, ErrorSheet, OpenWorkroomDialog, RemoteSetupSheet, VCSFailureSheet, WorkroomLabelSheet) and 11 declare `.defaultAction`, each with its own padding and Divider.
- Already shared (keep): `RemoteSetupSheet` hosts `BoxdSetupSheet`, `ExeDevSetupSheet` and `SSHHostSetupSheet`; `ScriptBox` is reused by `ErrorSheet` and others.
- Cost: a copy tweak or an accessibility fix lands in 3-20 files and drifts. Example already visible: `ChangesetDetailView.message` lacks the `.padding(24)` the other two have.
- Direction: move `MessageState`, `WarningHeader`, `Notice`, `SheetFooter` into DesignSystem (#1).
- Size: S-M. Test churn: none expected (UI identifiers stay).

### 5. Workflow state machines and async orchestration live inside view structs
- `DiffViewer.swift` (1,103 lines, 16 `@State`): a load pipeline (`FetchKey`, `HighlightKey`, `loadToken`, `loadedKey`, `activeFetchKey`, `activeHighlightKey`, `load` at 385, `applyHighlight` at 434, `Task.detached` at 473/491), a find index, side-by-side row building, and emphasis computation. 40 funcs in one `View`. The static helpers (`shouldLoad` 287, `rows(in:forHunk:)` 668, `findSource` 680, `hasDuplicateIDs` 718, `emphasizedPlain` 999) are only there so tests can reach them (see `DiffViewerLoadGuardTests`, `DiffViewerStaleLoadTests`, `DiffViewerLazyRenderingTests`, `DiffViewerFindTests`, `DiffViewerSideBySideRowsTests`). The comment at 94-100 documents a stale-load race fixed with a hand-rolled generation token.
- Same pattern again, with its own `LoadState` enum: `PlainFileViewer.swift:55,78` (`loadToken`, `LoadState` loading/text/empty/binary/tooLarge/failed) vs `DiffViewer.swift:157` (same cases plus `loaded`) vs `ChangesetDetailView.swift:74`. Three views re-implement "load keyed content, discard stale result, classify binary/empty/too large".
- `CommitSheet.swift:406-500`: `phase` (editing, committing, failed, outcomeUnknown, landedThenFailed, confirmingStagedLoss), `preflightState`, `prefill`, `commitChecking`, `commit(mode:)`, with long guard comments about concurrent-commit races (451-470). That is a commit workflow state machine whose correctness comments are the only spec.
- Settings reaches the CLI directly: `SettingsView.swift:423,434` call `WorkroomCLI.shared.list` / `setGlobalBaseBranch`, then write `ProjectStore.shared.globalBaseBranch` (436). `AddProjectSheet.swift:37` calls `FileManager` for path validation.
- Also: `HostOptionsFields.swift:15` (`HostOptionsCatalog: ObservableObject`, data loading), `Avatar.swift:131` (`AvatarImageLoader`, URLSession plus cache), `SwitcherRailView.swift:157` (`SwitcherRailModel`) are services declared in view files.
- Production views branch on test fixtures: `DiffViewer.swift:392,455,487`, `CommitSheet.swift:413`, `PlainFileViewer`, `ChangesetDetailView`, `PaneTreeView`, `TerminalTabStrip`, `WorkroomTabBar` (`AppEnvironment.current.isFixture` / `UITestFixture`; 8 files). The fixture should be swapped at the provider seam (as `FixtureVCSWriter` is) instead of inside views.
- Cost: this logic is testable only through static-func shims, cannot be reviewed apart from layout, and the race fixes are easy to regress in a view-only edit.
- Direction: `DiffLoader`/`FileContentLoader` (`@Observable`, in Core or a VCS-facing package) own keys, staleness and classification and emit one `LoadState<Content>`. `CommitFlow` owns `phase`. Views render. Fixtures are injected as loader implementations.
- Size: M-L (DiffViewer, CommitSheet, PlainFileViewer are three separate pieces). Test churn: moderate; existing static-func tests move onto the loaders, which is a net simplification.

### 6. 97 views in one flat folder; contexts are invisible and `Core/` is a flat 172 files
- Evidence: `ls Views | wc -l` = 97 with no subfolders. `CONTEXT.md` defines six contexts, none appears in the tree. Sidebar (ProjectSidebar, SidebarCard, SidebarColumn, EdgeRevealSidebar, RowHighlight), inspector (ChangesPanel `RightInspector`, InspectorColumn, InspectorSplitView, InspectorResizeHandle, FilesPanel, HistoryPanel, PullRequestPanel, DetailsPanel), creation (CreationPane, CreationPanePresentation, NewWorkroomDialog), remote setup (BoxdSetupSheet, ExeDevSetupSheet, SSHHostSetupSheet, RemoteSetupSheet, HostOptions*), VCS (CommitSheet, DiffViewer, ChangesetDetailView, VCSToolbar, VCSFailureSheet, VCSStatusBadge), terminal (TerminalContainerView, TerminalSearchBar, TerminalStatusBar, TerminalCodingAgentBanner and the four excluded files) and settings (SettingsView, ProjectsSettingsPane, ThemePicker, ShortcutRecorder) are all interleaved by alphabet. `docs/macapp/ui.md` still describes the folder as "hand-rolled sidebar | detail | inspector split ... plus the terminal detail".
- Several files are mis-named for what they hold: `ChangesPanel.swift` defines `RightInspector` (line 14), `InspectorHeaderButton` and `InspectorMenuButtonStyle` (659-711, shared) and `ChangesPanel` (732). `TabReorderMath.swift` holds five namespaces (`TabReorder`, `TabReorderDrag`, `TabStripMetrics`, `TabStripOverflow`, `TabStripSplitRun`). `SettingsView.swift` holds ten private pane structs; `ProjectSidebar.swift` has 15 private row-button structs in its tail (856-1208).
- Cost: finding the owner of a screen requires a repo-wide grep; two contributors on e.g. the inspector and the sidebar share a folder and merge conflicts concentrate in the 1k-line files (ProjectSidebar 1.2k, DiffViewer 1.1k, SettingsView 876, ChangesPanel 860, RootView 840).
- Direction: see section 3. Folders first (zero-risk move; xcodegen globs), packages later.
- Size: S for folders (moves only, plus `make app-generate`). Test churn: none.

### 7. Every view that shows modal state reads a pile of independent optionals on the store
- Evidence: `RootView.swift` has about 30 `store.pending*/activePicker/show*` references, 8 `.sheet` modifiers (206, 229, 317, 336, 356, 363, 369, 434, 445) and a bridge `rootModals`. `hasModalPresentation` is read from 5 files, 21 times in `RootView`. `ModalState.hasModalPresentation` (`Core/ModalState.swift:209-220+`) is a hand-maintained OR of 10+ optionals; adding a modal means remembering to add it there as well as in RootView. `docs/macapp/ui.md:30` records an Escape bug (#451) for sheets that were missed.
- Direction: one `enum ActiveModal` (or `Modal` stack) with a single `.sheet(item:)` presenter; `hasModalPresentation` becomes `activeModal != nil`.
- Cost today: each new dialog edits ModalState (state), AppStore (setter), RootView (presenter), and the key-monitor guard.
- Size: M. Test churn: moderate (ModalState tests).

### 8. Tests reach views through statics because the views are not separable; `Views/` is not a testable module
- Evidence: 253 files in `WorkroomAppTests`; of those only about 25 relate to view code, and they test statics (`DiffViewer.shouldLoad`, `PRNumberBadge.trafficColor`, `RootView.paneSpace`) or presentation enums. No snapshot or preview coverage; 216 `accessibilityIdentifier` uses are the only seam for UI tests, which the owner runs on request only because they take over the GUI.
- Cost: view regressions are caught only by UI tests nobody can run in CI or in parallel with another worker's GUI session (gui lock in `macapp/AGENTS.md`).
- Direction: `#Preview` on every leaf view with canned model values (needs #2 and #3). Optionally add a snapshot test target on DesignSystem primitives.
- Size: M, incremental.

### 9. Observation is a mixture of `ObservableObject`, `@Observable`, `@Default`, notifications
- Evidence: `AppStore` is both (`AppStore.swift:15-21`; comment says `ObservableObject` stays only for `@StateObject` at the window root). In Views: `ObservableObject` classes `HostOptionsCatalog`, `LogTextController`, `SwitcherRailModel`; `@Observable` in `TerminalTabStrip.swift:802` and `ThemeService`. `@Default` (the Defaults package) is read directly in 56 places in Views, which makes each view a settings consumer (`SettingsView:538`, `RootView:24`, `TitlebarBars:142`).
- Cost: contributors must know three observation systems; a refactor to narrow inputs (#3) needs the model to be consistently `@Observable`.
- Direction: finish the migration (store to `@Observable` + `@State`/`@Environment`) and read preferences through a small settings model instead of per-view `@Default`.
- Size: M. Churn: low-moderate.

## 2. Dead code and duplication

Dead code: none found. Check run: for every top-level `struct|class|enum` declared in `Views/*.swift`, `grep -rw <Name>` over `WorkroomApp` outside the declaring file. Every type has at least one reference elsewhere; the loop printed nothing. This is a candidate-grep result only (no periphery run) and does not cover private members or unused methods inside types.

Leftovers that look removable but need a behavioural check (not proven dead):
- `themeTick` + `.themeDidChange` in `ActivityBar.swift:18,62`, `QuickTerminalContent.swift:11,28`, `SettingsView.swift:38`, `VCSToolbar.swift`, `WindowFooter.swift:11,40`, since `ThemeService` is `@Observable`. Candidate (grep): `grep -rn themeTick Views`.
- Stale doc comment in `DialogOverlay.swift:5-33`: the `DialogOverlay` doc paragraph sits above `DialogOverlayStyle`'s doc, so the struct's own docs are merged into the style enum's. Minor.

Duplication (sites with lines):
- empty/error message view: `DiffViewer.swift:1048-1066`, `PlainFileViewer.swift:295-312`, `ChangesetDetailView.swift:438-447`, `FilesPanel.swift:91`, `HistoryPanel.swift:188`.
- warning header: `ErrorSheet.swift:36-41`, `VCSFailureSheet.swift:58-62`, `DeleteProjectSheet.swift:129-134`.
- `LoadState` enums and stale-guard pattern: `DiffViewer.swift:157`, `PlainFileViewer.swift:78`, `ChangesetDetailView.swift:74`.
- Sheet footer buttons: 11 files listed in #4.
- Row styles: 12 `*Row` structs (ChangedFileRow, CommitFileRow, HistoryRow, NotificationRow, WaitingRow (MenuBar), OpenTargetRow, PickerRow, CreationStepRow, ShortcutRow, FamilyRow, CodingAgentUsageRow, plus sidebar rows) each define their own hover highlight; `RowHighlight.swift` and `ProjectSidebar.rowHighlight/terminalHighlight` (787-815) exist but are not the shared primitive. Needs a closer look before claiming exact overlap.

## 3. Proposed target structure

Folders first (inside the app target, no behaviour change), mapped to `CONTEXT.md`:

```
Views/
  Shell/        RootView, TitlebarBars, WindowFooter, ToastStack, DialogOverlay, Onboarding, WhatsNew
  Sidebar/      ProjectSidebar (+ split rows), SidebarCard/Column, EdgeRevealSidebar, SwitcherRail*, ActivityBar
  Workroom/     NewWorkroomDialog, OpenWorkroomDialog, Creation*, WorkroomContextMenu, WorkroomLabelSheet, Delete*Sheet
  Inspector/    RightInspector(rename from ChangesPanel), InspectorColumn/SplitView, FilesPanel, HistoryPanel, PullRequestPanel, DetailsPanel
  VersionControl/ CommitSheet, DiffViewer, ChangesetDetailView, VCS*, CodeTextView, PlainFileViewer
  Terminal/     (existing owner's files) + TerminalSearchBar, TerminalStatusBar, TerminalCodingAgentBanner, CodingAgentUsage*
  RemoteHosts/  RemoteSetupSheet, Boxd/ExeDev/SSHHost setup, HostOptions*
  Settings/     SettingsView (split per pane), ProjectsSettingsPane, ThemePicker, ShortcutRecorder
```

Then packages, upward-layering per ADR 0020:
- `DesignSystem` (exists): ThemeTokens + Spacing/Radius/FontRole + shared primitives (MessageState, Notice, SheetChrome, RowButtonStyle, toolbar button styles). Depends on nothing in the app.
- `WorkroomViews` (optional later): leaf views taking value inputs plus `Actions` structs, each with `#Preview`. Depends on DesignSystem, WorkroomDomain, WorkroomVCS value types.
- App target keeps composition: RootView, window/AppKit glue, AppStore adapters that build the inputs. Dependency direction: app -> WorkroomViews -> DesignSystem/Domain; never the reverse.
- Loaders/flows (`DiffLoader`, `CommitFlow`, `FileContentLoader`, base-branch setting model) live in Core (or WorkroomVCS) so views never call `WorkroomCLI.shared`.

Ownership split that this enables: someone owns DesignSystem; the sidebar, inspector, VCS dialogs and settings can then be developed in parallel without touching AppStore or each other's files.

## 4. What is good (keep)
- Presenter/model-enum pattern with unit tests: `CreationPanePresentation`, `PaneToolbarPresentation`, `AddProjectSheetModel`, `DeleteProjectSheetModel`, `CodingAgentBannerViewModel`, `WorkroomLabelSheetModel`, `VCSSyncPresenter`.
- `RemoteSetupSheet` as the one shared frame for the three setup sheets; `BoxdSetupSheet` takes only `setup` and two closures.
- Colour discipline: 367 `tokens.` uses in 67 files; only about 10 raw system colours.
- `ModalState` extracted from `AppStore`; `AppStore` split into topic extensions.
- Every top-level view type is referenced (no orphan views). Comments record the why of races and layout quirks (they are the main reason the rules in #5 exist).
- 216 accessibility identifiers; `docs/macapp/ui.md` and `AGENTS.md` route contributors to the right references.

## 5. Open questions for the owner
1. Is a separate `WorkroomViews` package wanted, or is folders plus a fuller DesignSystem enough? The package route makes `#Preview` and isolated builds possible but costs access-control churn (`public` on view inputs).
2. `DESIGN.md` is the web brand; should the Mac app's tokens (spacing, radius, type scale) be documented there or in `docs/macapp/ui.md`?
3. Are the `themeTick` observers still needed for AppKit-hosted subtrees (menu bar, settings window themer, titlebar accessory)? I could not prove either way without running the app.
4. Should test-fixture branching move out of views (inject fixture loaders), or is the `AppEnvironment.current.isFixture` switch an intentional trade-off for UI-test speed? No ADR covers it.
5. Does the planned dual `ObservableObject`/`@Observable` `AppStore` have an end date (comment at `AppStore.swift:15`)?
