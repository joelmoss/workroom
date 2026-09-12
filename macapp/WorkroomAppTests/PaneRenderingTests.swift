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
    s.recency = SwitcherRecency()  // never write this suite's tabs into the shared MRU
    return s
  }

  /// Host the content (the same layout decision `WorkroomTerminalsView` makes) in a window.
  private func host(_ sessions: TerminalSessions) -> (NSWindow, NSView) {
    let root = TestPaneHost(target: target, sessions: sessions)
      .environmentObject(AppStore())
      .environmentObject(sessions.agentManager)
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

  /// Poll until `expected` is the surface mounted in `view`, and return whether it got there.
  ///
  /// Waiting on the COUNT is not enough when the count does not change: docking swaps which surface
  /// the origin shows while the total stays at one, so `waitForSurfaces(count: 1)` is already
  /// satisfied before the swap and can return the OLD surface. That is what failed on CI while
  /// passing locally — the same "wait for a value the shape already has" trap as a vacuous assertion,
  /// just in the polling predicate instead.
  @discardableResult
  private func waitForSurface(
    _ expected: GhosttySurfaceView?, in view: NSView, timeout: TimeInterval = 3
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      view.layoutSubtreeIfNeeded()
      let mounted = mountedSurfaces(in: view)
      if mounted.count == 1, mounted.first === expected { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    view.layoutSubtreeIfNeeded()
    let mounted = mountedSurfaces(in: view)
    return mounted.count == 1 && mounted.first === expected
  }

  /// Whether `needle` is anywhere in `haystack`'s view tree (regardless of window attachment).
  private func contains(_ haystack: NSView, _ needle: NSView?) -> Bool {
    guard let needle else { return false }
    var node: NSView? = needle
    while let current = node {
      if current === haystack { return true }
      node = current.superview
    }
    return false
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

  // MARK: Detaching (issue #172) — the origin must LET GO of the surface

  /// Detaching a pane unmounts it from the origin tree, and — the part that matters — the surface is
  /// still alive and unowned, ready for the detached window to adopt.
  ///
  /// This is the handoff half of the blank-pane class: `TerminalContainerView.mount` re-homes a
  /// surface between containers by design, so the failure mode is not "the view dies" but "both hosts
  /// think they own it". A tab the origin still rendered would drag the surface straight back out of
  /// the detached window.
  func testDetachingUnmountsThePaneFromTheOriginTree() {
    let s = makeSessions()
    let stay = s.addTab(for: target)
    // `splitFocusedPane` mints the second pane, so the split is (stay | detached).
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let detached = s.focusedTab(for: target)!.id
    let (window, view) = host(s)
    defer {
      window.orderOut(nil)
      window.close()
    }
    XCTAssertEqual(waitForSurfaces(in: view, count: 2).count, 2)

    s.detachPane(detached, for: target, at: .zero)

    let mounted = waitForSurfaces(in: view, count: 1)
    XCTAssertEqual(mounted.count, 1, "the origin renders only the pane it still owns")
    XCTAssertNotNil(
      s.tab(detached, for: target)?.surface,
      "the detached tab keeps its surface — it moved windows, it did not die")
    XCTAssertEqual(
      s.tab(stay.id, for: target)?.surface, mounted.first,
      "and the one still mounted is the one that stayed")

  }

  /// The blank-detached-pane regression (issue #172), which needs BOTH hosts alive to reproduce.
  ///
  /// Popping a pane out mounts it in the detached window while the origin tree still has one update
  /// pass queued, and `updateNSView` re-homes unconditionally — so the origin re-adopted the surface
  /// and then took it down with its own container, leaving it in no window at all. The pane's chrome
  /// (SwiftUI) still drew, so it looked like a rendering bug rather than an ownership one.
  ///
  /// `mountedSurfaces` cannot see this: a stranded surface has no window either. What settles it is
  /// WHICH window ends up holding the view.
  func testADetachedPaneEndsUpInTheDetachedWindowNotTheOrigin() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let detached = s.focusedTab(for: target)!.id
    let surface = s.tab(detached, for: target)!.surface!

    let (origin, originView) = host(s)
    defer {
      origin.orderOut(nil)
      origin.close()
    }
    XCTAssertEqual(waitForSurfaces(in: originView, count: 2).count, 2)

    // Stand in for `DetachedPaneWindows`: a second window hosting the same surface under the same
    // model-driven gate the real detached window uses.
    let detachedHost = NSHostingView(
      rootView: TestDetachedHost(tabID: detached, surface: surface, sessions: s))
    detachedHost.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let detachedWindow = NSWindow(
      contentRect: detachedHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
    detachedWindow.isReleasedWhenClosed = false
    defer {
      detachedWindow.orderOut(nil)
      detachedWindow.close()
    }

    s.detachPane(detached, for: target, at: .zero)
    detachedWindow.contentView = detachedHost
    detachedWindow.makeKeyAndOrderFront(nil)

    // Let BOTH trees settle — the origin's trailing update pass is the one that used to steal it.
    for _ in 0..<10 {
      originView.layoutSubtreeIfNeeded()
      detachedHost.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    XCTAssertTrue(
      contains(detachedHost, surface),
      "the detached window must end up holding the surface")
    XCTAssertFalse(
      contains(originView, surface),
      "and the origin must not have re-adopted it on its trailing update pass")
    XCTAssertNotNil(surface.window, "a surface in no window renders nothing — the blank-pane bug")
  }

  /// Docking is the mirror: the pane comes back into the origin tree and is mounted again, with no
  /// second surface created for it.
  func testDockingRemountsThePaneInTheOriginTree() {
    let s = makeSessions()
    s.addTab(for: target)
    let second = s.addTab(for: target)
    let surface = s.tab(second.id, for: target)?.surface
    s.detachPane(second.id, for: target, at: .zero)
    let (window, view) = host(s)
    defer {
      window.orderOut(nil)
      window.close()
    }
    XCTAssertEqual(waitForSurfaces(in: view, count: 1).count, 1)

    s.dockPane(second.id, for: target)

    XCTAssertTrue(
      waitForSurface(surface, in: view),
      "the SAME surface came back, alone — nothing was respawned")
  }
}

/// Stands in for `DetachedPaneView`: hosts one surface under the same model-driven ownership gate,
/// so the two-host tug of war can be reproduced without building a real detached window.
private struct TestDetachedHost: View {
  let tabID: TerminalTab.ID
  let surface: GhosttySurfaceView
  @ObservedObject var sessions: TerminalSessions

  var body: some View {
    TerminalContainerView(
      view: surface, isFocusedPane: true,
      mayHostSurface: sessions.detachedTabIDs.contains(tabID))
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
