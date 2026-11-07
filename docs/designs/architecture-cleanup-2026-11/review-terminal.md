# Terminal context review (Swift app side)

Status: research. Evidence for the [cleanup plan](../architecture-cleanup-2026-11.md), measured at
`65f01f1fa`; its paths and counts are not updated as the plan is built.

Scope: `Core/TerminalSessions.swift`, `Core/GhosttySurfaceView.swift`, `Core/GhosttyRuntimeAdapter.swift`, `Core/Session/*`, `Core/SessionSnapshot.swift`, `Core/AppStore+RunCommand.swift`, `Views/PaneTreeView.swift`, `Views/TerminalTabStrip.swift`, `Views/WorkroomSplitView.swift`, `Views/WorkroomTabBar.swift`, packages `DaemonConnection` and `WorkroomWire`. All paths below are under `macapp/` unless they start with `docs/`. Read-only; no builds run.

Growth since the 2026-10-10 cleanup (`git show <rev before 2026-10-10>:<file> | wc -l` vs now, and `git log --since=2026-10-10 -- <file> | wc -l`):

| File | Lines then → now | Commits since |
|---|---|---|
| `Core/TerminalSessions.swift` | 2461 → 3211 | 44 |
| `Core/GhosttySurfaceView.swift` | 2106 → 2412 | 44 (15 of them also touch TerminalSessions) |
| `Core/Session/PersistentSessionService.swift` | 844 → 1000 | 21 |
| `Core/AppStore+RunCommand.swift` | new → 865 | 16 |
| `Views/TerminalTabStrip.swift` | 1027 → 1279 | 26 |
| `Views/PaneTreeView.swift` | 1215 → 1281 | 22 |

The 44 TerminalSessions commits come from at least six features owned by other contexts: Quick Terminal (App shell), program status and "needs you" alerts (#358), coding-agent usage in the footer (#480), window moves (#444), run sessions (#522) and weighted workroom evening (#569). Every one of them edited the same file.

---

## 1. Top complaints (ranked)

### 1. `TerminalSessions` is a hub object with at least nine jobs, and every feature edits it
**Claim.** One `ObservableObject` holds the tab registry, strip order, split groups, focus, content-tab preview rules, session restore, run tabs, detach and window hand-off, occlusion, live-title parsing with coding-agent and tool detection, Claude-profile reads, cwd, branch and host-cwd queries, program-status rollup, remote ⌘-click file resolution, and session ownership and ending.

**Evidence.**
- MARK sections at `Core/TerminalSessions.swift`: Queries 735, Session capture 810, Restore 1017, Content tabs 1201–1470, run tabs 1469–1572, splits/focus 1573–2155, detach 1771, Hand-over 1825, Occlusion 2155, Live titles 2177–2459 (coding agent, Claude profile, branch, host cwd, progress), Internals 2459, Program status 2762–2916, Remote pane links 2916–3048, ownership/end 3048–3211.
- 90 non-private `func`s and 50 private members after line 480 (awk count on the declaration pattern). 66 distinct `terminals.<member>` names are used from outside (`grep -rhoE '\bterminals\.[a-zA-Z]+' Core Views WorkroomApp.swift | sort -u | wc -l`).
- Per-target state lives in eight parallel dictionaries keyed by `TerminalTarget.ID` (`tabsByTarget` 485, `orderByTarget` 488, `splitsByTarget` 493, `focusedTabByTarget` 495, `paneRects` 516, `paneSpace` 526, `counts` 534, `announcedShownSlots` 619), plus per-tab task dictionaries (`hostCwdQueries` 717, `claudeProfileQueries` 719, `branchQueries` 1179, `remoteOpens` 2962). Removing a target means remembering all of them (`reap` 2097).
- Quick-Terminal-only mode flags on the shared model: `readsPaneBranches` 705, `allowsDetach` 708, `moveToWorkroomChoices` 711, `dropOutsideWindow` 714.
- Coding-agent code inside it: 70 lines match `codingAgent|CodingAgent|claude|Claude|RecognizedTool|ToolLogo|Unrecognized`. It holds `codingAgentManager` (697) and builds the UI-test stub runner in `init` (724).

**Cost.** Program status, coding-agent usage, Quick Terminal and window moves are separate features, and they all land in one 3.2k-line file and one 2.4k-line test file (`WorkroomAppTests/TerminalSessionsTests.swift`, 134 tests). Two people working on "needs you" alerts and on Quick Terminal pane moves edit the same type and the same test file. A new per-target field has to be added to a dictionary, to `reap`, to `handOff`/`adopt` (1850, 1917) and to `sessionCapture` (828) by hand.

**Direction.** Keep `TerminalSessions` as the facade `AppStore` talks to, and keep its `onEvent` sink (ADR 0021). Split out what it hosts:
- (a) a pure per-target value, `TargetPanes { tabs order, split groups, focused, counter }`, that holds ids only (see complaint 2);
- (b) `PaneLiveState`, the cwd, branch, host cwd, title, tool and agent observers (2177–2459), as one per-tab helper owned by the facade;
- (c) `ProgramStatusBinding` (2762–2916);
- (d) `RemotePaneLinks` (2916–3048);
- (e) content-tab opening and preview rules (1201–1470), which are about tabs, not terminals.
A per-target struct turns the eight dictionaries into one `[TerminalTarget.ID: TargetPanes]`, so `reap`, hand-off and capture each become one line.

**Size.** L, done in steps. **Test churn:** high for `TerminalSessionsTests`, but most tests drive the facade API, which stays.

### 2. The pane, tab and split model is not a value type: the tab value embeds an `NSView`
**Claim.** `PaneLayout<Leaf>` is already pure and lives in `WorkroomDomain` (good). The tab model around it is not. `TabContent.terminal(TerminalState)` holds `let view: GhosttySurfaceView` (`Core/TerminalSessions.swift:374`). The model also reads facts back off the view instead of owning them.

**Evidence.**
- `TerminalState.view` at 374. The persisted kind of a tab is decided from the view (`state.view.isRunSession` and `isRunCommandSurface`, 277–278).
- The session id and cwd are stored twice, on the state and on the view: `state.sessionID ?? state.view.persistentSessionID` at 286, 2243, 2343; `state.cwd ?? state.view.lastKnownCwd` at 285, 1188 and `Views/TerminalStatusBar.swift:34`. `Core/Session/TerminalSessionAttachment.swift:21-25` keeps the two copies in sync by hand.
- Tests of model behaviour construct a real AppKit view: `GhosttySurfaceView(` appears 109 times in 51 files under `WorkroomAppTests` (`grep -rn 'GhosttySurfaceView(' WorkroomAppTests | wc -l`). That includes `TerminalSessionsTests.swift:18,38,613`. These tests run in the hosted app bundle (`project.yml` test target, `SWIFT_VERSION: "5.0"` at line 374), not under `swift test`.

**Cost.** Any change to split, focus or close-successor rules needs the hosted test run (`make app-test`, with the GUI lock) instead of a package `swift test`. Two sources of truth for session id and cwd mean every new reader has to know the `??` idiom. A missed one reads a stale value.

**Direction.** Make `TerminalTab` ids-plus-descriptors only: `.terminal(TerminalPaneID)`, with session id, cwd and the run flag as stored fields. Keep surfaces in a `SurfaceRegistry [TerminalTab.ID: GhosttySurfaceView]` owned by the facade. With that, `TargetPanes` (1a) plus `PaneLayout` plus `PaneTreeLayout` (complaint 4) can move to a package such as `TerminalModel`, depending on `WorkroomDomain` only, with plain `swift test`.

**Size.** M–L. **Test churn:** medium. Restore and capture tests change how they build tabs.

### 3. The split-groups logic is written twice, for workroom splits and terminal splits, and the history shows each rule change made twice
**Claim.** "A list of disjoint `PaneLayout` trees with at least two leaves each, with insert, remove, collapse, auto-even and fit-check" is implemented once in `AppStore+WorkroomSplit` for `SidebarID` leaves and once in `TerminalSessions` for tab-id leaves. Comments say "Mirrors" instead of sharing code.

**Evidence (both sites):**
- Group lookup: `Core/AppStore+WorkroomSplit.swift:28-30` and `Core/TerminalSessions.swift:947-950`.
- Group index map: `AppStore+WorkroomSplit.swift:130-137` and `TerminalSessions.swift:961-967`. The comment at 957 says "Mirrors `AppStore.workroomSplitGroupIndices()`".
- Set a ratio: `AppStore+WorkroomSplit.swift:443-448` and `TerminalSessions.swift:2049-2054`, identical bodies.
- Fit check (measured space, then prospective insert, then `evenedIfHonourable`, then `fitsEveryPane`, else `canSplit`): `canInsertWorkroomSplit` at `AppStore+WorkroomSplit.swift:168-199` and `fits` at `TerminalSessions.swift:2479-2507`.
- Move into a split (the `adds`/`leftAxis`/`evenAxis` derivation): `AppStore+WorkroomSplit.swift:228-231` and `TerminalSessions.swift:1712-1723`.
- Remove and collapse: `detachFromSplitGroup` at `AppStore+WorkroomSplit.swift:340-347` and `removeFromGroup`/`setSplit` at `TerminalSessions.swift:2579-2589` and 2519-2548.
- History: 6e17146de ("dragging a pane to a new place in its split re-evens the split"), 856b43f0b ("even only the dividers along the axis a pane joined or left") and b1ecb7ac8 each changed both `AppStore+WorkroomSplit.swift` and `TerminalSessions.swift`, plus both `WorkroomSplitTests.swift` and `TerminalSessionsTests.swift` (`git show --stat`).

**Cost.** Each splitting rule (#126 evening, axis-limited evens, rearrange re-even) is written, reviewed and tested twice: 102 tests in `WorkroomSplitTests` and 134 in `TerminalSessionsTests`. The two copies have already drifted. The workroom version prunes dead leaves (`liveLeavesOnly` 506) and weights leaves (`workroomLeafSlots`); the terminal version does neither. So the next fix lands in one copy and not the other.

**Direction.** Add a generic `PaneSplitGroups<Leaf>` value type in `WorkroomDomain` next to `PaneLayout`. It would offer `group(containing:)`, `groupIndices`, `inserting(_:beside:edge:evening:)`, `removing(_:evening:)`, `settingRatio`, and `admits(insert:space:leafSlots:)`, with an even/fit policy injected as closures (`evenedIfHonourable` and `leafSlots`). `AppStore` and `TerminalSessions` each keep one instance per window or per target.

**Size.** M. **Test churn:** move most rule tests from the two app suites into one package suite. The callers' tests stay thin.

### 4. The pure layout math lives in a View file and depends on the hub object for three constants
**Claim.** `PaneTreeLayout` (`Views/PaneTreeView.swift:306-708`: planning, clamps, drop targets, fit and evenness checks, adjacency) is pure and generic over `Leaf`. It is tested by `PaneTreeLayoutTests.swift` (638 lines, 53 tests). But it sits in a SwiftUI file in the app target and gets its metrics from `TerminalSessions`.

**Evidence.** `Views/PaneTreeView.swift:309-311`: `dividerThickness`, `minPaneWidth` and `minPaneHeight` forward to `TerminalSessions.dividerThickness/minPaneWidth/minPaneHeight` (defined at `Core/TerminalSessions.swift:681,689,693`). The workroom split (`AppStore+WorkroomSplit`, `WorkroomSplitView`) depends on `TerminalSessions` only through these constants.

**Cost.** The workroom split cannot be tested or reasoned about without the terminal hub. The layout's tests run hosted when they could run under `swift test`.

**Direction.** Move `PaneTreeLayout`, `PaneDividerFrame` and the three metrics (as `PaneMetrics`) into `WorkroomDomain`, or into the `TerminalModel` package from complaint 2.

**Size.** S. **Test churn:** move one test file.

### 5. `GhosttySurfaceView` mixes the libghostty FFI view with daemon-session policy, remote reconnect policy and app commands, through singletons
**Claim.** The NSView wrapping `ghostty_surface_t` also decides whether to attach to a daemon session, builds the attach command and environment, runs the remote-link reconnect backoff and wake/network re-attach, shows pane toasts, and sends context-menu commands to the key window's `AppStore`.

**Evidence.**
- `PersistentSessionService.shared` appears 12 times in `Core/GhosttySurfaceView.swift` (`applyPersistentSession` 506–559, `reconnectIfTheLinkDropped` 583–604, `reattachAfterNetworkChange` 609–626, the `persistentSessionID` `didSet` at 88, and `tearDown` at 484). `TerminalSessions` has an injectable `sessionService` (`TerminalSessions.swift:702`, "Settable for tests"), but the view ignores it and uses the singleton, so that seam does not cover the attach path.
- `WindowRegistry.shared.keyStore?.newTerminalInSelectedTarget()` and five split and close siblings at 2076–2091. The same menu uses per-view closures for other items (`onToggleWindow` 163, `moveToWorkroomChoices` 165).
- `RemoteReconnectBackoff` is defined in the view file at 2393.
- The view's jobs by MARK: accessibility polling 246, lifecycle and attach 298, geometry 641, occlusion 750, focus 771, theming 854, scrollbar 875, go-to-bottom 886, pane notice 902, progress-timeout policy 1029, inline-agent screen capture 1176, keyboard 1389–1767, mouse 1767, pointer 1923, context menu 1995, drag and drop 2124, IME 2215.

**Cost.** A change to remote reconnect (a Remote hosts and Daemon connection concern: #392, #507) edits the same 2.4k-line file as a keyboard or IME fix, and is tested by constructing the view (`GhosttySurfaceViewTests.swift`). Fifteen of the 44 commits since 2026-10-10 touched this file and `TerminalSessions` together.

**Direction.** Split it into:
- `GhosttySurfaceView`, the FFI, input, render and accessibility only. Its `extension`s are already partly split: keep keyboard, mouse and IME in `GhosttySurfaceView+Input.swift`.
- A `PaneSessionAttachment` object, injected, that owns `applyPersistentSession`, the reconnect backoff and network re-attach, and that the view asks for `(command, env)` before `createSurface`.
- Context-menu commands raised as surface events, not through `WindowRegistry.shared.keyStore`.

**Size.** M. **Test churn:** the reconnect tests in `GhosttySurfaceViewTests` (around 249–330) move to the new type and stop needing an NSView.

### 6. Surface callbacks are 13 single-slot closures, written from three files, so run, window-move and sessions overwrite each other's wiring
**Claim.** ADR 0021 made `TerminalSessions` → `AppStore` one typed sink. One level down, surface → owner is still 13 optional closures (`onActivity`, `onOpenURL`, `onCmdClickFile`, `resolveCmdHoverFile`, `onTitleChange`, `onCwdChange`, `onCommandFinished`, `onProgressReport`, `onChildExited`, `onCloseRequested`, `onFocused`, `onToggleWindow`, `moveToWorkroomChoices`; `GhosttySurfaceView.swift:114-165`). `AppStore` reaches through the model to the view to set some of them.

**Evidence.** `grep -nE '\.(on[A-Z]\w+|resolveCmdHoverFile|moveToWorkroomChoices) = '` finds:
- `TerminalSessions.swift` ×14 (2703–2757, and 2937–2944 overwriting `onCmdClickFile`, `resolveCmdHoverFile` and `onOpenURL` set at 2751–2757 for remote panes);
- `AppStore+RunCommand.swift:498,522,533,547` (`terminals.tab(...)?.surface?.onChildExited = …`);
- `AppStore+WindowMove.swift:262,353`, which re-wires or clears the run command's `onChildExited` after a move;
- `QuickTerminalController.swift:319`.

**Cost.** Run commands (#522) and window moves (#444) both own `onChildExited` on the same view. Whoever assigns last wins, and the window-move author has to know the run code's wiring to re-create it. These two features cannot be changed independently.

**Direction.** Give the surface one `onEvent: (SurfaceEvent) -> Void`, set once by `TerminalSessions.wire`. `TerminalSessions` turns `.childExited` for a run tab into the existing `Event.runStatus` or `.runSessionGone` path, or a new `Event.runChildExited`, so `AppStore` never touches `surface?.on…`. This applies ADR 0021's own reasoning one layer down. It does not contradict it.

**Size.** M. **Test churn:** low to medium (`RunCommandTests`, `DetachedPaneTests`).

### 7. One coarse `ObservableObject` republishes every title and pulse to the whole window, and fixes have been applied view by view
**Claim.** `TerminalSessions` is still `ObservableObject` with seven `@Published` dictionaries (485–507). `AppStore` moved to `@Observable` (`AppStore.swift:15-21`). Any `@Published` write invalidates every observer.

**Evidence.**
- Observers: `RootView.swift:12`, `ProjectSidebar.swift:21`, `WorkroomTabBar.swift:444` and `ToastStack.swift:17` via `@EnvironmentObject`; `PaneTreeView.swift:19,726`, `TerminalTabStrip.swift:25`, `WorkroomTerminalsView.swift:16`, `HistoryPanel.swift:43`, `ChangesPanel.swift:739` and `DetachedPaneView.swift:24` via `@ObservedObject`.
- Point fixes: WORKROOM-2B, a hang of 2000 ms or more (ADR 0018; `FocusedTabSelection.swift:1-15`; `ChangesPanel.swift:460`; `HistoryPanel.swift:229`); `LiveTitle` split into its own observable (`TerminalSessions.swift:366`, `docs/macapp-perf-facts.md` "A title event is cheap").
- The terminal divider writes the store on every drag tick (`PaneTreeView.swift:1190-1257` calls `sessions.setRatio` from `onChanged`, which writes `@Published splitsByTarget`). The workroom divider avoids exactly this for issue #139 (`WorkroomSplitView.swift:69-80`, local `liveRatio`).

**Cost.** Each new view that observes `TerminalSessions` reopens the WORKROOM-2B class of bug, and the fix is re-derived per view (ADR 0018 is a rule for inspector rows only). A divider drag in a terminal split republishes `RootView`, `ProjectSidebar` and the workroom tab bar at cursor rate. That is unmeasured: profiling would settle it.

**Direction.** Move to `@Observable` after the per-target split (1a), so observation is per `TargetPanes` and not per window. A migration has one named dependency to replace: `AppStore.swift:996-998` marks the saved layout dirty from `terminals.objectWillChange`. That needs an explicit `Event.layoutChanged` or an observation-tracking hook. Make the terminal divider use the same live/commit pattern as the workroom one (see section 2, duplication D1).

**Size.** M (after 1a). **Test churn:** invalidation tests (`*InvalidationTests`) re-baseline.

### 8. `TerminalTarget.ID` is a pipe-encoded string, and four functions re-derive the project or `SidebarID` from it
**Claim.** `SidebarID` is a typed enum in `WorkroomDomain`. `TerminalTarget.ID` encodes the same thing as `"wr|<project>|<name>"` or `"root|<project>"` (`Core/Models.swift:130-131`). Code converts between the two by scanning every project, or by parsing the string.

**Evidence.**
- `AppStore+RunCommand.swift:95-100` `project(forTargetID:)` and `:174-181` `project(forTarget:)` have the same body, the second one private.
- `AppStore+RunCommand.swift:193-205` `sidebarID(forTarget:)`.
- `AppStore.swift:3720-3730` `sidebarID(forTargetID:in:)` (static).
- `TerminalSessions.swift:3203-3210` `projectPath(from:)` hand-parses the `wr|`/`root|` prefixes.
- `SessionSnapshot.swift:425` documents the same encoding as the on-disk contract.

All the scans are O(projects × workrooms) string builds, and run per `paneCountChanged` (`AppStore+WorkroomSplit.swift:466`) and per status-bar render (`branchLabel` → `sidebarID(forTarget:)`, comment at 168–173 about WORKROOM-3D).

**Cost.** A change to the target-id format, such as the `creation|` id added for #483, has to find the parser in `TerminalSessions`, which no type points to. Four near-copies drift in which kinds of id they handle: `projectPath(from:)` has no `creation` branch.

**Direction.** Make `TerminalTarget.ID` a typed `TargetID` (or `SidebarID` itself) with `encoded`/`init?(encoded:)` for persistence, kept in `WorkroomDomain`. Delete the four resolvers. **Size.** M (id is pervasive). **Test churn:** medium, mostly mechanical.

### 9. "Session" means four different things in the code
**Claim.** `CONTEXT.md` (Terminal) defines **Session** as "a persistent pseudo-terminal held by workroomd". The code also uses "session" for:
- the saved window layout (`SessionSnapshot.swift`, `SessionStore.swift`, `SessionCoordinator.swift`, `AppStore+Session.swift`, `SessionRestoreTests`, `TargetSession`, `TabSession`);
- the tab and pane model (`TerminalSessions`);
- the detached-session list (`Core/Session/TerminalSessionsStore.swift`).

The remote copy of the saved layout is already called **layout** (`HostLayout.swift`, ADR 0044/0048), and `CONTEXT.md` has no term for the local one (only "layout" in Window, line 189).

**Cost.** "Session restore" can mean reattaching a pty (ADR 0046) or decoding `session.json` (ADR 0048), and both happen in the same restore path (`TerminalSessions.restore` 1044). Newcomers and reviewers cannot tell from a name which persistence they are touching. `macapp/AGENTS.md`'s "Session and VCS changes" rule needs an adversarial reviewer for `Core/Session/` but not for `SessionSnapshot.swift`, and the names make that boundary easy to misread.

**Direction.** Add a glossary term, such as **Saved layout**: the tabs, splits and windows a Mac restores, kept in `session.json` locally and as the host layout remotely. Rename gradually: `SessionSnapshot` → `SavedLayout`, `TerminalSessions` → `TerminalPanes` (or `PaneStore`), `TerminalSessionsStore` → `DetachedSessionList`. The file name `session.json` stays (stored contract).

**Size.** S for the glossary, M for the renames. **Test churn:** renames only.

### 10. The daemon's Control service has two Swift clients with two envelope codecs
**Claim.** Local control (list, kill, signal, retag) goes through the app's `Core/Session/DaemonControlClient.swift`: blocking socket, its own `Service` enum (40–43), `encodeEnvelope`/`decodeEnvelope` (98–117). Remote control goes through `DaemonConnection`'s `DaemonVCSConnection.sessions/endSession/signalSession` (`Packages/DaemonConnection/Sources/DaemonConnection/DaemonVCSConnection.swift:328-378`), with its own `envelope(service:stream:payload:)` (579–587) and service constants (94–109). `PersistentSessionService.signalRun` (794–822) and `retag` (828–837) branch on local or remote to choose between them.

**Why ADR 0005 does not cover this.** ADR 0005 accepts duplicating the frame between Swift and Rust. This is Swift against Swift, in the same process.

**Cost.** A new Control verb (retag was added for #577) is written twice, or only locally. `retag` has no remote path (`retagOverride` aside, 829–830 returns false for remote). The service byte numbering is kept in step in two Swift files plus Rust.

**Direction.** Put one `DaemonControl` codec (envelope plus control verbs) in `DaemonConnection`. `DaemonControlClient` becomes a thin blocking transport over it, or local control uses the same async connection type. Also: `DaemonVCSConnection` carries VCS, File, Control, Forward, Layout and ProgramStatus (service list at 94–109), so the name hides what it is. Rename it to `DaemonConnection` or `DaemonStream`. That package also imports `WorkroomVCS` (`Package.swift`), so the Daemon connection context depends on Version control. Worth a second look by the VCS reviewer.

**Size.** S–M. **Test churn:** low.

### 11. `PersistentSessionService` (1000 lines) mixes the legacy-helper drain, a remote session registry and quit bookkeeping
**Evidence.**
- Ownership resolution against the retired Swift helper: `backend(forSession:)` 294, `resolveOwner` 310, `helperOwnership` 360, `confirmBeforeAttach` 474, `HelperSessionState` 445.
- Remote registry and kill throttling: `remoteSessions` 111, `attachedRemote` 116, the `unended*` fields 120–124, `remoteKillsPerHost` 755, `retryWhenReconnected` 907.
- Quit budget: 26–60. Run signals: 794. Orphan sweeps: 944–1000.
- It reaches `RemoteHosts.shared` (177, 800–801) and `HostConnectionManager.shared` (802).

The helper-drain half is already planned for deletion (`TODOS.md:148`, "Retire the attach-only `workroom-session` shim"), so that part is a known item.

**Cost.** Remote-host work (#392, #507, #283) and local daemon work edit the same singleton. Remote kill retry logic is tested through it.

**Direction.** When the shim goes, split this into `LocalSessionControl` (socket, backend probe, attach command) and `RemoteSessionRegistry` (host, driver, attached panes, unended retries). Inject both into `TerminalSessions` and the attachment object from complaint 5. **Size.** M, best done with the TODOS retirement. **Test churn:** medium.

### 12. Smaller placement drift
- `AppStore+RunCommand.swift` holds base-branch settings (`globalBaseBranch`, `effectiveBaseBranch`, `setBaseBranch` at 133–160), which belong to Workroom management, and `branchName(for:)` (221), which is the app-wide branch answer and belongs to Version control. Neither is about run commands. Cost: anyone looking for base-branch code will not look in the run-command file. S.
- `SessionSnapshot.swift`'s header still says "Run tabs ... Run-command tabs are never persisted" (lines 36–42). That contradicts ADR 0058 and `TabSession.init?` (`TerminalSessions.swift:268-278`, which keeps run tabs). It is a stale doc on a stored-contract file. S.
- `Core/Session/DaemonBootstrap.swift` (585 lines; imports only packages, plus one `Bundle.main`) and its 899+572 lines of tests could live in `HostDrivers` (which it already imports) or `DaemonConnection` and run under `swift test`. S–M.
- `TerminalTarget` (`Core/Models.swift:18-80`) carries Remote hosts presentation (`hostTooltip`, `workroomGlyph`, `machineName`, `hostPlace: RemoteWorkrooms.Place`). This is part of ADR 0020's deferred move of `Project`/`HostDescriptor` and is noted here only because it is what stops the tab model's target type from moving to a package.

---

## 2. Dead code and duplication

### Dead code
None found with proof. Checked with `grep -rn --include='*.swift' -F '<name>' WorkroomApp | grep -v 'func '`, and the same over `WorkroomAppTests WorkroomAppUITests`, for 21 non-private `TerminalSessions` members (`activeTab(for`, `ensureTab(for`, `liveBranchRead(`, `seedProgramStatusForFixture(`, `attachments(of`, `defaultTitle(ofTab`, `blockedTerminalCount(`, `isWaitingStale(`, `hasProgramError(`, `visibleTabIDs(for`, `allTabs(for`, `tabCount(forTargetID`, `activeTargetIDs`, `containsTab(`, `pulsePaneActivity(`, `openFilePersistent(`, `openDiffPersistent(`, `view(for`, `applyThemeToAll(`, `blockedTabs(forTargetID`, `isProgressFailed(forTargetID`). Every one has an app caller except `liveBranchRead(` (app=0, tests=3), which is a test seam.

Rename candidate, not dead: `activeTab(for:)` is a one-line alias of `focusedTab(for:)` (`TerminalSessions.swift:991`), used 10 times in the app and 103 times in tests. Two names for one query.

`macapp/WorkroomSession/` (838 lines) is live until the shim retirement already planned in `TODOS.md:148`.

### Duplication (all sites)
- **D1. Divider view.** `Views/PaneTreeView.swift:1190-1257` (`SplitDivider`, writes live) and `Views/WorkroomSplitView.swift:667-767` (`WorkroomSplitDivider`, live plus commit). Same re-anchor, clamp, pointer style and accessibility code. They differ only in commit semantics and the accessibility id. One view with `onLive` and an optional `onCommit` would remove about 70 lines and the per-tick store write in D1's terminal half (complaint 7).
- **D2. Drop highlight, already drifted.** `PaneTreeView.swift:152-172` draws its own `RoundedRectangle` in `Color.accentColor`. `DropAccent` (`WorkroomSplitView.swift:170-188`) says "One look for every drop target ... so they can't drift apart" and uses `ThemeService.shared.tokens.accent`. They now use different accent colours. Make PaneTreeView use `DropAccent`.
- **D3. Split groups** (complaint 3): six pairs of sites, listed above.
- **D4. Tab-strip chrome.** `splitRunRects` in `TerminalTabStrip.swift:403-420` and `WorkroomTabBar.swift:319-335` (same bucketing loop). `showsLeadingSeparator` in `TerminalTabStrip.swift:444-452` and `WorkroomTabBar.swift:259-276`, where the first-tab rule already differs. `showsTrailingDivider` in `TerminalTabStrip.swift:460-465` and `WorkroomTabBar.swift:58-62`. `splitWell` in both. There are 20 "mirror" or "same as" cross-references across the two files (`grep -ciE 'mirror|same as'`: 7 + 13). `TabReorderMath.swift` already holds the shared arithmetic, and these belong there, generic over the id.
- **D5. Control envelope** (complaint 10): `Core/Session/DaemonControlClient.swift:98-117` and `DaemonVCSConnection.swift:579-587`.
- **D6. Target-id resolution** (complaint 8): `AppStore+RunCommand.swift:95-100`, `:174-181`, `:193-205`, `AppStore.swift:3720-3730`, `TerminalSessions.swift:3203-3210`.
- **D7. Session id and cwd stored twice** (complaint 2): `TerminalSessions.swift:285-286, 1188, 2243, 2343`, and `Views/TerminalStatusBar.swift:34`.

---

## 3. Proposed target structure

```
Packages/
  WorkroomDomain            (exists)  + PaneSplitGroups<Leaf>, PaneTreeLayout, PaneMetrics, typed TargetID
  TerminalModel   (new)     → WorkroomDomain
      TargetPanes  (tabs order, split groups, focus, counter; ids + descriptors only)
      TerminalTab / TabContent without the NSView (terminal payload = session id, cwd, run flag)
      close-successor, normalised strip order, restore/capture mapping to the Codable mirror
      swift test, Swift 6
  DaemonConnection (exists) + one Control codec; DaemonVCSConnection → DaemonConnection/DaemonStream
                              (+ DaemonBootstrap, or into HostDrivers)
  WorkroomWire     (exists, frozen per ADR 0006)

WorkroomApp/Terminal/        (folder; app target, AppKit/libghostty)
  Surface/   GhosttySurfaceView (+Input, +Accessibility, +Overlays), GhosttyApp, GhosttyRuntimeAdapter
             SurfaceEvent (one sink)
  Attach/    PaneSessionAttachment (attach command/env, reconnect backoff, network re-attach)
             LocalSessionControl, RemoteSessionRegistry  (after the shim retirement)
  Panes/     TerminalPanes facade (was TerminalSessions): owns [TargetID: TargetPanes] + SurfaceRegistry,
             PaneLiveState, ProgramStatusBinding, RemotePaneLinks; onEvent (ADR 0021) unchanged
  Views/     PaneTreeView, TerminalTabStrip, shared SplitDivider / DropAccent / TabStripChrome
WorkroomApp/Core/AppStore+RunCommand  → run only; base-branch + branchName move to their contexts
```

Dependency direction: `TerminalModel` depends only on `WorkroomDomain`. The app's `Terminal/` folder depends on `TerminalModel`, `DaemonConnection`, `HostDrivers` and GhosttyKit, and never on `AppStore`. `TerminalSessions` already holds no `AppStore` reference in code: every hit for `AppStore` in the file is in a comment. Keep it that way. `AppStore` (the App shell composition root) depends on `Terminal/` through the facade and `onEvent` only, never through `tab.surface?.on…`.

Ownership boundaries this buys:
- split, focus and layout rules: one owner, package tests;
- the libghostty view: one owner (input, render, accessibility);
- session attach and remote reconnect: a Daemon connection and Remote hosts owner;
- coding-agent and program-status bindings: their feature owners, plugged into the facade.

What still blocks a package for the model:
1. `TerminalState.view` (complaint 2);
2. `TerminalTarget`'s remote presentation fields and `RepositoryLocation` (ADR 0020's deferred move);
3. `ContentDescriptor` kinds (`DiffDescriptor`, `FileDescriptor`, `ChangesetDescriptor`, plus `NavPayload` bridging): these are app types, and would need to move to `WorkroomDomain` or `WorkroomVCS` as plain values;
4. the `Defaults[.autoResizeSplitsEvenly]` and `SwitcherRecency.shared` defaults, which are already injectable closures and properties.

---

## 4. Good, keep it
- `PaneLayout<Leaf>`, a pure, generic, `Equatable` tree in `WorkroomDomain`, used by both splits (`Packages/WorkroomDomain/Sources/WorkroomDomain/PaneLayout.swift`, 254-line test file).
- ADR 0021's single typed `onEvent` sink, and `TerminalSessions` never naming `AppStore` in code.
- The `SessionSnapshot` hand-written Codable mirror with `@Lossy`, decode-depth caps and the versioning rule (ADR 0048). It is a solid stored-data contract.
- `GhosttyRuntimeAdapter`'s pure, unit-tested mappings (clipboard confirmation, notification mapping) and the coalesced tick pump in `GhosttyApp`.
- `TabReorderMath.swift`'s shared, tested strip math. Extend it (D4), don't replace it.
- `PaneTreeLayout.shouldReanchorDrag` shared by both dividers, so the re-anchor rule cannot drift (only the view around it did).
- Deep "why" comments that cite issues and failure modes. They are what made this review cheap.

## 5. Open questions for the owner
1. Is one `TerminalSessions` per window (`AppStore.swift:991`) a decision? It is what forces `TargetHandOff` (`TerminalSessions.swift:1831`) and `RunCommandController.HandOff` for #444 moves. An app-wide pane store keyed by target, with windows holding only selection and layout, would remove the hand-off path. Worth an ADR either way.
2. Should content tabs (diff, file, changeset: three of the four `TabContent` kinds, with `case .changeset` switched in 8 files) be owned by the Terminal context at all? Or should "tab" become an App shell concept with terminal as one kind?
3. Is the terminal divider's live write per drag tick (`PaneTreeView.swift:1218-1223`) intended, given #139's fix for the workroom divider? A quick Instruments run on a terminal-split drag would settle complaint 7's unmeasured cost.
4. Do you want the glossary term for the saved layout (complaint 9) before any renames, so names follow `CONTEXT.md`?
5. When the remote fallback driver can't find a host's driver, it uses a `ContainerHostDriver` (`TerminalSessions.swift:3150-3152`, `?? ContainerHostDriver(hosts: [:], directory: RemoteHosts.directory)`). Is that fallback right for boxd, exe.dev and SSH hosts, or only for containers? (Not verified: flagged for the Remote hosts reviewer.)
