import AppKit
import XCTest

@testable import Workroom

/// Multi-window foundations (issue #70): windows share one `ProjectStore` but keep independent
/// per-window `AppStore` state, and `WindowRegistry` tracks windows + aggregates their unread counts.
@MainActor
final class MultiWindowTests: XCTestCase {
  private func project(_ path: String, workrooms: [String] = []) -> Project {
    Project(
      path: path, vcs: "jj",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "jj", warnings: [])
      }
    )
  }

  private func notification(_ targetID: String) -> WorkroomNotification {
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
    XCTAssertEqual(a.projects.map(\.id), ["/p"])
    XCTAssertEqual(b.projects.map(\.id), ["/p"], "both windows read the one shared project list")

    a.selectedTargetID = .root(project: "/p")
    XCTAssertEqual(a.selectedTargetID, .root(project: "/p"))
    XCTAssertNil(b.selectedTargetID, "selection is per-window, not shared")
  }

  func testProxyWritesThroughToSharedStore() {
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)

    a.projects = [project("/x")]
    XCTAssertEqual(
      shared.projects.map(\.id), ["/x"], "writing via one window updates the shared store")
    XCTAssertEqual(b.projects.map(\.id), ["/x"], "…and is visible to the other window")
  }

  func testIsolatedStoresDoNotShareProjects() {
    let a = AppStore()  // default: its own fresh ProjectStore
    let b = AppStore()
    a.projects = [project("/only-a")]
    XCTAssertTrue(
      b.projects.isEmpty, "bare AppStore() is isolated, so tests never pollute each other")
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

  func testRegistryAggregatesUnreadAcrossWindows() {
    let registry = WindowRegistry()
    let a = AppStore(projectStore: ProjectStore())
    let b = AppStore(projectStore: ProjectStore())
    registry.register(window: NSWindow(), store: a)
    registry.register(window: NSWindow(), store: b)

    a.notifications.seedForTesting([notification("t1")])
    b.notifications.seedForTesting([notification("t2"), notification("t3")])
    registry.recomputeBadge()

    XCTAssertEqual(
      registry.aggregateUnread, 3, "the badge/menu-bar count sums every window's unread")
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

  // MARK: Window-close guard (A3)

  func testCloseGuardAllowsCloseWithoutRunCommand() {
    let store = AppStore(projectStore: ProjectStore())
    let guardDelegate = WindowCloseGuard(store: store, forwarding: nil)
    XCTAssertFalse(store.hasLiveRunCommand, "no run command in a fresh store")
    XCTAssertTrue(
      guardDelegate.windowShouldClose(NSWindow()),
      "with no live run command the window closes immediately — no confirm, no stop")
  }

  // New-window sizing (issue #70) opens a window at the current window's size from the first frame
  // (RootWindow's idealWidth/Height ← WindowRegistry.preferredNewWindowContentSize). It reads live
  // NSWindows from the shared registry — which the unit-test host app itself populates with a window —
  // so it isn't cleanly unit-testable; it's verified live (no open-small-then-resize flash).
}
