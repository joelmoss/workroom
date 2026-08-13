import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// View-layer harness for splits (issue #3). Hosts the real pane renderer in an off-screen `NSWindow`
/// and inspects the AppKit hierarchy after driving the model — so it verifies what unit tests on the
/// model can't: that the right terminal surfaces are actually **mounted in the window** with sensible
/// frames after split / close / focus changes.
///
/// This is the regression net for the close-a-split-pane blank bug: that bug left the surviving
/// surface in a detached container (no window) at the wrong size. Counting window-mounted
/// `GhosttySurfaceView`s here catches exactly that. Runs in the normal `make app-test` gate (no UI-
/// automation entitlement needed — unlike XCUITest, which the CI/dev machine must be granted).
@MainActor
final class PaneRenderingTests: XCTestCase {
  private let target = TerminalTarget(
    id: "wr|/p|panes", title: "panes", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalSessions {
    let s = TerminalSessions()
    // Mount real `GhosttySurfaceView`s (so the AppKit hierarchy assertions below are meaningful) but
    // with `spawnsSurface: false` — no libghostty Metal renderer / login shell. Hosting live surfaces
    // in the headless CI unit-test host crashed XCTest's post-test memory checker on teardown; the
    // view-mount/layout path this suite verifies needs no live surface.
    s.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false) }
    return s
  }

  /// Host the content (the same layout decision `WorkroomTerminalsView` makes) in a window.
  private func host(_ sessions: TerminalSessions) -> (NSWindow, NSView) {
    let root = TestPaneHost(target: target, sessions: sessions)
      .environmentObject(AppStore())
      .environmentObject(sessions.agentManager)
      // `TerminalStatusBar` reads this too (issue #145). A missing `@EnvironmentObject` is a fatal
      // crash at render, not a nil — so every view test that mounts a pane has to supply it.
      .environmentObject(sessions.resumeCoordinator)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // ARC owns `window`; a programmatic NSWindow defaults `isReleasedWhenClosed` to true, so the
    // `window.close()` in each test's `defer` would send a second release on top of ARC's — an
    // over-release that corrupts the heap. Opt out so ARC is the sole owner.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  /// All `GhosttySurfaceView`s under `view` that are actually attached to a window (i.e. rendered).
  private func mountedSurfaces(in view: NSView) -> [GhosttySurfaceView] {
    var found: [GhosttySurfaceView] = []
    func walk(_ v: NSView) {
      if let s = v as? GhosttySurfaceView, s.window != nil { found.append(s) }
      v.subviews.forEach(walk)
    }
    walk(view)
    return found
  }

  /// Poll the runloop until SwiftUI commits and the mounted-surface count settles to `expected`.
  @discardableResult
  private func waitForSurfaces(in view: NSView, count expected: Int, timeout: TimeInterval = 3)
    -> [GhosttySurfaceView]
  {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      view.layoutSubtreeIfNeeded()
      if mountedSurfaces(in: view).count == expected { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    view.layoutSubtreeIfNeeded()
    return mountedSurfaces(in: view)
  }

  func testSoloRendersOnePane() {
    let s = makeSessions()
    s.addTab(for: target)
    let (window, view) = host(s)
    defer {
      Task { await s.reapAll() }
      window.close()
    }  // free surfaces so their render threads stop
    XCTAssertEqual(waitForSurfaces(in: view, count: 1).count, 1)
  }

  func testSplitRendersTwoPanes() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let (window, view) = host(s)
    defer {
      Task { await s.reapAll() }
      window.close()
    }  // free surfaces so their render threads stop
    XCTAssertEqual(waitForSurfaces(in: view, count: 2).count, 2)
  }

  /// The regression: closing one pane of a split must leave the survivor mounted and full-size — not
  /// stranded in a detached container (the blank bug).
  func testClosingSplitPaneKeepsSurvivorMountedFullSize() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let (window, view) = host(s)
    defer {
      Task { await s.reapAll() }
      window.close()
    }  // free surfaces so their render threads stop
    XCTAssertEqual(waitForSurfaces(in: view, count: 2).count, 2)

    let focused = s.focusedTab(for: target)!.id  // the new split pane
    s.closeTab(focused, for: target)

    let survivors = waitForSurfaces(in: view, count: 1)
    XCTAssertEqual(survivors.count, 1, "exactly one survivor pane should remain mounted")
    XCTAssertGreaterThan(
      survivors.first?.bounds.width ?? 0, 300,
      "the survivor should fill the pane, not be collapsed or detached")
  }

  func testNestedSplitRendersThreePanes() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    s.splitFocusedPane(for: target, orientation: .vertical)  // [a, (b, c)]
    let (window, view) = host(s)
    defer {
      Task { await s.reapAll() }
      window.close()
    }  // free surfaces so their render threads stop
    XCTAssertEqual(waitForSurfaces(in: view, count: 3).count, 3)
  }

  /// Focusing a solo tab while a split exists shows only that tab (the split is hidden).
  func testFocusingSoloTabHidesSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b] visible
    let solo = s.addTab(for: target).id  // C solo, focused → split hidden
    let (window, view) = host(s)
    defer {
      Task { await s.reapAll() }
      window.close()
    }  // free surfaces so their render threads stop
    let mounted = waitForSurfaces(in: view, count: 1)
    XCTAssertEqual(mounted.count, 1, "only the focused solo tab should be mounted")
    _ = solo
  }

  /// Extracting a pane out of a split shows just the extracted tab (solo); the rest of the split hides.
  func testExtractingPaneMountsOnlyTheExtractedTab() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b], b focused
    let (window, view) = host(s)
    defer {
      Task { await s.reapAll() }
      window.close()
    }
    XCTAssertEqual(waitForSurfaces(in: view, count: 2).count, 2)

    let b = s.focusedTab(for: target)!.id
    s.extractFromSplit(b, for: target)  // b → solo + focused
    XCTAssertEqual(waitForSurfaces(in: view, count: 1).count, 1)
  }
}

/// Mirrors `WorkroomTerminalsView`'s content decision (split when visible, else the focused solo tab)
/// so the harness drives the exact rendering path that produced the blank bug.
private struct TestPaneHost: View {
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions

  var body: some View {
    if let active = sessions.activeTab(for: target) {
      PaneTreeView(
        layout: sessions.isSplitVisible(for: target)
          ? (sessions.split(for: target) ?? .leaf(active.id)) : .leaf(active.id),
        target: target, sessions: sessions
      )
    }
  }
}
