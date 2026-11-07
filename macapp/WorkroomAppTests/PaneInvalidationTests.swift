import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// Pane state is observed per target (plan step 3.5): a change to one workroom's tabs re-runs the
/// views that read that workroom and no others. When the views held the window's whole
/// `TerminalPanes` as an `ObservableObject`, an agent working in one workroom re-ran every
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

  /// No sessions, and an inert surface, so nothing spawns.
  private func makeInert(_ store: AppStore) {
    store.terminals.sessionService = isolatedPaneSessionService()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
  }

  private func fixture() throws -> Fixture {
    let store = AppStore()
    makeInert(store)
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
        .invalidationEnvironment(store)
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
  private func settleRendering(_ window: NSWindow) async throws {
    try await Task.sleep(for: .milliseconds(150))
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
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
    try await settleRendering(f.window)
    resetPasses()

    try await agentStartsWorking(on: f.surfaceA)
    try await settleRendering(f.window)

    XCTAssertTrue(
      f.store.terminals.isRunning(forTargetID: f.a.id), "workroom A's change landed")
    XCTAssertEqual(
      TerminalTabStrip.bodyPasses, 0, "workroom A's pane change re-ran workroom B's tab strip")
    XCTAssertEqual(
      PaneTitleBar.bodyPasses, 0, "workroom A's pane change re-ran workroom B's pane title bar")
  }

  // MARK: Two windows (step 3.9)

  /// What RootView computes for ⌥Tab's menu item, across every window (`canSwitchWorkrooms`),
  /// counted. RootView itself needs the whole app around it; this is the one cross-window read in
  /// its body.
  private struct SwitcherEnablementProbe: View {
    static var bodyPasses = 0
    let registry: WindowRegistry

    var body: some View {
      Self.bodyPasses += 1
      return Text(QuickSwitcher.canSwitchWorkrooms(registry: registry) ? "switch" : "stay")
    }
  }

  private struct TwoWindows {
    let registry: WindowRegistry
    let one: AppStore
    let two: AppStore
    let a: TerminalTarget
    let b: TerminalTarget
    let surfaceA: GhosttySurfaceView
    let windows: [NSWindow]
  }

  /// Window one holds workroom A, window two holds workroom B and draws its terminals and the
  /// switcher's enablement, as RootView would.
  private func twoWindows() throws -> TwoWindows {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pane-invalidation-\(UUID().uuidString)")
    let paths = ["a", "b"].map { root.appendingPathComponent($0).path }
    let projects = ProjectStore()
    projects.projects = paths.map { Project(path: $0, vcs: "git", workrooms: []) }
    let stores = [AppStore(projectStore: projects), AppStore(projectStore: projects)]
    for store in stores { makeInert(store) }
    let a = try XCTUnwrap(stores[0].target(for: .root(project: paths[0])))
    let b = try XCTUnwrap(stores[1].target(for: .root(project: paths[1])))
    let surfaceA = try XCTUnwrap(stores[0].terminals.surface(stores[0].terminals.addTab(for: a)))
    _ = stores[1].terminals.addTab(for: b)

    let registry = WindowRegistry()
    let frame = NSRect(x: 100, y: 100, width: 900, height: 600)
    let windows = stores.map { _ in
      let window = NSWindow(
        contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      return window
    }
    // Before the view is made: its first body pass is what subscribes to every window's reads.
    for (window, store) in zip(windows, stores) { registry.register(window: window, store: store) }
    let hosting = NSHostingView(
      rootView: VStack {
        SwitcherEnablementProbe(registry: registry)
        WorkroomTerminalsView(target: b, sessions: stores[1].terminals)
      }
      .invalidationEnvironment(stores[1])
      .frame(width: 900, height: 600))
    hosting.frame = frame
    windows[1].contentView = hosting
    windows[1].orderFront(nil)
    return TwoWindows(
      registry: registry, one: stores[0], two: stores[1], a: a, b: b, surfaceA: surfaceA,
      windows: windows)
  }

  /// An agent working in window one's workroom re-runs nothing in window two: not its tab strip
  /// or pane title bar (each tab's record is its own, wherever the tab is, D4), and not the
  /// switcher enablement it reads across every window, which asks only whether each workroom has
  /// tabs (F1 of step 3.5's review).
  func testAnotherWindowsPaneChangeReRunsNoViewOfThisWindow() async throws {
    let f = try twoWindows()
    defer {
      for window in f.windows { window.close() }
      Task {
        await f.one.terminals.reapAll()
        await f.two.terminals.reapAll()
      }
    }
    f.windows[1].contentView?.layoutSubtreeIfNeeded()
    f.windows[1].displayIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    f.windows[1].displayIfNeeded()
    XCTAssertTrue(
      QuickSwitcher.canSwitchWorkrooms(registry: f.registry), "two workrooms, two windows")
    XCTAssertGreaterThan(SwitcherEnablementProbe.bodyPasses, 0, "the probe drew")
    resetPasses()
    SwitcherEnablementProbe.bodyPasses = 0

    try await agentStartsWorking(on: f.surfaceA)
    try await settleRendering(f.windows[1])

    XCTAssertTrue(f.one.terminals.isRunning(forTargetID: f.a.id), "window one's change landed")
    XCTAssertEqual(
      TerminalTabStrip.bodyPasses, 0, "window one's pane change re-ran window two's tab strip")
    XCTAssertEqual(
      PaneTitleBar.bodyPasses, 0, "window one's pane change re-ran window two's pane title bar")
    XCTAssertEqual(
      SwitcherEnablementProbe.bodyPasses, 0,
      "window one's pane change re-ran window two's cross-window menu enablement")
  }

  /// The positive half for the cross-window read: window one's workroom losing its last terminal
  /// is what the switcher's answer depends on, so window two hears that.
  func testAnotherWindowLosingItsWorkroomReRunsTheSwitcherEnablement() async throws {
    let f = try twoWindows()
    defer {
      for window in f.windows { window.close() }
      Task {
        await f.one.terminals.reapAll()
        await f.two.terminals.reapAll()
      }
    }
    f.windows[1].contentView?.layoutSubtreeIfNeeded()
    f.windows[1].displayIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    f.windows[1].displayIfNeeded()
    SwitcherEnablementProbe.bodyPasses = 0

    f.one.terminals.closeTab(
      try XCTUnwrap(f.one.terminals.tabs(for: f.a).first).id, for: f.a)
    try await settleRendering(f.windows[1])

    XCTAssertFalse(QuickSwitcher.canSwitchWorkrooms(registry: f.registry))
    XCTAssertGreaterThan(
      SwitcherEnablementProbe.bodyPasses, 0,
      "window one's workroom losing its last terminal must re-run window two's enablement")
  }

  /// The positive half: the same change in the workroom the view shows still re-runs it, so the
  /// test above is not passing on a view that never updates.
  func testThisWorkroomsPaneChangeStillReRunsItsViews() async throws {
    let f = try fixture()
    defer {
      f.window.close()
      Task { await f.store.terminals.reapAll() }
    }
    try await settleRendering(f.window)
    resetPasses()

    try await agentStartsWorking(on: f.surfaceB)
    try await settleRendering(f.window)

    XCTAssertTrue(f.store.terminals.isRunning(forTargetID: f.b.id))
    XCTAssertGreaterThan(
      TerminalTabStrip.bodyPasses, 0, "workroom B's own pane change must re-run its tab strip")
  }
}

extension View {
  /// What the terminals view reads from its environment, and nothing more: the counts above are
  /// of these views' passes alone (`detachedPaneEnvironment` would add the usage monitor too). The
  /// theme is injected as every production root injects it.
  fileprivate func invalidationEnvironment(_ store: AppStore) -> some View {
    environmentObject(store)
      .paneHost(store)
      .environmentObject(store.modals)
      .environmentObject(store.runCommand)
      .environmentObject(store.notifications)
      .environmentObject(store.terminals.codingAgentManager)
      .themeTokensRoot()
  }
}
