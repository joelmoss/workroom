import AppKit
import Observation
import WorkroomDomain
import XCTest

@testable import Workroom

/// Multi-window foundations (issue #70): windows share one `ProjectStore` but keep independent
/// per-window `AppStore` state, and `WindowRegistry` tracks windows + aggregates their unread counts.
@MainActor
final class MultiWindowTests: XCTestCase {
  private func project(_ path: String, workrooms: [String] = []) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "git", warnings: [])
      }
    )
  }

  private func notification(_ targetID: TargetID) -> WorkroomNotification {
    WorkroomNotification(
      id: UUID(), targetID: targetID, tabID: UUID(), source: "src",
      title: "t", body: nil, date: Date(timeIntervalSince1970: 0), count: 1)
  }

  // MARK: ProjectStore sharing

  func testWindowsShareProjectsButNotSelection() {
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)

    shared.projects = [project("/p", workrooms: ["w"])]
    XCTAssertEqual(a.projectStore.projects.map(\.id), ["/p"])
    XCTAssertEqual(
      b.projectStore.projects.map(\.id), ["/p"], "both windows read the one shared project list")

    a.selectedTargetID = .root(project: "/p")
    XCTAssertEqual(a.selectedTargetID, .root(project: "/p"))
    XCTAssertNil(b.selectedTargetID, "selection is per-window, not shared")
  }

  func testAWriteThroughOneWindowReachesTheSharedStore() {
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)

    a.projectStore.projects = [project("/x")]
    XCTAssertEqual(
      shared.projects.map(\.id), ["/x"], "writing via one window updates the shared store")
    XCTAssertEqual(
      b.projectStore.projects.map(\.id), ["/x"], "…and is visible to the other window")
  }

  func testIsolatedStoresDoNotShareProjects() {
    let a = AppStore()  // default: its own fresh ProjectStore
    let b = AppStore()
    a.projectStore.projects = [project("/only-a")]
    XCTAssertTrue(
      b.projectStore.projects.isEmpty,
      "bare AppStore() is isolated, so tests never pollute each other")
  }

  /// A project-list write that changes nothing notifies no one, so the sidebar, tab bar and title
  /// bar reading the list do not redraw: a workroom relabelled to the label it has, or one dropped
  /// that is already gone. An in-place write to a stored `@Observable` property notifies even when
  /// the value is equal; `ProjectStore`'s setter makes it a whole-value write, which does not.
  func testAProjectListWriteThatChangesNothingNotifiesNoOne() {
    let store = AppStore()
    store.projectStore.projects = [project("/p", workrooms: ["w"])]
    let gone = Workroom(name: "gone", path: "/p/gone", vcsName: "git", warnings: [])
    var notified = false
    withObservationTracking {
      _ = store.projectStore.projects
    } onChange: {
      notified = true
    }
    store.relabelLocally("w", in: "/p", to: nil)
    store.removeWorkroomLocally(gone, in: store.projectStore.projects[0])
    XCTAssertFalse(notified, "a write that changed nothing must not redraw")
    store.relabelLocally("w", in: "/p", to: "Auth")
    XCTAssertTrue(notified, "a write that changes the list still notifies")
  }

  /// Value: protects=a create or delete set write that changes nothing (a create's release after
  /// a failed remote create already released it, a tombstone lifted twice) redraws nothing that
  /// reads the sets, as when `AppStore` forwarded them; fails_when=a set is a plain stored property
  /// on the lifecycle; why_new=the sets moved owner without a guard; seam=none.
  func testACreateOrDeleteSetWriteThatChangesNothingNotifiesNoOne() {
    let lifecycle = WorkroomLifecycle(vcsStatus: VCSStatusService(projectStore: ProjectStore()))
    let id = TargetID.workroom(project: "/p", name: "w")
    var notified = false
    withObservationTracking {
      _ = lifecycle.creatingWorkrooms
      _ = lifecycle.creationRunForTarget
      _ = lifecycle.deletingWorkrooms
      _ = lifecycle.deletingProjects
    } onChange: {
      notified = true
    }
    lifecycle.creatingWorkrooms.remove(id)
    lifecycle.creationRunForTarget[id] = nil
    lifecycle.deletingWorkrooms.remove(id)
    lifecycle.deletingProjects.remove("/p")
    XCTAssertFalse(notified, "a write that changed nothing must not redraw")
    lifecycle.creatingWorkrooms.insert(id)
    XCTAssertTrue(notified, "a write that changes a set still notifies")
  }

  // MARK: Blank new windows

  func testInitialRestoreIsOneShot() {
    let shared = ProjectStore()
    XCTAssertTrue(
      shared.consumeInitialRestore(), "the first restoring window claims the saved selection")
    XCTAssertFalse(shared.consumeInitialRestore(), "every later window (incl. ⌘N) starts blank")
    XCTAssertFalse(shared.consumeInitialRestore())
  }

  // MARK: WindowRegistry

  func testRegistryTracksWindowsAndRoutesByWindow() {
    let registry = WindowRegistry()
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)
    let winA = NSWindow()
    let winB = NSWindow()

    registry.register(window: winA, store: a)
    registry.register(window: winB, store: b)

    XCTAssertEqual(registry.allStores.count, 2)
    XCTAssertTrue(registry.store(for: winA) === a)
    XCTAssertTrue(registry.store(for: winB) === b)

    registry.unregister(window: winA)
    XCTAssertEqual(registry.allStores.count, 1)
    XCTAssertNil(registry.store(for: winA))
  }

  func testRegistryReRegisterIsIdempotent() {
    let registry = WindowRegistry()
    let store = AppStore(projectStore: ProjectStore())
    let win = NSWindow()
    registry.register(window: win, store: store)
    registry.register(window: win, store: store)
    XCTAssertEqual(
      registry.allStores.count, 1, "re-resolving the same window doesn't double-register")
  }

  func testRegistryTracksAgentsAcrossWindowsAndRemovesClosedWindows() async {
    let registry = WindowRegistry()
    let first = AppStore(projectStore: ProjectStore())
    let second = AppStore(projectStore: ProjectStore())
    let firstWindow = NSWindow()
    let secondWindow = NSWindow()
    let target = TerminalTarget(
      id: .root(project: "/tmp"), title: "test", path: "/tmp", isMissing: false)
    for store in [first, second] {
      store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
      store.terminals.addTab(for: target)
    }
    registry.register(window: firstWindow, store: first)
    registry.register(window: secondWindow, store: second)
    let codex = first.terminals.tabs(for: target)[0].surface!
    let claude = second.terminals.tabs(for: target)[0].surface!
    codex.foregroundProcessNameForTesting = "codex"
    codex.handleTitleChange("Codex")
    claude.foregroundProcessNameForTesting = "claude"
    claude.handleTitleChange("Claude")
    for _ in 0..<20 where registry.activeCodingAgentBackends != [.codex, .claude] {
      await Task.yield()
    }
    XCTAssertEqual(registry.activeCodingAgentBackends, [.codex, .claude])

    codex.handleCommandFinished(rawExitCode: 0)
    for _ in 0..<20 where registry.activeCodingAgentBackends != [.claude] { await Task.yield() }
    XCTAssertEqual(registry.activeCodingAgentBackends, [.claude])
    registry.unregister(window: secondWindow)
    XCTAssertTrue(registry.activeCodingAgentBackends.isEmpty)
    registry.unregister(window: firstWindow)
  }

  /// Value: protects=every window showing the app's one notification list and one count (ADR 0064);
  /// fails_when=a window gets a list of its own again or the count stops following the list;
  /// why_new=the old test summed per-window lists; seam=none; no_claim=SwiftUI rendering.
  func testWindowsShareOneNotificationListAndCount() {
    let registry = WindowRegistry()
    let a = AppStore(projectStore: ProjectStore(), notifications: registry.notifications)
    let b = AppStore(projectStore: ProjectStore(), notifications: registry.notifications)
    registry.register(window: NSWindow(), store: a)
    registry.register(window: NSWindow(), store: b)

    a.notifications.seedForTesting([notification(.root(project: "/t1"))])
    b.notifications.record(
      targetID: .root(project: "/t2"), tabID: UUID(), activity: .osc(title: "done", body: nil),
      focused: false)

    XCTAssertEqual(a.notifications.items.count, 2, "A lists B's notification")
    XCTAssertEqual(registry.aggregateUnread, 2, "the count follows the list without a recompute")
  }

  /// **The window number is assigned AFTER the view update, and must stay that way.** `register` is
  /// reached from `WindowAccessor`'s `viewDidMoveToWindow`, which SwiftUI runs while it installs the
  /// representable's backing view — i.e. inside a view update. Assigning `AppStore.windowNumber`
  /// (`@Published`) from there fired `objectWillChange` mid-update, which is Apple-declared undefined
  /// behaviour: "Publishing changes from within view updates is not allowed, this will cause
  /// undefined behavior", logged exactly 9 times per launch, every one of them this call path
  /// (measured 9 before the deferral, 0 after). `recomputeBadge`'s `aggregateUnread` rides along for
  /// the same reason.
  ///
  /// A SwiftUI runtime issue can't be asserted from a unit test, so what's pinned is the property
  /// that removes it: nothing observable is written on `register`'s own turn.
  func testWindowNumberIsAssignedAfterRegisterReturnsNotDuringIt() async {
    let registry = WindowRegistry()
    let store = AppStore(projectStore: ProjectStore())

    registry.register(window: NSWindow(), store: store)
    XCTAssertEqual(
      store.windowNumber, 0,
      """
      `register` assigned the window number on its own turn again — that write lands inside a \
      SwiftUI view update and is undefined behaviour. It must be deferred to the main actor.
      """)

    // The deferred work is a main-actor `Task`, which cannot start until this one suspends.
    for _ in 0..<10 where store.windowNumber == 0 { await Task.yield() }
    XCTAssertEqual(
      store.windowNumber, 1, "the first registered window still gets number 1, just a turn later")
  }

  // MARK: Window cycling (issue #87)

  func testCyclePlanForwardSurfacesSecondAndSendsFrontBack() {
    // Front-to-back [A, B, C]; ⌘` brings B (just behind the front) forward and pushes A to the
    // back, so repeated presses rotate A→B→C→A rather than bouncing between the front two.
    let plan = WindowRegistry.cyclePlan(ordered: ["A", "B", "C"], forward: true)
    XCTAssertEqual(plan?.front, "B")
    XCTAssertEqual(plan?.sendBack, "A")
  }

  func testCyclePlanBackwardSurfacesBackmostWithNoSendBack() {
    // ⇧⌘` brings the backmost window forward; doing so rotates the rest back one on its own, so
    // there's no separate window to push to the back.
    let plan = WindowRegistry.cyclePlan(ordered: ["A", "B", "C"], forward: false)
    XCTAssertEqual(plan?.front, "C")
    XCTAssertNil(plan?.sendBack)
  }

  func testCyclePlanNeedsAtLeastTwoWindows() {
    XCTAssertNil(WindowRegistry.cyclePlan(ordered: ["only"], forward: true), "nothing to cycle to")
    XCTAssertNil(WindowRegistry.cyclePlan(ordered: ["only"], forward: false))
    XCTAssertNil(WindowRegistry.cyclePlan(ordered: [String](), forward: true))
  }

  // MARK: Create and delete across windows

  /// Windows registered on `WindowRegistry.shared` by the create/delete tests below, as the app
  /// registers its windows. Unwound in `tearDown`, so a failed assertion can't leak a registration
  /// into a later test.
  private var registeredWindows: [NSWindow] = []

  override func tearDown() {
    for window in registeredWindows { WindowRegistry.shared.unregister(window: window) }
    registeredWindows = []
    super.tearDown()
  }

  /// Two windows over one lifecycle and project list, each registered as the app registers a window.
  private func twoWindows(cli: WorkroomCLIProtocol) -> (AppStore, AppStore) {
    let shared = WorkroomLifecycle(vcsStatus: VCSStatusService(projectStore: ProjectStore()))
    let windows = (AppStore(lifecycle: shared, cli: cli), AppStore(lifecycle: shared, cli: cli))
    for store in [windows.0, windows.1] {
      store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
      let window = NSWindow()
      WindowRegistry.shared.register(window: window, store: store)
      registeredWindows.append(window)
    }
    return windows
  }

  /// A two-leaf workroom split of `first` and `second`.
  private func split(_ first: SidebarID, _ second: SidebarID) -> PaneLayout<SidebarID> {
    .split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))
  }

  /// Value: protects=a workroom deleted in one window leaves no trace in another that showed it:
  /// out of its split, off its selection, its run state gone; fails_when=the delete reaches only the
  /// window it was made in; why_new=no test had two windows for a delete, and in tests a store's
  /// siblings were only itself; seam=one WorkroomLifecycle for both windows;
  /// no_claim=the teardown's own steps.
  func testADeleteInOneWindowClearsItFromTheOther() async {
    let path = "/private/var/tmp/wr-two-window-delete"
    let main = Workroom(name: "main", path: "\(path)/.workrooms/main", vcsName: "git", warnings: [])
    let doomed = Workroom(
      name: "doomed", path: "\(path)/.workrooms/doomed", vcsName: "git", warnings: [])
    let before = Project(path: path, vcs: "git", workrooms: [main, doomed])
    let fake = FakeWorkroomCLI(
      canonical: path, projects: [Project(path: path, vcs: "git", workrooms: [main])])
    let (a, b) = twoWindows(cli: fake)
    a.projectStore.projects = [before]
    let mainSid = SidebarID.workroom(project: path, name: "main")
    let doomedSid = SidebarID.workroom(project: path, name: "doomed")
    let doomedID = TargetID.workroom(project: path, name: "doomed")
    b.workroomSplits = [split(mainSid, doomedSid)]
    b.selectedTargetID = doomedSid
    b.runCommand.armAutoRun(forWorkroom: doomedID)

    a.lifecycle.deleteWorkroom(doomed, in: before, from: a)

    XCTAssertNil(b.workroomSplit(containing: doomedSid), "the other window's split lost it")
    XCTAssertEqual(b.selectedTargetID, mainSid, "the other window lands on what it split with")
    for _ in 0..<200 where !a.lifecycle.deletingWorkrooms.isEmpty {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTAssertTrue(a.lifecycle.deletingWorkrooms.isEmpty, "the teardown finished")
    XCTAssertNil(b.runCommand.runStates[doomedID], "the other window's run state went with it")
  }

  /// Value: protects=a delete whose dev server is still stopping in another window finishes when
  /// that window closes before the server exits: the other window's terminals are reaped and the
  /// teardown runs; fails_when=the delete holds the other window's store only weakly, so its stop's
  /// poll stops with it and the tombstone stays until relaunch (the workroom hidden, its worktree
  /// or paid machine left); why_new=no test closed a window mid-delete; seam=one WorkroomLifecycle
  /// for both windows, liveProcessOverrideForTesting; no_claim=how long the stop waits.
  func testADeleteFinishesWhenAWindowStoppingItsRunClosesMidStop() async {
    let path = "/private/var/tmp/wr-two-window-delete-closing"
    let main = Workroom(name: "main", path: "\(path)/.workrooms/main", vcsName: "git", warnings: [])
    let doomed = Workroom(
      name: "doomed", path: "\(path)/.workrooms/doomed", vcsName: "git", warnings: [])
    let before = Project(path: path, vcs: "git", workrooms: [main, doomed])
    let fake = FakeWorkroomCLI(
      canonical: path, projects: [Project(path: path, vcs: "git", workrooms: [main])])
    let a: AppStore
    // Only the window holds its store (`RootWindow`'s `@StateObject`): no other strong local.
    var b: AppStore?
    do {
      let windows = twoWindows(cli: fake)
      (a, b) = (windows.0, windows.1)
    }
    a.projectStore.projects = [before]
    let doomedID = TargetID.workroom(project: path, name: "doomed")
    guard let server = b.flatMap({ runDevServer(in: $0, at: doomedID, inProject: path) }),
      let terminals = b?.terminals
    else { return XCTFail("the other window runs the workroom's dev server") }
    server.liveProcessOverrideForTesting = true
    weak var closed = b

    a.lifecycle.deleteWorkroom(doomed, in: before, from: a)
    // The other window closes while its dev server is still stopping.
    if let registered = registeredWindows.last {
      WindowRegistry.shared.unregister(window: registered)
    }
    b = nil
    server.liveProcessOverrideForTesting = false

    for _ in 0..<500 where !a.lifecycle.deletingWorkrooms.isEmpty {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTAssertTrue(a.lifecycle.deletingWorkrooms.isEmpty, "the teardown ran")
    XCTAssertEqual(terminals.tabCount(forTargetID: doomedID), 0, "the closed window was reaped")
    XCTAssertNil(closed, "and the delete let go of its store")
  }

  /// Starts `id`'s dev server in `window` and returns its terminal, its process standing in.
  private func runDevServer(
    in window: AppStore, at id: TerminalTarget.ID, inProject project: String
  ) -> GhosttySurfaceView? {
    guard let sid = id.sidebarID, let target = window.target(for: sid) else { return nil }
    window.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    window.runCommand.signalSupervisorForTesting = { _, _ in .delivered }
    window.runCommands.setRunConfig(
      RunConfig(command: "echo hi", autoRun: false), forProject: project)
    window.startRunCommand(for: target)
    return window.runCommand.runTabID(for: id).flatMap { window.terminals.tab($0, for: target) }?
      .surface
  }

  /// Value: protects=a create started in one window becomes its workroom in another that shows its
  /// pane, in the selection and in a split, once it has a name; fails_when=only the window it was
  /// started in swaps the pane; why_new=as above; seam=one WorkroomLifecycle for both windows;
  /// no_claim=the create's checklist.
  func testACreateInOneWindowNamesItsPaneInTheOther() async {
    let path = "/private/var/tmp/wr-two-window-create"
    let fake = GatedFakeCLI(
      projectPath: path, names: ["fresh"], hasSetup: false, gate: .beforeReady,
      existing: ["main"])
    let (a, b) = twoWindows(cli: fake)
    a.lifecycle.creationSuccessHold = .zero
    a.lifecycle.closesFinishedCreations = { false }
    await a.reload()
    guard let project = a.projectStore.projects.first else {
      return XCTFail("the fake lists its project")
    }
    let mainSid = SidebarID.workroom(project: path, name: "main")

    let create = Task { await a.lifecycle.createWorkroom(in: project, from: a) }
    var pane: SidebarID?
    for _ in 0..<200 {
      if case .creation = a.selectedTargetID { pane = a.selectedTargetID }
      if pane != nil { break }
      await Task.yield()
    }
    guard let pane else {
      create.cancel()
      return XCTFail("the create's pane opens in the window it was started in")
    }
    b.workroomSplits = [split(mainSid, pane)]
    b.selectedTargetID = pane

    fake.release("fresh")
    await create.value

    let fresh = SidebarID.workroom(project: path, name: "fresh")
    XCTAssertEqual(a.selectedTargetID, fresh, "the window it was started in shows the workroom")
    XCTAssertEqual(b.selectedTargetID, fresh, "so does the other window's selection")
    XCTAssertEqual(
      b.workroomSplit(containing: fresh)?.tabIDs, [mainSid, fresh],
      "and its split holds the workroom where the pane was")
  }

  // MARK: Window-close guard (A3)

  func testCloseGuardAllowsCloseWithoutRunCommand() {
    let store = AppStore(projectStore: ProjectStore())
    let guardDelegate = WindowCloseGuard(store: store, forwarding: nil)
    XCTAssertFalse(store.runCommand.hasLiveRunCommand, "no run command in a fresh store")
    XCTAssertTrue(
      guardDelegate.windowShouldClose(NSWindow()),
      "with no live run command the window closes immediately — no confirm, no stop")
  }

  // New-window sizing (issue #70) opens a window at the current window's size from the first frame
  // (RootWindow's idealWidth/Height ← WindowRegistry.preferredNewWindowContentSize). It reads live
  // NSWindows from the shared registry — which the unit-test host app itself populates with a window —
  // so it isn't cleanly unit-testable; it's verified live (no open-small-then-resize flash).
}
