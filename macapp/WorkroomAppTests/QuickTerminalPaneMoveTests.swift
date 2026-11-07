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
    let (source, pane, window, target) = try makeMove()
    let quickTarget = QuickTerminalController.target()
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

  /// Value: protects="Move to Workroom" built over bare panes lists the window's workroom and its
  /// choice moves the pane there; fails_when=a choice's closure captures or needs a source store,
  /// or drops its source before the move; why_new=the choices were run only through a store's
  /// forwarder (C4 review); seam=the window list; no_claim=menu rendering.
  func testAChoiceBuiltOverBarePanesMovesThePane() async throws {
    let (source, pane, window, target) = try makeMove()
    let quickTarget = QuickTerminalController.target()

    let groups = QuickTerminalPaneMove.choices(
      pane.id, of: quickTarget, source: source, notifications: registry.notifications,
      windows: [window])

    let choice = try XCTUnwrap(groups.first?.choices.first)
    XCTAssertEqual(choice.title, window.title(for: sid))
    choice.move()
    for _ in 0..<50 where window.terminals.tab(pane.id, for: target) == nil {
      await Task.yield()
    }
    XCTAssertNotNil(window.terminals.tab(pane.id, for: target), "it arrives")
    XCTAssertEqual(source.tabCount(forTargetID: quickTarget.id), 0, "and leaves")
  }

  /// Bare panes holding one Quick Terminal pane, and a window over the fixture projects with
  /// workroom `a` open and selected.
  private func makeMove() throws -> (
    source: TerminalPanes, pane: TerminalTab, window: AppStore, target: TerminalTarget
  ) {
    let source = makeIsolatedPanes()
    source.allowsDetach = false
    let pane = source.addTab(for: QuickTerminalController.target())
    let window = AppStore(projectStore: projects, notifications: registry.notifications)
    window.services.notifier = SilentNotifier()
    window.confirmOnCloseOverrideForTesting = false
    window.terminals.makeView = source.makeView
    window.terminals.recordUnrecognizedTool = { _ in }
    let target = try XCTUnwrap(window.target(for: sid))
    _ = window.terminals.addTab(for: target)
    window.selectedTargetID = sid
    return (source, pane, window, target)
  }
}
