import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// Pane state is observed per target (plan step 3.5): a change to one workroom's tabs re-runs the
/// views that read that workroom and no others. When the views held the window's whole
/// `TerminalSessions` as an `ObservableObject`, an agent working in one workroom re-ran every
/// workroom's strip and panes in the window, and the app-wide tab registry (step 3.9) would have
/// carried that to every window (the WORKROOM-2B class, ADR 0018).
///
/// The real terminals view, with an inert surface, for workroom B, while workroom A's terminal
/// reports progress and a recognised agent: what a working agent does many times a minute.
@MainActor
final class PaneInvalidationTests: XCTestCase {
  private struct Fixture {
    let store: AppStore
    let a: TerminalTarget
    let b: TerminalTarget
    let surfaceA: GhosttySurfaceView
    let surfaceB: GhosttySurfaceView
    let window: NSWindow
  }

  private func fixture() throws -> Fixture {
    let store = AppStore()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "no sessions in invalidation fixture") },
      ownership: { _ in .notOwned })
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pane-invalidation-\(UUID().uuidString)")
    let paths = ["a", "b"].map { root.appendingPathComponent($0).path }
    store.projectStore.projects = paths.map { Project(path: $0, vcs: "git", workrooms: []) }
    let a = try XCTUnwrap(store.target(for: .root(project: paths[0])))
    let b = try XCTUnwrap(store.target(for: .root(project: paths[1])))
    let surfaceA = try XCTUnwrap(store.terminals.surface(store.terminals.addTab(for: a)))
    let surfaceB = try XCTUnwrap(store.terminals.surface(store.terminals.addTab(for: b)))
    let hosting = NSHostingView(
      rootView: WorkroomTerminalsView(target: b, sessions: store.terminals)
        .environmentObject(store)
        .environmentObject(store.modals)
        .environmentObject(store.runCommand)
        .environmentObject(store.notifications)
        .environmentObject(store.terminals.codingAgentManager)
        .frame(width: 900, height: 600))
    hosting.frame = NSRect(x: 100, y: 100, width: 900, height: 600)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    return Fixture(
      store: store, a: a, b: b, surfaceA: surfaceA, surfaceB: surfaceB, window: window)
  }

  /// Lets SwiftUI run any update the changes scheduled.
  private func settleRendering(_ f: Fixture) async throws {
    try await Task.sleep(for: .milliseconds(150))
    f.window.contentView?.layoutSubtreeIfNeeded()
    f.window.displayIfNeeded()
  }

  /// Report what a working agent reports: OSC 9;4 progress, then a title naming a known agent.
  private func agentStartsWorking(on surface: GhosttySurfaceView) async throws {
    surface.handleProgressReport(true)
    try await Task.sleep(for: .milliseconds(50))
    surface.foregroundProcessNameForTesting = "codex"
    surface.handleTitleChange("Codex")
  }

  private func resetPasses() {
    TerminalTabStrip.bodyPasses = 0
    PaneTitleBar.bodyPasses = 0
  }

  func testAnotherWorkroomsPaneChangeReRunsNoViewOfThisOne() async throws {
    let f = try fixture()
    defer {
      f.window.close()
      Task { await f.store.terminals.reapAll() }
    }
    try await settleRendering(f)
    resetPasses()

    try await agentStartsWorking(on: f.surfaceA)
    try await settleRendering(f)

    XCTAssertTrue(
      f.store.terminals.isRunning(forTargetID: f.a.id), "workroom A's change landed")
    XCTAssertEqual(
      TerminalTabStrip.bodyPasses, 0, "workroom A's pane change re-ran workroom B's tab strip")
    XCTAssertEqual(
      PaneTitleBar.bodyPasses, 0, "workroom A's pane change re-ran workroom B's pane title bar")
  }

  /// The positive half: the same change in the workroom the view shows still re-runs it, so the
  /// test above is not passing on a view that never updates.
  func testThisWorkroomsPaneChangeStillReRunsItsViews() async throws {
    let f = try fixture()
    defer {
      f.window.close()
      Task { await f.store.terminals.reapAll() }
    }
    try await settleRendering(f)
    resetPasses()

    try await agentStartsWorking(on: f.surfaceB)
    try await settleRendering(f)

    XCTAssertTrue(f.store.terminals.isRunning(forTargetID: f.b.id))
    XCTAssertGreaterThan(
      TerminalTabStrip.bodyPasses, 0, "workroom B's own pane change must re-run its tab strip")
  }
}
