import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// A terminal's right-click New Terminal, splits and Close Terminal act on the pane clicked, in the
/// window that owns its tab (#583): a main window, a second main window, a detached pane's window
/// (owned by the main window its tab belongs to) and the Quick Terminal. They used to go to the key
/// window's store, which only main windows register, so from the Quick Terminal or a detached pane
/// they reached the last main window instead.
///
/// Most tests drive the menu item itself, as a click would, so the handler's own routing is what is
/// under test; the detached pane's refusals go through the event, since its menu has no such item.
@MainActor
final class PaneContextMenuRoutingTests: XCTestCase {
  private let shared = ProjectStore()
  /// The windows' one notification list (ADR 0064), which the Quick Terminal shares.
  private let registry = WindowRegistry()
  private let sid = SidebarID.workroom(project: "/p", name: "a")

  override func setUp() async throws {
    try await super.setUp()
    shared.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: shared, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    return store
  }

  private func target(_ store: AppStore) -> TerminalTarget { store.target(for: sid)! }

  /// A main window with two solo terminals in its workroom; the second, the last opened, is focused.
  private func makeWindow() -> (AppStore, TerminalTab, TerminalTab) {
    let store = makeStore()
    let t = target(store)
    let first = store.terminals.addTab(for: t)
    let second = store.terminals.addTab(for: t)
    return (store, first, second)
  }

  /// Choose `title` from `tab`'s right-click menu, then let the command run: it is deferred to the
  /// next runloop turn, after the menu closes.
  private func choose(
    _ title: String, on tab: TerminalTab, in panes: TerminalPanes,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let surface = panes.surface(tab) else {
      return XCTFail("no surface for \(tab.id)", file: file, line: line)
    }
    guard let item = surface.contextMenu().items.first(where: { $0.title == title }),
      let action = item.action
    else { return XCTFail("no \(title) in the menu", file: file, line: line) }
    XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), file: file, line: line)
    let ran = expectation(description: "the deferred command ran")
    DispatchQueue.main.async { ran.fulfill() }
    wait(for: [ran], timeout: 2)
  }

  // MARK: A main window

  /// Value: protects=New Terminal from a main window's pane opening a tab in that pane's workroom;
  /// fails_when=the command is sent anywhere but the pane's own window; why_new=the menu had no
  /// routing test; seam=contextMenu; no_claim=the right-click focusing the pane.
  func testNewTerminalOpensATabInTheClickedPanesWorkroom() {
    let (store, first, _) = makeWindow()

    choose("New Terminal", on: first, in: store.terminals)

    XCTAssertEqual(store.terminals.tabCount(forTargetID: target(store).id), 3)
  }

  /// Value: protects=a split from a main window's pane splitting that pane, not the focused one;
  /// fails_when=the split goes to another window or to the focused pane; why_new=as above;
  /// seam=contextMenu; no_claim=the split's sizes.
  func testSplitSplitsTheClickedPane() {
    let (store, first, second) = makeWindow()
    let t = target(store)

    choose("Split Right", on: first, in: store.terminals)

    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 3)
    XCTAssertNotNil(store.terminals.split(containing: first.id, for: t), "the clicked pane splits")
    XCTAssertNil(store.terminals.split(containing: second.id, for: t), "the focused one doesn't")
  }

  /// Value: protects=Close Terminal closing the pane clicked; fails_when=it closes another window's
  /// tab or the focused one; why_new=as above; seam=contextMenu; no_claim=the close confirm.
  func testCloseClosesTheClickedPane() {
    let (store, first, second) = makeWindow()
    let t = target(store)

    choose("Close Terminal", on: first, in: store.terminals)

    XCTAssertEqual(store.terminals.tabs(for: t).map(\.id), [second.id])
  }

  // MARK: A second main window

  /// Value: protects=New Terminal in a second window opening there and not in the other window;
  /// fails_when=the command goes to the key or last active window; why_new=#583's second route;
  /// seam=contextMenu; no_claim=which window is key.
  func testNewTerminalInASecondWindowLeavesTheOtherAlone() {
    let (other, _, _) = makeWindow()
    let (store, first, _) = makeWindow()

    choose("New Terminal", on: first, in: store.terminals)

    XCTAssertEqual(store.terminals.tabCount(forTargetID: target(store).id), 3)
    XCTAssertEqual(other.terminals.tabCount(forTargetID: target(other).id), 2)
  }

  /// Value: protects=a split in a second window splitting its own pane; fails_when=as above;
  /// why_new=as above; seam=contextMenu; no_claim=the split's sizes.
  func testSplitInASecondWindowLeavesTheOtherAlone() {
    let (other, otherFirst, _) = makeWindow()
    let (store, first, _) = makeWindow()

    choose("Split Down", on: first, in: store.terminals)

    XCTAssertNotNil(store.terminals.split(containing: first.id, for: target(store)))
    XCTAssertEqual(other.terminals.tabCount(forTargetID: target(other).id), 2)
    XCTAssertNil(other.terminals.split(containing: otherFirst.id, for: target(other)))
  }

  /// Value: protects=Close Terminal in a second window closing its own pane; fails_when=it closes
  /// the other window's tab; why_new=as above; seam=contextMenu; no_claim=the close confirm.
  func testCloseInASecondWindowLeavesTheOtherAlone() {
    let (other, _, _) = makeWindow()
    let (store, first, second) = makeWindow()

    choose("Close Terminal", on: first, in: store.terminals)

    XCTAssertEqual(store.terminals.tabs(for: target(store)).map(\.id), [second.id])
    XCTAssertEqual(other.terminals.tabCount(forTargetID: target(other).id), 2)
  }

  // MARK: A detached pane

  /// A main window with `first` docked and `second` popped out into its own window.
  private func makeWindowWithADetachedPane() -> (AppStore, TerminalTab, TerminalTab) {
    let (store, first, second) = makeWindow()
    store.terminals.surface(second)?.onEvent?(.windowToggleRequested)
    XCTAssertTrue(store.terminals.detachedTabIDs.contains(second.id))
    return (store, first, second)
  }

  /// Value: protects=a detached pane's window offering no New Terminal or split, as the menu bar
  /// disables them while one is key, and still offering Close Terminal; fails_when=the menu stops
  /// checking its window; why_new=#583 chose to match the menu bar; seam=contextMenu;
  /// no_claim=the menu's layout.
  func testADetachedPanesMenuOffersCloseButNoNewTerminalOrSplit() {
    let surface = GhosttySurfaceView(workingDirectory: "/tmp", spawnsSurface: false)
    let window = DetachedPaneWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(surface)
    defer { surface.removeFromSuperview() }

    let titles = surface.contextMenu().items.map(\.title)

    XCTAssertTrue(titles.contains("Close Terminal"))
    for title in ["New Terminal", "Split Right", "Split Left", "Split Down", "Split Up"] {
      XCTAssertFalse(titles.contains(title), "\(title) is offered in a detached pane's window")
    }
  }

  /// Value: protects=New Terminal raised by a detached pane doing nothing, in its owner window or
  /// any other, as ⌘T does there; fails_when=the owner opens a tab in its selected workroom;
  /// why_new=#583; seam=the surface's event; no_claim=the menu (the test above).
  func testNewTerminalFromADetachedPaneOpensNothing() {
    let (other, _, _) = makeWindow()
    let (store, _, detached) = makeWindowWithADetachedPane()
    defer { store.detachedPanes.closeAll() }

    store.terminals.surface(detached)?.onEvent?(.paneCommand(.newTerminal))

    XCTAssertEqual(store.terminals.tabCount(forTargetID: target(store).id), 2)
    XCTAssertEqual(other.terminals.tabCount(forTargetID: target(other).id), 2)
  }

  /// Value: protects=a split raised by a detached pane splitting nothing: not the owner's focused
  /// pane, which `splitTab` falls back to when it can't focus a detached tab; fails_when=the guard
  /// goes; why_new=#583; seam=the surface's event; no_claim=the menu (the test above).
  func testSplitFromADetachedPaneSplitsNothing() {
    let (other, otherFirst, _) = makeWindow()
    let (store, first, detached) = makeWindowWithADetachedPane()
    defer { store.detachedPanes.closeAll() }

    store.terminals.surface(detached)?.onEvent?(.paneCommand(.split(.right)))

    XCTAssertEqual(store.terminals.tabCount(forTargetID: target(store).id), 2)
    XCTAssertNil(store.terminals.split(containing: first.id, for: target(store)))
    XCTAssertTrue(store.terminals.detachedTabIDs.contains(detached.id), "it stays in its window")
    XCTAssertNil(other.terminals.split(containing: otherFirst.id, for: target(other)))
  }

  /// Value: protects=Close Terminal in a detached pane closing that pane, through its owner's close
  /// as its window's ⌘W does, and nothing in any other window; fails_when=the close goes to the
  /// last main window's focused tab; why_new=#583's detached route; seam=contextMenu;
  /// no_claim=the window closing with it.
  func testCloseInADetachedPaneClosesThatPane() {
    let (other, _, _) = makeWindow()
    let (store, first, detached) = makeWindowWithADetachedPane()
    defer { store.detachedPanes.closeAll() }

    choose("Close Terminal", on: detached, in: store.terminals)

    XCTAssertEqual(store.terminals.tabs(for: target(store)).map(\.id), [first.id])
    XCTAssertFalse(store.terminals.detachedTabIDs.contains(detached.id))
    XCTAssertEqual(other.terminals.tabCount(forTargetID: target(other).id), 2)
  }

  // MARK: The Quick Terminal

  private let quickTarget = QuickTerminalController.target()

  /// A Quick Terminal with two tabs, beside a main window with two of its own.
  private func makeQuickTerminal() -> (QuickTerminalHost, TerminalTab, TerminalTab, AppStore) {
    let host = makeQuickTerminalHost(notifications: registry.notifications)
    let first = host.terminals.addTab(for: quickTarget)
    let second = host.terminals.addTab(for: quickTarget)
    let (window, _, _) = makeWindow()
    return (host, first, second, window)
  }

  /// Value: protects=New Terminal in the Quick Terminal opening a tab there; fails_when=it opens
  /// one in a main window; why_new=#583's Quick Terminal route; seam=contextMenu; no_claim=the
  /// window showing it.
  func testNewTerminalInTheQuickTerminalOpensThere() {
    let (host, first, _, window) = makeQuickTerminal()

    choose("New Terminal", on: first, in: host.terminals)

    XCTAssertEqual(host.terminals.tabCount(forTargetID: quickTarget.id), 3)
    XCTAssertEqual(window.terminals.tabCount(forTargetID: target(window).id), 2)
  }

  /// Value: protects=a split in the Quick Terminal splitting the pane clicked there; fails_when=it
  /// splits a main window's pane; why_new=as above; seam=contextMenu; no_claim=the split's sizes.
  func testSplitInTheQuickTerminalSplitsTheClickedPane() {
    let (host, first, second, window) = makeQuickTerminal()

    choose("Split Left", on: first, in: host.terminals)

    XCTAssertNotNil(host.terminals.split(containing: first.id, for: quickTarget))
    XCTAssertNil(host.terminals.split(containing: second.id, for: quickTarget))
    XCTAssertEqual(window.terminals.tabCount(forTargetID: target(window).id), 2)
  }

  /// Value: protects=Close Terminal in the Quick Terminal closing the pane clicked there;
  /// fails_when=it closes a main window's focused tab, which may be running something;
  /// why_new=as above; seam=contextMenu; no_claim=the close confirm.
  func testCloseInTheQuickTerminalClosesTheClickedPane() {
    let (host, first, second, window) = makeQuickTerminal()

    choose("Close Terminal", on: first, in: host.terminals)

    XCTAssertEqual(host.terminals.tabs(for: quickTarget).map(\.id), [second.id])
    XCTAssertEqual(window.terminals.tabCount(forTargetID: target(window).id), 2)
  }
}
