import AppKit
import DaemonConnection
import Defaults
import DesignSystem
import SwiftUI
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// The sidebar's rows are built by adapters behind equality gates, and what changes often (VCS
/// status, selection, the drag, the run, a host's status) is read in leaves of their own. These
/// count, by row, which row bodies a change re-runs: the change a row shows re-runs that row, and
/// one it doesn't show re-runs none.
///
/// Each negative test makes its change twice and measures the second: measured in this harness,
/// the first update of a view type in the process re-runs its body whatever its inputs
/// (`AdapterGateInvalidationTests`).
@MainActor
final class SidebarInvalidationTests: XCTestCase {
  /// The real sidebar under a holder of the drag state, as `SidebarColumn` holds it.
  private struct DragHost: View {
    /// The drag state's binding, as its last pass handed it to the sidebar.
    static var drag: Binding<WorkroomPaneDrag?>?
    /// The binding of state the host reads and the sidebar doesn't, as `RootView` and a column
    /// resize hold theirs.
    static var unrelated: Binding<Int>?
    /// The passes of this body, so a test sees its change re-ran the host.
    static var passes = 0
    static let token = UUID()
    @State private var drag: WorkroomPaneDrag?
    @State private var unrelated = 0

    var body: some View {
      let _ = {
        Self.drag = $drag
        Self.unrelated = $unrelated
        Self.passes += 1
      }()
      // Read, so a write re-runs this body.
      let _ = unrelated
      ProjectSidebar(
        drag: SidebarDragPlumbing(
          token: Self.token, drag: $drag, localize: { _ in nil }, dropTarget: { _ in nil })
      )
      .equatable()
    }
  }

  private struct Fixture {
    let store: AppStore
    /// Project A, with one workroom; project B, with none.
    let a: Project
    let b: Project
    /// The tab in A's root.
    let surfaceA: GhosttySurfaceView
    let tabA: TerminalTab.ID
    let window: NSWindow
    let view: NSView
    /// The fixture's folders, removed when it closes.
    let folder: URL

    var rootA: SidebarID { .root(project: a.path) }
    var rootB: SidebarID { .root(project: b.path) }
  }

  /// Real folders, so the targets open terminals and can run a command.
  private func fixture() throws -> Fixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sidebar-invalidation-\(UUID().uuidString)")
    let paths = ["a", "b", "a/w"].map { root.appendingPathComponent($0).path }
    for path in paths {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    let store = AppStore()
    makeInert(store)
    store.projectStore.projects = [
      Project(
        path: paths[0], vcs: "git",
        workrooms: [Workroom(name: "w", path: paths[2], vcsName: "w", warnings: [])]),
      Project(path: paths[1], vcs: "git", workrooms: []),
    ]
    store.collapsedProjects = []
    let a = store.projectStore.projects[0]
    let b = store.projectStore.projects[1]
    let tabA = store.terminals.addTab(for: a.rootTarget)
    let surfaceA = try XCTUnwrap(store.terminals.surface(tabA))
    let tabAID = tabA.id
    _ = store.terminals.addTab(for: b.rootTarget)

    DragHost.drag = nil
    DragHost.unrelated = nil
    let (window, hosting) = hostInWindow(
      DragHost()
        .environmentObject(store)
        .environmentObject(store.runCommand)
        .environmentObject(store.projectStore)
        .environmentObject(store.vcsStatus)
        .environmentObject(store.lifecycle)
        .environmentObject(store.notifications)
        .environmentObject(store.modals)
        .themeTokensRoot()
        .frame(width: 300, height: 700),
      size: NSSize(width: 300, height: 700))
    return Fixture(
      store: store, a: a, b: b, surfaceA: surfaceA, tabA: tabAID, window: window, view: hosting,
      folder: root)
  }

  private func close(_ f: Fixture) {
    f.window.close()
    DragHost.drag = nil
    DragHost.unrelated = nil
    try? FileManager.default.removeItem(at: f.folder)
    Task { await f.store.terminals.reapAll() }
  }

  /// Lets SwiftUI run any update the change scheduled.
  private func render(_ f: Fixture) async throws { try await render(f.view) }

  private func listRows(_ f: Fixture) throws -> Int {
    func findTable(_ view: NSView) -> NSTableView? {
      if let table = view as? NSTableView { return table }
      return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    return try XCTUnwrap(findTable(f.view), "must host the native List").numberOfRows
  }

  // MARK: Terminals

  /// A's agent stopping changes what A's root row shows (its spinner), and nothing of any other.
  func testAnAgentInOneTargetReRunsOnlyThatTargetsRow() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    XCTAssertGreaterThan(SidebarRowPasses.total, 0, "the fixture must render actual rows")
    try await agentStartsWorking(on: f.surfaceA)
    try await render(f)
    XCTAssertTrue(f.store.terminals.isRunning(forTargetID: f.a.rootTarget.id))

    SidebarRowPasses.reset()
    f.surfaceA.handleProgressReport(false)
    try await render(f)

    XCTAssertFalse(
      f.store.terminals.isRunning(forTargetID: f.a.rootTarget.id), "the change landed")
    XCTAssertEqual(
      Set(SidebarRowPasses.byRow.keys), [f.rootA], "only A's root row shows A's agent")
  }

  /// The subtree is its own view, so it still lists one List row per terminal (issue #30).
  func testAnExpandedSubtreeListsOneRowPerTerminal() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    // Projects A and B, A's root and workroom, B's root.
    XCTAssertEqual(try listRows(f), 5)

    _ = f.store.terminals.addTab(for: f.a.rootTarget)
    f.store.toggleTerminals(for: f.a.rootTarget.id)
    try await render(f)

    XCTAssertEqual(try listRows(f), 7, "A's root lists its two terminals")
    XCTAssertGreaterThan(SidebarRowPasses.terminal, 0, "the terminal rows drew")
  }

  /// A host's status publishing re-runs no row: the terminal rows' tooltip line is the only thing
  /// it can change, and the tooltip reads it itself. That tooltip has no positive half here:
  /// SwiftUI builds a modifier that only adds a tooltip when the tooltip is asked for, which no
  /// test window does, so its body never runs in this harness.
  func testAHostStatusPublishReRunsNoRow() async throws {
    let f = try fixture()
    defer { close(f) }
    _ = f.store.terminals.addTab(for: f.a.rootTarget)
    f.store.toggleTerminals(for: f.a.rootTarget.id)
    try await render(f)
    XCTAssertGreaterThan(SidebarRowPasses.terminal, 0, "the fixture must render terminal rows")
    ProgramStatusMonitor.shared.objectWillChange.send()
    try await render(f)

    SidebarRowPasses.reset()
    ProgramStatusMonitor.shared.objectWillChange.send()
    try await render(f)

    XCTAssertEqual(SidebarRowPasses.total, 0, "a host status publish must re-run no row")
  }

  // MARK: The run

  func testARunStartingReRunsNoRow() async throws {
    let f = try fixture()
    defer {
      close(f)
      f.store.runCommands.setRunConfig(.empty, forProject: f.a.path)
    }
    f.store.runCommands.setRunConfig(
      RunConfig(command: "npm run dev", autoRun: false), forProject: f.a.path)
    let target = f.a.rootTarget
    try await render(f)
    f.store.runCommand.runStates[target.id] = .running(tab: f.tabA, interrupted: false)
    try await render(f)
    f.store.runCommand.runStates[target.id] = nil
    try await render(f)

    SidebarRowPasses.reset()
    f.store.runCommand.runStates[target.id] = .running(tab: f.tabA, interrupted: false)
    try await render(f)

    XCTAssertTrue(f.store.runCommand.isRunCommandRunning(for: target.id), "the run started")
    XCTAssertEqual(SidebarRowPasses.total, 0, "a run starting must re-run no row")
    XCTAssertGreaterThan(
      SidebarRowPasses.runButton, 0, "the run button decides it shows, so it re-runs")
  }

  // MARK: Selection

  func testSelectionReRunsNoRow() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    f.store.selectedTargetID = f.rootB
    // The selection's status probe runs against the fixture's folders; it measures nothing here.
    f.store.selectionStatusTask?.cancel()
    try await render(f)

    SidebarRowPasses.reset()
    f.store.selectedTargetID = f.rootA
    f.store.selectionStatusTask?.cancel()
    try await render(f)

    XCTAssertEqual(SidebarRowPasses.total, 0, "a selection must re-run no row")
    XCTAssertGreaterThan(
      SidebarRowPasses.background, 0, "the row backgrounds read the selection, so they re-run")
  }

  // MARK: The theme

  /// A theme switch repaints an expanded terminal row's background: its subtree reads the theme
  /// from the environment, so the switch re-runs it although its `==` leaves the theme out.
  func testAThemeSwitchRepaintsAnExpandedTerminalRow() async throws {
    let savedFamily = Defaults[.themeFamily]
    defer { ThemeService.shared.applyFamily(savedFamily) }
    ThemeService.shared.applyFamily(ThemeCatalog.defaultFamilyName)
    let original = ThemeService.shared.tokens.hover
    let other = try XCTUnwrap(
      ThemeCatalog.families.first { family in
        ThemeService.shared.applyFamily(family.name)
        defer { ThemeService.shared.applyFamily(ThemeCatalog.defaultFamilyName) }
        return ThemeService.shared.tokens.hover != original
      },
      "the catalog needs a family with another hover colour")

    let f = try fixture()
    defer { close(f) }
    _ = f.store.terminals.addTab(for: f.a.rootTarget)
    f.store.toggleTerminals(for: f.a.rootTarget.id)
    // The selected target's focused terminal draws the theme's hover colour.
    f.store.selectedTargetID = f.rootA
    f.store.selectionStatusTask?.cancel()
    try await render(f)
    let focused = try XCTUnwrap(f.store.terminals.focusedTab(for: f.a.rootTarget)?.id)
    XCTAssertEqual(SidebarRowPasses.terminalFills[focused], original)

    ThemeService.shared.applyFamily(other.name)
    let switched = ThemeService.shared.tokens.hover
    try await render(f)
    settle(f.view, seconds: 2) { SidebarRowPasses.terminalFills[focused] == switched }
    XCTAssertEqual(SidebarRowPasses.terminalFills[focused], switched, "the row repaints")

    ThemeService.shared.applyFamily(ThemeCatalog.defaultFamilyName)
    try await render(f)
    settle(f.view, seconds: 2) { SidebarRowPasses.terminalFills[focused] == original }
    XCTAssertEqual(
      SidebarRowPasses.terminalFills[focused], original, "the row repaints on a second switch")
  }

  // MARK: The drag

  func testADragTickReRunsNoRow() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    let drag = try XCTUnwrap(DragHost.drag, "the host must hand over its drag state")
    drag.wrappedValue = WorkroomPaneDrag(sid: f.rootA, location: CGPoint(x: 10, y: 10))
    try await render(f)

    SidebarRowPasses.reset()
    drag.wrappedValue = WorkroomPaneDrag(sid: f.rootA, location: CGPoint(x: 20, y: 10))
    try await render(f)

    XCTAssertEqual(SidebarRowPasses.total, 0, "a drag tick must re-run no row")
    XCTAssertGreaterThan(SidebarRowPasses.dragDim, 0, "the rows' dim reads the drag, so it re-runs")
  }

  // MARK: The holder

  /// A pass of the view holding the sidebar (a `RootView` pass, a column resize) re-runs no tree:
  /// the sidebar's gate compares its drag plumbing, which that pass leaves equal.
  func testAPassOfTheHolderReRunsNoTree() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    let unrelated = try XCTUnwrap(DragHost.unrelated, "the host must hand over its own state")
    unrelated.wrappedValue += 1
    try await render(f)

    SidebarRowPasses.reset()
    DragHost.passes = 0
    unrelated.wrappedValue += 1
    try await render(f)

    XCTAssertGreaterThan(DragHost.passes, 0, "the change re-ran the holder")
    XCTAssertEqual(SidebarRowPasses.tree, 0, "a pass of the holder must re-run no tree")
    XCTAssertEqual(SidebarRowPasses.total, 0, "a pass of the holder must re-run no row")
  }

  // MARK: VCS

  func testAVCSChangeReRunsNoRow() async throws {
    let f = try fixture()
    defer { close(f) }
    f.store.vcsStatus.workroomStatuses[f.rootA] = WorkroomStatus(dirty: false)
    try await render(f)
    f.store.vcsStatus.mergeLocalStatus(WorkroomStatus(dirty: true), into: f.rootA)
    try await render(f)

    SidebarRowPasses.reset()
    f.store.vcsStatus.mergeLocalStatus(WorkroomStatus(dirty: false), into: f.rootA)
    try await render(f)

    XCTAssertEqual(f.store.vcsStatus.workroomStatuses[f.rootA]?.dirty, false, "the change landed")
    XCTAssertEqual(SidebarRowPasses.total, 0, "a VCS change must re-run no row")
  }

  /// A root's branch resolving repaints its label, tooltip and spoken label, which read it
  /// themselves, and re-runs no row.
  func testARootBranchResolvingReRunsNoRow() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    f.store.vcsStatus.rootRefs[f.b.id] = RootRef(branch: "main", kind: .branch)
    try await render(f)

    SidebarRowPasses.reset()
    f.store.vcsStatus.rootRefs[f.a.id] = RootRef(branch: "feature", kind: .branch)
    try await render(f)

    XCTAssertEqual(SidebarRowPasses.total, 0, "a root's branch resolving must re-run no row")
    XCTAssertGreaterThan(SidebarRowPasses.rootLabel, 0, "the root's label reads it, so it re-runs")
  }

  // MARK: What a row shows (positives)

  // Each makes the change a row shows twice and measures the second, as the negatives do, so a gate
  // that drops a field from its `==` fails here rather than passing on a first update.

  /// The filesystem can't be observed, so a project's folder going shows on its root row when the
  /// app next reloads its list, which republishes it unchanged; and its coming back the same way.
  func testARootFolderGoingShowsOnItsRowAtTheNextReload() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    XCTAssertEqual(SidebarRowPasses.folderMissing[f.rootA], false)

    try FileManager.default.removeItem(atPath: f.a.path)
    f.store.projectStore.projects = f.store.projectStore.projects
    try await render(f)
    XCTAssertEqual(
      SidebarRowPasses.folderMissing[f.rootA], true, "A's root row shows its folder gone")

    SidebarRowPasses.reset()
    try FileManager.default.createDirectory(atPath: f.a.path, withIntermediateDirectories: true)
    f.store.projectStore.projects = f.store.projectStore.projects
    try await render(f)

    XCTAssertEqual(
      SidebarRowPasses.folderMissing[f.rootA], false, "A's root row shows its folder back")
    XCTAssertNil(SidebarRowPasses.byRow[f.rootB], "B's folder never went")
  }

  /// A root's metadata watcher firing re-checks that root alone, so its folder going shows on its
  /// row before the next reload, and no other row re-runs.
  func testARootFolderGoingShowsOnItsRowWhenItsWatcherFires() async throws {
    let f = try fixture()
    defer { close(f) }
    try await render(f)
    try FileManager.default.removeItem(atPath: f.a.path)
    f.store.projectStore.recheckMissingRoot(projectID: f.a.id)
    try await render(f)
    XCTAssertEqual(
      SidebarRowPasses.folderMissing[f.rootA], true, "A's root row shows its folder gone")

    SidebarRowPasses.reset()
    try FileManager.default.createDirectory(atPath: f.a.path, withIntermediateDirectories: true)
    try FileManager.default.removeItem(atPath: f.b.path)
    f.store.projectStore.recheckMissingRoot(projectID: f.a.id)
    try await render(f)

    XCTAssertEqual(
      SidebarRowPasses.folderMissing[f.rootA], false, "A's root row shows its folder back")
    XCTAssertNil(SidebarRowPasses.byRow[f.rootB], "only A's root was re-checked")
    XCTAssertFalse(f.store.projectStore.missingRoots.contains(f.b.id))
  }

  /// A workroom's folder going reaches its row as the list's `DirectoryMissing` warning.
  func testAWorkroomFolderGoingShowsOnItsRow() async throws {
    let f = try fixture()
    defer { close(f) }
    let wid = SidebarID.workroom(project: f.a.path, name: "w")
    let workroom = try XCTUnwrap(f.a.workrooms.first)
    let gone = Warning(
      kind: "DirectoryMissing", message: "directory not found", path: workroom.path, vcs: nil)
    func publish(warnings: [Warning]) {
      f.store.projectStore.projects[0] = Project(
        path: f.a.path, vcs: f.a.vcs,
        workrooms: [
          Workroom(
            name: workroom.name, path: workroom.path, vcsName: workroom.vcsName,
            warnings: warnings)
        ])
    }
    try await render(f)
    publish(warnings: [gone])
    try await render(f)
    publish(warnings: [])
    try await render(f)
    XCTAssertEqual(SidebarRowPasses.folderMissing[wid], false)

    SidebarRowPasses.reset()
    publish(warnings: [gone])
    try await render(f)

    XCTAssertEqual(SidebarRowPasses.folderMissing[wid], true, "the row shows its folder gone")
  }

  /// A workroom's label and name are on its row.
  func testALabelAndARenameReRunTheWorkroomsRow() async throws {
    let f = try fixture()
    defer { close(f) }
    let workroom = try XCTUnwrap(f.a.workrooms.first)
    func publish(name: String, label: String?) {
      f.store.projectStore.projects[0] = Project(
        path: f.a.path, vcs: f.a.vcs,
        workrooms: [
          Workroom(
            name: name, path: workroom.path, vcsName: workroom.vcsName, warnings: [],
            label: label)
        ])
    }
    let wid = SidebarID.workroom(project: f.a.path, name: "w")
    try await render(f)
    publish(name: "w", label: "One")
    try await render(f)

    SidebarRowPasses.reset()
    publish(name: "w", label: "Two")
    try await render(f)
    XCTAssertEqual(SidebarRowPasses.workroomTitles[wid], "Two", "the row shows its new label")

    SidebarRowPasses.reset()
    publish(name: "w2", label: nil)
    try await render(f)
    let renamed = SidebarID.workroom(project: f.a.path, name: "w2")
    XCTAssertEqual(SidebarRowPasses.workroomTitles[renamed], "w2", "the row shows its new name")
  }

  /// A create's failure shows on its workroom's row, in the step circle that observes its run.
  func testACreationFailingShowsOnItsWorkroomsRow() async throws {
    let f = try fixture()
    defer { close(f) }
    let lifecycle = f.store.lifecycle
    let wid = TargetID.workroom(project: f.a.path, name: "w")
    func attach() -> CreationRun {
      let run = CreationRun(project: f.a, kind: nil, splitAnchor: nil, previousSelection: nil)
      lifecycle.creationRuns[run.id] = run
      lifecycle.creationRunForTarget[wid] = run.id
      return run
    }
    defer {
      lifecycle.creationRunForTarget[wid] = nil
      lifecycle.creationRuns = [:]
    }
    try await render(f)
    let first = attach()
    try await render(f)
    first.fail(.failedBeforeWorkroom(message: "first"))
    try await render(f)
    let second = attach()
    try await render(f)
    XCTAssertEqual(SidebarRowPasses.createSteps[second.id], "progress")

    SidebarRowPasses.reset()
    second.fail(.failedBeforeWorkroom(message: "second"))
    try await render(f)

    XCTAssertEqual(
      SidebarRowPasses.createSteps[second.id], "failed", "the row shows its create failed")
  }

  /// A terminal starting to wait on the user is on its target's row.
  func testATerminalNeedingYouReRunsItsTargetsRow() async throws {
    let f = try fixture()
    defer { close(f) }
    let monitor = ProgramStatusMonitor()
    f.store.terminals.programStatus = monitor
    let session = UUID()
    // A tab with a session follows its host's program status, as a daemon-backed tab does.
    _ = f.store.terminals.addTab(for: f.a.rootTarget, sessionID: session)
    let waiting = ProgramStatusRecord(id: "", state: .blocked, kind: .question, episode: 1)
    try await render(f)
    monitor.seed(session, records: [waiting])
    try await render(f)
    monitor.seed(session, records: [])
    try await render(f)

    SidebarRowPasses.reset()
    monitor.seed(session, records: [waiting])
    try await render(f)

    XCTAssertEqual(f.store.terminals.blockedTerminalCount(forTargetID: f.a.rootTarget.id), 1)
    XCTAssertEqual(
      Set(SidebarRowPasses.byRow.keys), [f.rootA], "only A's root row shows A's terminal waiting")
  }

  /// An unread notification repaints the unread dots, which read the notifications themselves, and
  /// re-runs no row.
  func testAnUnreadNotificationRepaintsTheDotsAndNoRow() async throws {
    let f = try fixture()
    defer { close(f) }
    func notify() {
      f.store.notifications.recordNotice(
        targetID: f.a.rootTarget.id, source: "test", title: "Done", body: nil)
    }
    try await render(f)
    notify()
    try await render(f)

    SidebarRowPasses.reset()
    notify()
    try await render(f)

    XCTAssertEqual(f.store.notifications.count(target: f.a.rootTarget.id), 2, "the change landed")
    XCTAssertGreaterThan(SidebarRowPasses.unreadDot, 0, "the dots read it, so they re-run")
    XCTAssertEqual(SidebarRowPasses.total, 0, "an unread notification must re-run no row")
  }

  /// A terminal's title is drawn by its row's title leaf, which reads it live.
  func testATerminalTitleChangeShowsOnItsRow() async throws {
    let f = try fixture()
    defer { close(f) }
    _ = f.store.terminals.addTab(for: f.a.rootTarget)
    f.store.toggleTerminals(for: f.a.rootTarget.id)
    try await render(f)
    f.surfaceA.handleTitleChange("one")
    try await render(f)

    SidebarRowPasses.reset()
    f.surfaceA.handleTitleChange("two")
    try await render(f)

    XCTAssertEqual(SidebarRowPasses.terminalTitles[f.tabA], "two", "the row shows its new title")
  }

  // MARK: Structure (control)

  /// The tree still reads its structure: collapsing a project re-runs its row and drops its
  /// children from the List, terminal rows and all.
  func testCollapsingAProjectStillRebuildsTheTree() async throws {
    let f = try fixture()
    defer { close(f) }
    _ = f.store.terminals.addTab(for: f.a.rootTarget)
    f.store.toggleTerminals(for: f.a.rootTarget.id)
    f.store.selectedTargetID = f.rootA
    f.store.selectionStatusTask?.cancel()
    try await render(f)
    XCTAssertEqual(try listRows(f), 7)

    SidebarRowPasses.reset()
    f.store.collapsedProjects.insert(f.a.path)
    try await render(f)

    XCTAssertEqual(try listRows(f), 3, "collapse removes A's root, its terminals and workroom")
    XCTAssertGreaterThan(
      SidebarRowPasses.byRow[.project(f.a.path)] ?? 0, 0, "A's row shows its chevron turn")
  }
}
