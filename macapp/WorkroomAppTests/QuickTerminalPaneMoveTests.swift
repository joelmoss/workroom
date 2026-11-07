import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// A Quick Terminal pane moving into a window's workroom, from panes no window store owns: the
/// source side needs only its `TerminalPanes` and the app's notification list.
@MainActor
final class QuickTerminalPaneMoveTests: XCTestCase {
  private let projects = ProjectStore()
  private let registry = WindowRegistry()
  private let sid = SidebarID.workroom(project: "/p", name: "a")

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  /// Value: protects=a pane moves from bare panes (no AppStore behind them) into a window's
  /// workroom, its notifications following it to that window, and leaves its source;
  /// fails_when=the move reads a source store, skips the repoint, or leaves the pane behind;
  /// why_new=the Quick Terminal's host is no longer a window store; seam=none;
  /// no_claim=the retag (WorkroomHandOverTests), window raise on screen.
  func testAPaneMovesFromBarePanesIntoAWindowsWorkroom() async throws {
    let notifications = registry.notifications
    let source = TerminalPanes()
    source.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    source.recordUnrecognizedTool = { _ in }
    source.allowsDetach = false
    source.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned })
    let quickTarget = QuickTerminalController.target()
    let pane = source.addTab(for: quickTarget)
    let window = AppStore(projectStore: projects, notifications: notifications)
    window.services.notifier = SilentNotifier()
    window.confirmOnCloseOverrideForTesting = false
    window.terminals.makeView = source.makeView
    window.terminals.recordUnrecognizedTool = { _ in }
    let target = try XCTUnwrap(window.target(for: sid))
    _ = window.terminals.addTab(for: target)
    window.selectedTargetID = sid
    _ = notifications.record(
      targetID: quickTarget.id, tabID: pane.id, activity: .osc(title: "done", body: nil),
      focused: false, origin: ObjectIdentifier(source))

    await QuickTerminalPaneMove.move(
      pane.id, of: quickTarget, source: source, notifications: notifications, to: window,
      into: sid)

    XCTAssertNotNil(window.terminals.tab(pane.id, for: target), "it arrives")
    XCTAssertEqual(window.terminals.allTabs(for: target).last?.id, pane.id)
    XCTAssertNil(source.tab(pane.id, for: quickTarget), "and leaves")
    XCTAssertEqual(source.tabCount(forTargetID: quickTarget.id), 0)
    let moved = notifications.items.filter { $0.tabID == pane.id }
    XCTAssertEqual(moved.count, 1)
    XCTAssertEqual(moved.first?.targetID, target.id, "its notification names the workroom")
    XCTAssertEqual(moved.first?.origin, ObjectIdentifier(window), "and the window it is in")
  }
}

/// Posts nothing.
private final class SilentNotifier: SystemNotifying, @unchecked Sendable {
  func ensureAuthorized() async -> Bool { false }
  func post(_ notification: WorkroomNotification) {}
  func withdraw(tabIDs: [TerminalTab.ID]) {}
  func withdraw(identifiers: [String]) {}
}
