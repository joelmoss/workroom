import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// A pane moving between any two targets, in any holders: here two windows' workrooms, and one
/// window's own two workrooms, with no Quick Terminal involved.
@MainActor
final class PaneMoveTests: XCTestCase {
  private let projects = ProjectStore()
  private let registry = WindowRegistry()
  private let sidA = SidebarID.workroom(project: "/p", name: "a")
  private let sidB = SidebarID.workroom(project: "/p", name: "b")

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [
          Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: []),
          Workroom(name: "b", path: "/p/b", vcsName: "workroom/b", warnings: []),
        ])
    ]
  }

  private func makeWindow() -> AppStore {
    let window = AppStore(projectStore: projects, notifications: registry.notifications)
    window.services.notifier = SilentNotifier()
    window.confirmOnCloseOverrideForTesting = false
    window.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    window.terminals.recordUnrecognizedTool = { _ in }
    // Every retag succeeds: there is no daemon behind these panes.
    window.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
    return window
  }

  private func target(_ window: AppStore, _ sid: SidebarID) throws -> TerminalTarget {
    try XCTUnwrap(window.target(for: sid))
  }

  /// Value: protects=a pane moves live from one window's workroom into another window's, keeping
  /// its surface, its notification following it, and the destination window selected on it;
  /// fails_when=the move only handles a Quick Terminal source, or leaves the pane or its
  /// notification behind; why_new=the move was Quick-Terminal-only (#653); seam=AppStore pair;
  /// no_claim=window raise on screen.
  func testAPaneMovesBetweenTwoWindowsWorkrooms() async throws {
    let first = makeWindow()
    let second = makeWindow()
    let from = try target(first, sidA)
    let into = try target(second, sidB)
    let pane = first.terminals.addTab(for: from)
    _ = second.terminals.addTab(for: into)
    let surface = first.terminals.surface(pane)
    _ = registry.notifications.record(
      targetID: from.id, tabID: pane.id, activity: .osc(title: "done", body: nil),
      focused: false, origin: ObjectIdentifier(first))

    await PaneMove.move(
      pane.id, of: from, source: first.terminals, notifications: registry.notifications,
      to: second, into: into.id)

    XCTAssertNil(first.terminals.tab(pane.id, for: from), "it leaves")
    XCTAssertTrue(second.terminals.surface(second.terminals.tab(pane.id, for: into)) === surface)
    XCTAssertEqual(second.selectedTargetID, sidB)
    let moved = registry.notifications.items.filter { $0.tabID == pane.id }
    XCTAssertEqual(moved.map(\.targetID), [into.id])
    XCTAssertEqual(moved.map(\.origin), [ObjectIdentifier(second)])
  }

  /// Value: protects=a pane moves between two workrooms of one window and that window selects the
  /// destination; fails_when=the same-window case is refused as "same panes"; why_new=#653;
  /// seam=AppStore; no_claim=none.
  func testAPaneMovesBetweenTwoWorkroomsOfOneWindow() async throws {
    let window = makeWindow()
    let from = try target(window, sidA)
    let into = try target(window, sidB)
    let pane = window.terminals.addTab(for: from)
    _ = window.terminals.addTab(for: from)

    await PaneMove.move(
      pane.id, of: from, source: window.terminals, notifications: registry.notifications,
      to: window, into: into.id)

    XCTAssertNil(window.terminals.tab(pane.id, for: from))
    XCTAssertNotNil(window.terminals.tab(pane.id, for: into))
    XCTAssertEqual(window.selectedTargetID, sidB)
  }

  /// Value: protects=a pane moved into the target it is already in stays put; fails_when=the move
  /// hands a tab off to its own target and loses it; why_new=#653; seam=AppStore; no_claim=none.
  func testAPaneMovedIntoItsOwnTargetStays() async throws {
    let window = makeWindow()
    let from = try target(window, sidA)
    let pane = window.terminals.addTab(for: from)

    await PaneMove.move(
      pane.id, of: from, source: window.terminals, notifications: registry.notifications,
      to: window, into: from.id)

    XCTAssertNotNil(window.terminals.tab(pane.id, for: from))
  }

  /// Value: protects=a window's own panes get Move to… choices that list every open workroom,
  /// its own included but disabled, and one moves the pane; fails_when=the builder answers only
  /// for the Quick Terminal; why_new=one builder for every source (#653); seam=AppStore;
  /// no_claim=menu rendering.
  func testAnyWindowsPaneGetsMoveChoices() async throws {
    let first = makeWindow()
    let second = makeWindow()
    let from = try target(first, sidA)
    let into = try target(second, sidB)
    let pane = first.terminals.addTab(for: from)
    _ = second.terminals.addTab(for: into)

    let groups = first.paneMoveChoices(
      pane.id, of: from, windows: [first, second], quickTerminal: nil)

    XCTAssertEqual(
      groups.map(\.choices.count), [2, 1, 1], "the Terminals section's, then each window's")
    XCTAssertEqual(groups[1].choices.map(\.enabled), [false], "its own target: nothing to move to")
    XCTAssertEqual(groups[2].choices.map(\.enabled), [true])
    groups[2].choices[0].move()
    for _ in 0..<50 where second.terminals.tab(pane.id, for: into) == nil { await Task.yield() }
    XCTAssertNotNil(second.terminals.tab(pane.id, for: into))
  }
}
