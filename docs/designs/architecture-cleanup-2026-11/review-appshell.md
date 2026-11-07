# App shell and state ownership review (macapp)

Status: research. Evidence for the [cleanup plan](../architecture-cleanup-2026-11.md), measured at
`65f01f1fa`; its paths and counts are not updated as the plan is built.

Scope: `Core/AppStore.swift` and its 12 `AppStore+*.swift` extensions, `WorkroomApp.swift`, `Core/WindowRegistry.swift`, `Core/ProjectStore.swift`, `Core/ModalState.swift`, `Core/RunCommandController.swift`, `Core/QuickTerminalController.swift`, `Core/AppEnvironment.swift`, `Core/UITestFixture.swift`, `macapp/project.yml`. Read-only; nothing was built.

## Corrections to the brief's numbers (measured)

- The 9,210 lines are all 13 files together: `AppStore.swift` is 3,822 and the 12 extensions are 5,388 (`wc -l Core/AppStore*.swift`).
- `Core/Services*` does not exist. The only "Services" types are `AppEnvironment.Services` (an enum, `live`/`fixture`, AppEnvironment.swift:18) and `RemoteCreateServices` (AppStore+WorkroomCreation.swift:1024). There is no services container or composition-root object. See complaint 5.
- "53 Core files reference AppStore": almost all of those mentions are in doc comments. If you drop comment lines, only 11 non-AppStore Core files use the type in code: WindowRegistry (18 refs), QuickSwitcher (9), QuickSwitcherController (5), ProgramStatusAlerts (3), and 1–2 each in SwitcherRecency, RoomCommandState, RemoteSetup, QuickTerminalController, DetachedPaneController, WorkroomStatusResolver and FocusedTabSelection. TerminalSessions (31 mentions), ProjectStore (12), SessionSnapshot (9), RemoteStateModel (7) and RunCommandController (3) have zero code references. In Views, 36 of 97 files use it in code (44 if you count comments).

---

## 1. Top complaints (ranked)

### C1. AppStore is the state and flow owner of five bounded contexts. Its extensions are file splits, not boundaries, and the type has grown since the cleanup.

**Claim.** CONTEXT.md makes the App shell "the composition root that wires the other contexts together". That role is fine. But AppStore does more than wire: it stores the state and runs the workflows of Workroom management, Version control, Terminal, Remote hosts and App shell. The extensions were cut by file, and their own headers say the state stayed behind.

**Evidence.**
- The extension headers say so themselves:
  - AppStore+InspectorLayout.swift:1-6: "Moved out of `AppStore.swift` as is. The state it reads and writes stays on `AppStore` … because an extension cannot store".
  - The same "Moved out … as is" wording opens ContentTabs, NavigationHistory, WorkroomLabels and VCSWrites.
  - Each of those files also lists its "Coupling points left on `AppStore`".
- Growth since the cleanup. At `10a188745` (last commit before 2026-10-10), AppStore.swift was 5,767 lines plus 4 extensions of 2,150, for 7,917 in total. Today the total is 9,210. AppStore.swift shrank 34%, but the type's surface grew 16%.
- The type exposes 214 distinct stored or computed properties and 312 non-private funcs across the 13 files (extracted with grep into scratchpad `props.txt` and `funcs.txt`).
- AppStore.swift by section and context (from its MARK lines; line counts approximate):

| Lines | Content | Context |
|---|---|---|
| 1–954 | ~120 stored or proxied properties, all contexts mixed | all |
| 955–1160 | init, `handleTerminalEvent` | Terminal → App shell |
| 1160–1605 | window attach, frames, selection | App shell |
| 1783–2364 | Loading (project list, branch watchers, fixture load) | Workroom mgmt |
| 2365–2929 | Mutations (add/delete project/workroom, teardown, trash) | Workroom mgmt, Remote hosts |
| 2930–3258 | Menu-command convenience, close confirmations | Terminal / App shell |
| 3306–3764 | Notifications, program status alerts | App shell, Terminal |

- The extensions mapped to contexts:

| Context | Extensions |
|---|---|
| Workroom management | WorkroomCreation (1,219), WorkroomLabels (109) |
| Version control | WorkroomStatus (695), VCSWrites (298) |
| Terminal | RunCommand (865), ContentTabs (155), Session (273) |
| Remote hosts | HostLayout (489) |
| App shell | WorkroomSplit (557), WindowMove (440), NavigationHistory (209), InspectorLayout (79) |

- Approximate cross-file call counts. These come from name-based `\bfn\(` matching, so generic names inflate some cells. The shape is what matters: the following are coupled in both directions, i.e. aggregates hiding as extensions:
  - Creation↔core: 37 calls one way, 15 the other.
  - RunCommand↔core: 26 / 27.
  - Split↔core: 23 / 14.
  - WindowMove↔core: 12 / 30.
  - VCSWrites→Status: 19, one way.
  - InspectorLayout, WorkroomLabels, ContentTabs and NavigationHistory are near-leaves.

**Cost.**
- Churn since 2026-10-10:
  - AppStore.swift was touched by 84 of the 478 macapp commits.
  - 131 commits touched some AppStore file.
  - The next most-touched app file is TerminalSessions.swift, with 44.
- Any feature that needs new per-window state has to add a stored property to AppStore.swift, because extensions cannot store. So work on creation, run commands and workroom status all converges on that one file's 950-line property block.
- In practice, two people cannot work on creation and run commands without conflicting in AppStore.swift.

**Direction.** Make each both-ways extension an owned `@MainActor @Observable` type with its own stored state. Candidates, in this order: RunCommand, then VCS status + writes, then Workroom creation/deletion. AppStore keeps window state and the wiring. See section 3.

**Size.** L overall, done as M steps. Test churn is measured under C2.

### C2. Sub-objects were extracted, but callers were never redirected: 53 forwarding proxies keep AppStore as the only door.

**Claim.** ProjectStore, ModalState and RunCommandController exist as real owners. But AppStore re-exposes their fields one by one, so no view or test ever learns those owners exist.

**Evidence.**
- AppStore.swift has 47 `get {` accessors:
  - 14 forward to `projectStore`, e.g. `rootRefs`, `workroomStatuses`, `creationRuns`, `deletingWorkrooms` (lines 324–378, 659–686).
  - 25 forward to `modals` (lines 608–747).
  - 14 forward to `runCommand` (lines 1700–1757).
- The run block's comment (1692–1694) says the members "forward to it, so views and tests read run state through the store as before".
- Views use the proxies, not the owners: `store.hasModalPresentation` 23×, `store.activePicker` 16×, `store.pendingDeletion` 12×. Only 6 references anywhere in Views or WorkroomApp.swift go through `store.terminals.X`, `store.modals.X` or similar directly.

**Cost.**
- Adding one modal or run field takes three edits: the owner, the proxy in AppStore.swift, and the readers.
- The owners can't be handed to a view on their own, because nothing reads them directly.
- Test references to redirect if the proxies go (`grep -rhoE` over WorkroomAppTests):

| Area | Test refs | Test files |
|---|---|---|
| Run state | 52 | 4 |
| Creation | 179 | 7 |
| Workroom status | 111 | 14 |
| Modals and errors | 100 | 20 |

**Direction.**
- Delete the proxies.
- Inject `ModalState`, `RunCommandController` and the shared stores into the environment.
- Change callers to `modals.pendingDeletion`, etc.
- Mechanical work; do one owner per commit.

**Size.** S–M per owner. Test churn as in the table above.

### C3. There is no app-scoped owner, so app-wide behaviour runs by one window's store iterating its siblings, and app-wide state hangs off the per-window type as statics.

**Claim.** Shared *data* lives in ProjectStore. Shared *behaviour* (delete, create, host-layout fan-out, window moves) is done by whichever window's AppStore started it, looping over every other window's AppStore.

**Evidence.**
- `affectedStores` (AppStore.swift:2488–2492) returns `[self] + WindowRegistry.shared.allStores`. It is used at:
  - AppStore.swift:2467 (delete workroom) and 2751 (delete project).
  - AppStore+WorkroomCreation.swift:54, 143, 346, 929.
- `WindowRegistry.shared.allStores` is also read at AppStore+HostLayout.swift:446 and AppStore+WindowMove.swift:100 and 195.
- `stopRunsAcrossWindows` (2508–2517) drives a `DispatchGroup` over sibling stores.
- Eight `static var`s on AppStore hold state for the whole process:
  - AppStore.swift:942 `sweptOrphanedSessions`
  - AppStore.swift:1828 `claimingProvisioned`
  - AppStore+Session.swift:32 `quitStopsRuns`
  - AppStore+WindowMove.swift:78 `refusing`
  - AppStore+WorkroomCreation.swift:191 `announceCreation`
  - AppStore+HostLayout.swift:88 `hostLayoutStore` and :95 `hostSessions`, both `nonisolated(unsafe)`
  - plus the `RemoteCreateServices.live` factory
- ProjectStore (ProjectStore.swift:24–170) is itself a bag spanning four contexts:
  - Workroom management: project list, `globalBaseBranch`, run config revision, deletion tombstones.
  - Version control: VCS and CI status, gh CLI status, commit and write in-flight counts.
  - Creation runs.
  - Remote hosts: remote setup waits.
- The status sweep for that app-wide data is per-window: `statusSweepTask` and `statusResolver` live on AppStore (AppStore.swift:890–891, AppStore+WorkroomStatus.swift:82–130). It runs from whichever window won `claimPublication` (AppStore.swift:1913–1917).
- ADR 0064's "Rejected" paragraph shows the same strain. `allStores` is overloaded: session save, window cycling, the quick switcher and run-command ownership all read it, so the Quick Terminal could not join it.

**Cost.**
- Deleting a workroom touches every window's AppStore through the whole god-object interface.
- A new cross-window rule ("when X happens, every window must Y") becomes another `for store in affectedStores` loop somewhere in AppStore files.
- App-wide flows have no single home, which makes them hard to test without registering windows. In tests, `affectedStores` is just `[self]` (comment at 2486–2487), so the multi-window path goes unexercised.

**Direction.**
- Add one app-scoped `@MainActor` owner for workroom lifecycle, VCS status and run ownership.
- It publishes events like `targetRemoved(sid)` and `paneReplaced(old:new:)`. Each window applies them to its own selection and splits, which inverts the fan-out.
- Move the process statics there.
- Split ProjectStore along context lines (catalog, VCS status, creation runs).

**Size.** L. Test churn is mostly the creation and deletion tests (179 creation refs in 7 files).

### C4. Views take the whole store. No slice, protocol or seam exists, and the Quick Terminal has to build a full AppStore to host one target.

**Claim.** Every view that needs anything from window or app state gets all of it.

**Evidence.**
- 43 `@EnvironmentObject … AppStore` sites, 5 `@ObservedObject`, 1 `@FocusedValue(AppStore.self)`.
- About 199 distinct `store.<member>` names are used from Views and WorkroomApp.swift.
- No `extension AppStore: <Protocol>` exists anywhere: `grep -rnE 'extension AppStore\s*:'` returns nothing.
- QuickTerminalController.swift:313 builds `AppStore(notifications: …)` for its single, project-less target. Per the init comment (AppStore.swift:962–967), that gives it a private, empty `ProjectStore`. It also gets its own `RemoteStateModel`, `HistoryModel`, status resolver and fixture branches, just to host one `TerminalSessions`. The doc comment at 107–113 describes the workaround: "the store's project lookups never see it".
  - Note (2026-11-07): no longer so. Since row 4.9's follow-up the Quick Terminal builds no `AppStore`; a `QuickTerminalHost` hosts its panes with only the owners it uses, and its notification labels read `ProjectStore.shared`. The finding is kept as it was reviewed.

**Cost.**
- A view for, say, the creation pane can't be previewed or tested without a full AppStore.
- Any AppStore rename ripples through 36 view files.
- Two people editing different views both depend on, and edit, the same type.

**Direction.**
- Inject the owned types from C1 and C2 into the environment separately (`@Environment(RunCommands.self)`, etc.). With `@Observable` this costs nothing in re-render scope and narrows it.
- Pull out a "pane host" slice (terminals, notifications, close and focus actions) that the Quick Terminal can build without AppStore.

**Size.** M, incremental per view family. Test churn is low, since most view tests go through the store.

### C5. Dependency injection is ad hoc, with no composition root. `AppEnvironment.Services` is a flag, not a set of services.

**Evidence.** The seam styles in use:
- Five init parameters (AppStore.swift:955–960).
- About 10 settable closure or protocol properties: `trasher`, `systemNotifier`, `isAppActive`, `autoEvenSplits`, `remoteCreateServices`, `closesFinishedCreations`, `creationSuccessHold`, `scheduleRunToastDismiss`, and others.
- 11 `*ForTesting` vars app-wide, 5 of them on AppStore.
- Mutable static seams (`hostLayoutStore` and `hostSessions`, `nonisolated(unsafe)`).
- 41 `static let/var shared` singletons app-wide. AppStore files reach `WindowRegistry.shared` 15×, `RepositoryRouter.shared` 15×, `RemoteHosts.shared` 14× and `HostLayoutOwners.shared` 5×.
- `RemoteCreateServices` is the one closure-bag done right (with `live`), but `plan` and `trustStatus` take `AppStore` as a parameter (AppStore+WorkroomCreation.swift:1025, 1044–1048), which leaks the god object back into the seam.
- TODOS.md "Test a config-only project delete's remote teardown" (P1) asks to "Give `AppStore` a seam for the teardown's `run`". Seams get added one test at a time.

**Cost.**
- Every new test needs a new one-off seam on AppStore.
- Static seams make tests order-dependent and block parallel test execution.
- Nothing lists everything the app reaches outside itself.

**Direction.**
- One `AppServices` struct: cli, VCS writer factory, history resolver, remote-create services, trasher, notifier, host-layout store, host sessions, clock.
- Build it once in `WorkroomApp.init` as `.live`, with `.fixture` under `#if DEBUG`.
- Pass it down. Retire the statics and the `*ForTesting` properties as each owner from C1 is extracted.

**Size.** M. Test churn is moderate: test setup changes, assertions don't.

### C6. ADR 0022 is half built: fixture code still ships in the Release binaries, and 54 fixture branches remain in production code.

**Contradiction?** None. ADR 0022 itself says "The fixture file is to be wrapped in `#if DEBUG`, so a Release build compiles none of it; today it is compiled into Release". Its status line says "accepted, not yet built". This item reports drift from it, nearly four weeks later.

**Evidence.**
- `strings` on the installed binaries:
  - Workroom 2.1.0, Release config: contains `fixture: authentication refused`, a `FixtureVCSWriter` string (UITestFixture.swift:1491).
  - Workroom Nightly 2.2.0-nightly.2226: also contains `workroom-uitest/workrooms/uitest-created`, `$ git worktree add -b workroom/uitest-created`, `Preparing worktree (new branch 'workroom/uitest-created')` and `Installing dependencies…`. These are `ScriptedCreateCLI` strings (UITestFixture.swift:1500–1568).
  - Those strings appear nowhere else in `WorkroomApp/`.
- Of 103 distinct long string literals in UITestFixture.swift, 6 survive in Nightly. So the optimizer strips most of the fixture data, but the fixture collaborators that AppStore's init names (`ScriptedCreateCLI`, `FixtureVCSWriter`) ship.
- UITestFixture.swift has exactly one `#if` (line 42).
- The ADR's other half did land: AppEnvironment has both axes. But the branches it was meant to replace remain:
  - 54 `isFixture` reads across 18 files. 16 are in AppStore.swift, 8 in AppStore+WorkroomStatus.swift, 6 in AppStore+VCSWrites.swift.
  - AppStore's init picks fixture collaborators inline (970–990).
  - `refreshWorkroomStatuses` calls `seedFixtureStatuses()` (AppStore+WorkroomStatus.swift:84–87).
  - The commit path calls `FixtureVCSWriter().commit` (AppStore+VCSWrites.swift:161).

**Cost.**
- Every business flow carries a test branch, and new flows copy the pattern.
- A shipped binary carries test types that a future change could reach.
- The ADR status line is stale.

**Direction.**
- Finish ADR 0022: the fixture becomes `AppServices.fixture` (C5) inside `#if DEBUG`.
- The `isFixture` reads collapse into the choice of services.
- Update the ADR status.

**Size.** M. Test churn is low; the UI tests keep their launch flags.

### C7. `WorkroomApp.swift` is three files in one (1,842 lines)

**Evidence.**
- `AppDelegate` spans 299–955. Its `applicationDidFinishLaunching` runs 398–690, which includes the documented `NSEvent` key monitor (docs/macapp/ui.md:8–25) and 122 comment lines.
- 24 `FocusedValueKey` structs plus `extension FocusedValues` (956–1164).
- `WorkroomCommands` (1165–1842), with 60 `Button(`s.

The monitor and its `assumeIsolated` calls are deliberate and correct (non-isolated monitor closures). This complaint is about organisation only.

**Cost.**
- 49 of the 478 macapp commits since 2026-10-10 touched this file.
- A menu change, a key route and a launch-order change all conflict here.

**Direction.**
- `App/WorkroomApp.swift` (scene).
- `App/AppDelegate.swift` plus `App/KeyEventRouter.swift` (the monitor body).
- `App/FocusedValues.swift`.
- `App/Menus/WorkroomCommands.swift`, split per menu if wanted.

**Size.** S. No test churn.

### C8. Swift 6 posture: the app is strict but its tests aren't, and concurrency idioms are hand-rolled and duplicated

**Evidence.**
- Language modes in `project.yml`:
  - App target: `SWIFT_VERSION: "6.0"` (line 235).
  - WorkroomAppTests (374), workroom-session (395) and WorkroomAppUITests (437): `"5.0"`.
  - All 8 packages: `swift-tools-version: 6.0`.
  - ADR 0020 covers packages only. So the 81,882 lines of hosted tests that drive `@MainActor` AppStore do so without Swift 6 checking (147 of 253 test files say `@MainActor` by hand).
- App-wide counts: `@MainActor` 225, `nonisolated(unsafe)` 46, `@unchecked Sendable` 30, `MainActor.assumeIsolated` 76, `DispatchQueue.main` 56, `NSLock()` 18.
- Hand-rolled locking: `CreationWarningBox` and `CreationLandingBox` (AppStore+WorkroomCreation.swift:1140–1210) are `NSLock` plus `@unchecked Sendable`. Meanwhile `Synchronization.Mutex` is already used in Packages/DesignSystem (ThemeCatalog.swift) and Packages/HostDrivers (SSHHostDriver.swift), and the deployment target is macOS 15.
- Duplication: `onMain` closure, see section 2.
- Mixed observation:
  - 25 `ObservableObject` classes with 127 `@Published`, against 9 `@Observable` classes (AppStore included).
  - AppStore is both, for the documented `@StateObject` reason (AppStore.swift:15–20), so that part is not a defect.
  - But `TerminalSessions`, `RemoteStateModel` and `WindowRegistry` being `ObservableObject` means AppStore subscribes with Combine (`terminals.objectWillChange.sink`, AppStore.swift:996). ADR 0018 relies on publish cadence.

**Cost.**
- A test can touch main-actor state from the wrong context with no compiler error.
- Each new background callback gets another copy of the `onMain` helper.

**Direction.**
- Move WorkroomAppTests to Swift 6 mode (fix whatever it surfaces).
- Replace the lock boxes with `Mutex`.
- One shared `MainQueue.hop` helper.
- Leave the observation mix alone until the C1 extractions, then make each new owner `@Observable`.

**Size.** M for the test-mode move (unknown error count; not measured, because building was out of scope). S for the rest.

### C9. Core/ is a flat folder of 156 files spanning all six contexts

**Evidence.**
- `ls Core | wc -l` gives 158 entries: 156 files plus `Session/` and `SyntaxHighlighting/`.
- Creation types (`CreationRun`, `ContainerCreate`, `DevContainer*`, `RemoteProvisioning`, `BoxdSetup`, `ExeDevSetup`, `SSHHostSetup`) sit beside terminal types (`GhosttySurfaceView`, `TerminalSessions`), VCS types (`VCSWriting`, `GitGraph`, `LibGit2`) and app-shell types (`QuickSwitcher*`, `WindowRegistry`).

**Cost.**
- Nothing tells a contributor which files belong to their context.
- Ownership (CODEOWNERS or review routing) can't be set per context.

**Direction.**
- Folders named after CONTEXT.md's six contexts.
- `createIntermediateGroups: true` in project.yml means a folder move is free for the build.

**Size.** S. No test churn.

---

## 2. Dead code and duplication

**Dead code.** There is very little. I extracted every non-private func and property name from the 13 AppStore files (312 funcs, 214 properties) and counted word matches across `WorkroomApp/` against `WorkroomApp*Tests/`. Only two names occur exactly once in app code, i.e. only at their definition:

- **Candidate (grep): `workroomSplitActive`**, AppStore+WorkroomSplit.swift:57. Defined once in the app; used only in WorkroomSplitTests.swift:88 and :375. Grep: `grep -rn workroomSplitActive WorkroomApp WorkroomAppTests WorkroomAppUITests`.
- **Candidate (grep): `createStep(for:)`**, AppStore+WorkroomCreation.swift:525. Defined once in the app; used only in CreationPanePresentationTests.swift:310–313 and RemoteHostsTests.swift:2375–2378. The real view builds `AppStore.CreateStep(run)` directly (ProjectSidebar.swift:1011). Same grep.

Both are test-only API. Either point the tests at the real path (`resolvedSplitLeaves`, `CreateStep(run)`) or keep them as documented test helpers.

**Duplication.**

- **`onMain` hop closure, defined three times** in AppStore+WorkroomCreation.swift: 731–733, 833–835, 859–861. The body is identical each time: `let onMain: @Sendable (@escaping @MainActor () -> Void) -> Void = { body in DispatchQueue.main.async { MainActor.assumeIsolated(body) } }`. The pattern `DispatchQueue.main.async { MainActor.assumeIsolated` appears 7× in the app.
- **Forwarding proxies, 53 of them** (C2): AppStore.swift 324–378 and 659–686 (projectStore), 608–747 (modals), 1700–1757 (runCommand). Each is a four-line `get`/`set` pair repeating a field of another type.
- **Fixture collaborator selection**, repeated per collaborator in AppStore's init (970–990) and again at call sites: AppStore+VCSWrites.swift:161 and AppStore+WorkroomStatus.swift:84. This is one decision made in several places (C6).
- **Lock-box pattern**: `CreationWarningBox` (1140–1154) and `CreationLandingBox` (1165–1210) each hand-roll NSLock get/set that `Mutex<T>` gives for free.

---

## 3. Proposed target structure

The dependency direction, from top to bottom (each arrow means "depends on"):

```
Views ──► context models (environment-injected, @MainActor @Observable)
            ▲
WindowModel (per window: today's AppStore minus C1's aggregates)
            │ subscribes to events, never iterated by siblings
AppModel (app-scoped, one instance; replaces affectedStores + AppStore statics)
            │
AppServices (.live / #if DEBUG .fixture), built once in WorkroomApp.init
            │
Packages (WorkroomDomain, WorkroomVCS, DaemonConnection, HostDrivers, …)
```

Folders under `WorkroomApp/`, one per CONTEXT.md context (owner in brackets):

- `App/`: `WorkroomApp.swift` (scene only), `AppDelegate.swift`, `KeyEventRouter.swift`, `FocusedValues.swift`, `Menus/`, `AppServices.swift`, `AppModel.swift`. [App shell]
- `AppShell/`: `WindowModel` (renamed AppStore, or AppStore kept), plus window attach/frames, selection, `WindowRegistry`, `NavigationHistory`, inspector layout, workroom splits, `WindowMove`, quick switcher, `NotificationCenterStore`, theme. [App shell]
- `WorkroomManagement/`: `ProjectCatalog` (projects, load, labels, tombstones: today's ProjectStore core plus Loading and WorkroomLabels), `WorkroomLifecycle` (AppStore+WorkroomCreation plus the delete half of "Mutations", `CreationRun`, `RemoteCreateServices`, script trust). App-scoped, because the runs already are (`ProjectStore.creationRuns`). [Workroom mgmt]
- `VersionControl/`: `VCSStatusService` (AppStore+WorkroomStatus plus the ProjectStore status, gh and commit in-flight fields), `VCSWrites`, and the current `VCSWriting`, `GitGraph`, `LibGit2`, … [Version control]
- `Terminal/`: `TerminalSessions`, `RunCommands` (RunCommandController plus AppStore+RunCommand, run ownership from WindowRegistry), content tabs, Ghostty, `Session/`. [Terminal]
- `RemoteHosts/`: `HostLayoutCoordinator` (AppStore+HostLayout plus its statics), provisioning and setup types. [Remote hosts]
- `DaemonConnection/` (app side): `DaemonBootstrap`, `DaemonPortForwarding`, … [Daemon connection]
- `Testing/` under `#if DEBUG`: `UITestFixture` and `AppServices.fixture`.

Rules:
- A context model never imports or holds `WindowModel`.
- Where it needs a window's answer (today `remoteState.describeTarget`, AppStore.swift:1023), it takes a closure or a small protocol, as `RemoteStateModel` already does.
- Cross-window effects travel as events from `AppModel` to each `WindowModel`.

Suggested order (each step is independently shippable):

| # | Step | Size | Test churn |
|---|---|---|---|
| 1 | Folders (C9) and the `WorkroomApp.swift` split (C7) | S | none |
| 2 | Remove the `modals` proxies (C2) | S | 100 refs / 20 files |
| 3 | `AppServices` plus `#if DEBUG` fixture (C5, C6) | M | low |
| 4 | `RunCommands` aggregate (C1) | M | 52 refs / 4 files |
| 5 | `VCSStatusService`, app-scoped (C1, C3) | M | 111 refs / 14 files |
| 6 | `WorkroomLifecycle` plus window events (C1, C3) | L | 179 refs / 7 files |
| 7 | Pane-host slice for the Quick Terminal (C4) | M | — |
| 8 | WorkroomAppTests to Swift 6 mode (C8) | M | unknown |

After step 6, creation, run commands and status each have their own file set and their own stored state, so three people can work on them in parallel.

---

## 4. Things that are good and should be kept

- **Coupling runs Views→AppStore, not Core→AppStore.** TerminalSessions, ProjectStore, RunCommandController, RemoteStateModel and SessionSnapshot have zero code references to AppStore. That makes the C1 extractions feasible.
- **ADR 0021's single typed sink.** `handleTerminalEvent` (AppStore.swift:1052+) switches exhaustively, so a new event can't go unhandled.
- **`RemoteStateModel` is wired after init with closures** (AppStore.swift:1000–1030), so it is testable without AppStore. This is the template for every new owner.
- **`RemoteCreateServices` and its `live` factory**: the right seam shape. Just stop passing AppStore through it.
- **AppEnvironment's two axes and its Release gate on reads** (AppEnvironment.swift:48–57, UITestFixture.swift:41–62). They stop a stray `defaults write` from latching a shipped build into fixture mode.
- The store types are `@MainActor` throughout, and all packages are Swift 6.
- The extension headers honestly list their coupling points. That made this review fast.
- There is little dead code (section 2).
- The cross-window write-release closure that captures `projectStore` strongly (AppStore.swift:1031–1040) is a careful lifetime fix with its reasoning recorded.

---

## 5. Open questions for the owner

1. Were the 53 proxies (C2) meant as a transitional step after the #70, #7 and modal extractions, or are they the intended permanent surface? (No ADR or TODO says either way.)
2. ADR 0022: is the `#if DEBUG` wrap of UITestFixture still planned? Its status line reads "not yet built", though the AppEnvironment half is built.
3. Should WorkroomAppTests move to Swift 6 language mode, and is there a reason it stayed on 5.0 (project.yml:374)?
4. Is it acceptable to move workroom create and delete flows out of the per-window store into an app-scoped owner that windows subscribe to? I found no ADR against it, and ADR 0064's rejection was about registering the Quick Terminal's store, not about this.
5. ADR 0020's title and text still say `Project` and `Workroom` "stay in the app for now". They now live in `Packages/WorkroomDomain/Sources/WorkroomDomain/Model.swift`. Should the ADR text be updated?
6. Quick Terminal: would you accept a smaller pane-host type in place of its private `AppStore` (QuickTerminalController.swift:313), or is reusing the full store a deliberate way to keep its panes identical to a workroom's?

Not checked:
- I did not build anything, so the Swift 6 test-mode error count and the post-#483 Release binary contents are unmeasured. The Release proof is the 2.1.0 binary plus Nightly 2.2.0-nightly.2226.
- The call-count matrix in C1 is name-based and approximate.
