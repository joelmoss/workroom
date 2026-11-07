import Carbon.HIToolbox
import DaemonConnection
import Defaults
import WorkroomDomain
import XCTest

@testable import Workroom

/// The quick-terminal lifecycle (issue #39): ABSENT → summon a fresh ~/ window, hide keeps the
/// surface alive across a re-summon, and a close fully tears it down so the next summon is fresh.
/// Surfaces are injected non-spawning (`spawnsSurface: false`) so no real PTY / Metal renderer is
/// created — mounting and tearing one down is unsafe in the headless test host.
@MainActor
final class QuickTerminalControllerTests: XCTestCase {
  private func makeController(
    backendPrepared: Bool = true, backend: SessionBackendAvailability = .notBundled
  ) -> QuickTerminalController {
    let controller = QuickTerminalController()
    controller.makeSurface = {
      GhosttySurfaceView(workingDirectory: $0, command: $1, spawnsSurface: false)
    }
    // No real background helper (a test surface never attaches); its first health check answered
    // already, unless a test waits on it.
    let service = PersistentSessionService(
      probe: { _ in backend }, ownership: { _ in .notOwned })
    if backendPrepared { _ = service.backend }
    controller.sessionServiceOverride = service
    // Key focus moves under the test host's feet; only the focus test opts in.
    controller.hidesWhenUnfocused = { false }
    return controller
  }

  /// Value: protects=a summon during startup waiting for the session backend, so its first pane gets
  /// a session (#573, O2); fails_when=the pane is created before the health check answers;
  /// why_new=new path; seam=sessionServiceOverride (production caller: none, tests only, like
  /// makeSurface); no_claim=a real daemon probe.
  func testASummonBeforeTheBackendIsReadyWaitsForIt() async {
    let controller = makeController(backendPrepared: false)
    defer { controller.close() }

    controller.toggle()
    XCTAssertFalse(controller.hasWindow, "no pane before the backend answers")
    for _ in 0..<200 where !controller.hasWindow { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(controller.hasWindow, "it opens once the backend answered")
    XCTAssertTrue(controller.isVisible)
  }

  func testFirstTabOpensInTheSettingsFolder() throws {
    // The real app path: the first shell starts in the Settings folder, ~/ while it is unset.
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    XCTAssertEqual(
      try XCTUnwrap(controller.currentSurface).workingDirectory,
      QuickTerminalController.workingDirectory(for: Defaults[.quickTerminalDirectory]))
  }

  /// Pure, so no shared `Defaults` write races the parallel test workers.
  func testWorkingDirectoryFollowsSettingElseHome() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("file")
    try Data().write(to: file)

    XCTAssertEqual(QuickTerminalController.workingDirectory(for: ""), NSHomeDirectory())
    XCTAssertEqual(QuickTerminalController.workingDirectory(for: folder.path), folder.path)
    XCTAssertEqual(QuickTerminalController.workingDirectory(for: "~"), NSHomeDirectory())
    XCTAssertEqual(
      QuickTerminalController.workingDirectory(for: folder.appendingPathComponent("gone").path),
      NSHomeDirectory(), "a folder that is gone falls back to home")
    XCTAssertEqual(
      QuickTerminalController.workingDirectory(for: file.path), NSHomeDirectory(),
      "a file is not a folder")
  }

  /// A 1000×800 visible frame inside a 1000×1000 screen (menu bar + Dock taken out).
  private let screen = NSRect(x: 0, y: 0, width: 1000, height: 1000)
  private let visible = NSRect(x: 0, y: 100, width: 1000, height: 800)
  private let size = NSSize(width: 400, height: 200)

  func testDockedFrameHugsEachEdgeCentredAlongIt() {
    XCTAssertEqual(
      QuickTerminalEdge.top.dockedFrame(size: size, in: visible),
      NSRect(x: 300, y: 700, width: 400, height: 200))
    XCTAssertEqual(
      QuickTerminalEdge.bottom.dockedFrame(size: size, in: visible),
      NSRect(x: 300, y: 100, width: 400, height: 200))
    XCTAssertEqual(
      QuickTerminalEdge.left.dockedFrame(size: size, in: visible),
      NSRect(x: 0, y: 400, width: 400, height: 200))
    XCTAssertEqual(
      QuickTerminalEdge.right.dockedFrame(size: size, in: visible),
      NSRect(x: 600, y: 400, width: 400, height: 200))
  }

  func testDockedFrameShrinksToFitTheScreen() {
    XCTAssertEqual(
      QuickTerminalEdge.top.dockedFrame(size: NSSize(width: 2000, height: 900), in: visible),
      visible)
  }

  func testDockedFrameSitsAtItsOffsetAlongTheEdge() {
    XCTAssertEqual(
      QuickTerminalEdge.top.dockedFrame(size: size, in: visible, offset: 0.25),
      NSRect(x: 50, y: 700, width: 400, height: 200))
    XCTAssertEqual(
      QuickTerminalEdge.right.dockedFrame(size: size, in: visible, offset: 0.75),
      NSRect(x: 600, y: 600, width: 400, height: 200), "along the side, 0 is the bottom")
    XCTAssertEqual(
      QuickTerminalEdge.top.dockedFrame(size: size, in: visible, offset: 0).minX, 0,
      "an offset past the end still keeps it on the screen")
    XCTAssertEqual(
      QuickTerminalEdge.bottom.dockedFrame(size: size, in: visible, offset: 1).maxX, 1000)
  }

  func testDragDocksToTheEdgeNearestTheWindowsCentre() {
    func nearest(_ x: CGFloat, _ y: CGFloat, current: QuickTerminalEdge? = nil) -> QuickTerminalEdge
    {
      QuickTerminalEdge.nearest(
        forCenter: NSPoint(x: x, y: y), size: size, in: visible, current: current)
    }
    XCTAssertEqual(nearest(500, 780), .top)
    XCTAssertEqual(nearest(500, 120), .bottom)
    XCTAssertEqual(nearest(210, 450), .left)
    XCTAssertEqual(nearest(790, 450), .right)
    XCTAssertEqual(nearest(500, 500), .top, "a four-way tie breaks the same way every time")
    XCTAssertEqual(nearest(505, 500), .right)
    XCTAssertEqual(
      nearest(505, 500, current: .left), .left,
      "just past the line, it stays on its edge rather than flicker")
    XCTAssertEqual(nearest(600, 500, current: .left), .right, "well past it, it hops")
  }

  /// Value: protects=a drag docks on the screen under the pointer, picking the edge from where the
  /// pointer less its grab puts the window's centre; fails_when=the grab is not subtracted, the
  /// frame is not the edge's docked frame, or a pointer off every screen has no fallback;
  /// why_new=`dragDock` is new and `nearest` alone does not cover its wiring; seam=none;
  /// no_claim=the glide between edges.
  func testADragDocksFromWhereTheGrabPutsTheWindowsCentre() throws {
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let area = screen.visibleFrame
    let size = NSSize(width: 400, height: 200)
    let pointer = NSPoint(x: area.midX, y: area.minY + 100)

    let low = try XCTUnwrap(
      QuickTerminalController.dragDock(
        size: size, pointer: pointer, grab: .zero, current: .top, fallback: nil))
    XCTAssertEqual(low.edge, .bottom)
    XCTAssertEqual(low.frame, low.edge.dockedFrame(size: size, in: area, offset: low.offset))

    let grabbedLow = NSPoint(x: 0, y: 100 - (area.height - 100))
    let high = try XCTUnwrap(
      QuickTerminalController.dragDock(
        size: size, pointer: pointer, grab: grabbedLow, current: .bottom, fallback: nil))
    XCTAssertEqual(high.edge, .top, "the pointer is low, but the window's centre is high")

    let nowhere = NSPoint(x: -1e6, y: -1e6)
    XCTAssertNil(
      QuickTerminalController.dragDock(
        size: size, pointer: nowhere, grab: .zero, current: .top, fallback: nil))
    XCTAssertNotNil(
      QuickTerminalController.dragDock(
        size: size, pointer: nowhere, grab: .zero, current: .top, fallback: screen))
  }

  func testOffsetRoundTripsThroughDockedFrame() {
    for edge in QuickTerminalEdge.allCases {
      let docked = edge.dockedFrame(size: size, in: visible, offset: 0.3)
      let offset = edge.offset(
        forCenter: NSPoint(x: docked.midX, y: docked.midY), size: size, in: visible)
      XCTAssertEqual(offset, 0.3, accuracy: 0.0001, "\(edge)")
    }
    XCTAssertEqual(
      QuickTerminalEdge.top.offset(forCenter: NSPoint(x: -500, y: 0), size: size, in: visible),
      0.2, accuracy: 0.0001, "clamped where the window's end meets the screen's")
    XCTAssertEqual(
      QuickTerminalEdge.top.offset(
        forCenter: .zero, size: NSSize(width: 1000, height: 200), in: visible), 0.5,
      "a window as wide as the screen has nowhere to slide")
  }

  func testHiddenFrameSitsJustPastTheEdge() {
    for edge in QuickTerminalEdge.allCases {
      let docked = edge.dockedFrame(size: size, in: visible)
      let hidden = edge.hiddenFrame(docked: docked, screen: screen)
      XCTAssertFalse(hidden.intersects(screen), "\(edge) starts fully off-screen")
      XCTAssertEqual(hidden.size, docked.size, "\(edge) slides, never resizes")
      switch edge {
      case .top, .bottom: XCTAssertEqual(hidden.minX, docked.minX, "\(edge) slides vertically")
      case .left, .right: XCTAssertEqual(hidden.minY, docked.minY, "\(edge) slides sideways")
      }
    }
    XCTAssertEqual(
      QuickTerminalEdge.top.hiddenFrame(
        docked: QuickTerminalEdge.top.dockedFrame(size: size, in: visible), screen: screen
      ).minY, screen.maxY, "touches the edge, so the slide has no gap")
  }

  func testToggleFromAbsentCreatesVisibleWindow() {
    let controller = makeController()
    defer { controller.close() }

    XCTAssertFalse(controller.hasWindow)
    controller.toggle()

    XCTAssertTrue(controller.hasWindow)
    XCTAssertTrue(controller.isVisible)
    XCTAssertNotNil(controller.currentSurface)
  }

  func testToggleWhenVisibleHidesButKeepsSurface() {
    let controller = makeController()
    defer { controller.close() }

    controller.toggle()  // → VISIBLE
    let surface = controller.currentSurface
    controller.toggle()  // → HIDDEN

    XCTAssertFalse(controller.isVisible)
    XCTAssertTrue(controller.hasWindow, "hidden, not destroyed")
    XCTAssertTrue(controller.currentSurface === surface, "same surface persists across hide")
  }

  func testToggleWhenHiddenShowsSameSurface() {
    let controller = makeController()
    defer { controller.close() }

    controller.toggle()  // VISIBLE
    let surface = controller.currentSurface
    controller.toggle()  // HIDDEN
    controller.toggle()  // VISIBLE again

    XCTAssertTrue(controller.isVisible)
    XCTAssertTrue(controller.currentSurface === surface, "re-summon restores the same session")
  }

  func testCloseTearsDownAndNextSummonIsFresh() {
    let controller = makeController()
    controller.toggle()
    let first = controller.currentSurface

    controller.close()
    XCTAssertFalse(controller.hasWindow)
    XCTAssertNil(controller.currentSurface)

    controller.toggle()  // a brand-new terminal — no session resurrection
    defer { controller.close() }
    XCTAssertNotNil(controller.currentSurface)
    XCTAssertFalse(controller.currentSurface === first, "reopen creates a different surface")
  }

  func testTheTerminalGetsTheWindowsHeightNotItsChrome() throws {
    // The drag areas in the tab strip and footer once grew tall and squashed the pane to nothing.
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    let window = try XCTUnwrap(controller.currentWindow)
    let surface = try XCTUnwrap(controller.currentSurface)
    window.contentView?.layoutSubtreeIfNeeded()

    let content = try XCTUnwrap(window.contentView).bounds.height
    XCTAssertGreaterThan(surface.frame.height, content - 120, "only the bars sit beside it")

    // …while the drag areas still fill their bar's height, so there's something to grab.
    func handles(in view: NSView) -> [NSView] {
      (view is QuickTerminalDragHandle.HandleView ? [view] : []) + view.subviews.flatMap(handles)
    }
    let found = handles(in: try XCTUnwrap(window.contentView))
    XCTAssertEqual(found.count, 2, "the tab strip's and the footer's")
    let frame = try XCTUnwrap(window.contentView?.superview)
    // A click `x` of the way across the window, level with `handle`.
    func clickLands(at x: CGFloat, across handle: NSView) -> NSView? {
      let row = handle.convert(handle.bounds, to: nil).midY
      return frame.hitTest(frame.convert(NSPoint(x: frame.bounds.width * x, y: row), from: nil))
    }
    for handle in found {
      XCTAssertGreaterThan(handle.frame.height, 15)
      // …and run across their bar: a click well past the tabs (once only the last 60pt) drags.
      XCTAssertTrue(clickLands(at: 0.75, across: handle) === handle)
    }
    // The strip's first tab sits above its handle and keeps its own clicks (select, reorder).
    let strip = try XCTUnwrap(
      found.max { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY })
    XCTAssertFalse(clickLands(at: 0.03, across: strip) === strip)
  }

  func testWindowIsChromeLessButClosable() throws {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()

    let window = try XCTUnwrap(controller.currentWindow)
    XCTAssertTrue(window is QuickTerminalWindow, "tag type the ⌘W key monitor matches on")
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertNil(window.toolbar, "no toolbar — chrome-less")
    XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true, "no traffic lights")
    XCTAssertFalse(window.isMovable, "docked to its edge")
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "the tab bar is the titlebar")
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertFalse(
      controller.windowShouldZoom(window, toFrame: .zero), "a double-click never un-docks it")
  }

  func testWindowStartsOffScreenOutsideAppKitsConstraint() throws {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    let window = try XCTUnwrap(controller.currentWindow)
    let offScreen = NSRect(x: 0, y: 100_000, width: 400, height: 200)
    XCTAssertEqual(window.constrainFrameRect(offScreen, to: window.screen), offScreen)
  }

  func testLosingFocusSlidesAwayUnlessTurnedOff() {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()  // VISIBLE

    controller.hidesWhenUnfocused = { false }
    controller.focusMoved(to: nil)
    XCTAssertTrue(controller.isVisible, "setting off: stays up")

    controller.hidesWhenUnfocused = { true }
    controller.focusMoved(to: nil)
    XCTAssertFalse(controller.isVisible, "setting on: slides away")
    XCTAssertTrue(controller.hasWindow, "hidden, not closed")
  }

  func testFocusOnItsOwnPopoverKeepsItUp() throws {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    controller.hidesWhenUnfocused = { true }
    let window = try XCTUnwrap(controller.currentWindow)
    // An `NSPopover`'s window is a child of the window it opens from (probed: `_NSPopoverWindow`).
    let popover = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered,
      defer: true)
    window.addChildWindow(popover, ordered: .above)
    defer { window.removeChildWindow(popover) }

    controller.focusMoved(to: popover)
    XCTAssertTrue(controller.isVisible, "the usage popover is part of the Quick Terminal")
  }

  func testItsStoreIsAWorkroomsKeptNowhere() throws {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    let store = try XCTUnwrap(controller.store)
    XCTAssertTrue(store.terminals.readsPaneBranches, "each pane reads its own branch")
    XCTAssertFalse(store.terminals.allowsDetach, "no pane moves to a window of its own")
    XCTAssertNil(
      WindowRegistry.shared.store(for: try XCTUnwrap(controller.currentWindow)),
      "never registered, so never saved or restored")
  }

  func testKeysActOnItsTabsAndTheLastCloseClosesTheWindow() throws {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    let store = try XCTUnwrap(controller.store)
    // A test pane never starts, so it counts as running and a close would ask first.
    store.confirmOnCloseOverrideForTesting = false
    let sessions = store.terminals
    let target = QuickTerminalController.target()

    controller.perform(.splitRight)
    controller.perform(.splitDown)
    XCTAssertEqual(sessions.split(for: target)?.tabIDs.count, 3)
    controller.perform(.newTab)
    XCTAssertEqual(sessions.tabs(for: target).count, 4)
    controller.perform(.selectTab(0))
    XCTAssertEqual(sessions.activeTab(for: target)?.id, sessions.tabs(for: target).first?.id)

    for _ in 0..<4 { controller.perform(.closePane) }
    XCTAssertFalse(controller.hasWindow, "⌘W on the last pane of the last tab closes the window")
  }

  func testArrowKeysMoveFocusBetweenItsPanes() throws {
    // Its store is in no WindowRegistry, so the workroom ⌃⌘arrow handler can't reach it (PR #571).
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    let sessions = try XCTUnwrap(controller.store).terminals
    let target = QuickTerminalController.target()
    let left = try XCTUnwrap(sessions.activeTab(for: target)).id
    controller.perform(.splitRight)
    let right = try XCTUnwrap(sessions.activeTab(for: target)).id
    XCTAssertNotEqual(left, right)

    XCTAssertTrue(controller.perform(.focusPane(.left)))
    XCTAssertEqual(sessions.activeTab(for: target)?.id, left)
    XCTAssertFalse(controller.perform(.focusPane(.up)), "no pane above: the key is the terminal's")
    XCTAssertEqual(sessions.activeTab(for: target)?.id, left)
  }

  /// The app's registry with this controller as its Quick Terminal and an empty list, put back after.
  private func joinRegistry(_ controller: QuickTerminalController) -> WindowRegistry {
    let registry = WindowRegistry.shared
    registry.notifications.clear()
    registry.quickTerminal = controller
    addTeardownBlock { @MainActor in
      registry.quickTerminal = nil
      registry.keyWindow = { NSApp.keyWindow }
      registry.notifications.clear()
    }
    return registry
  }

  /// Value: protects=its notifications joining the app's one list, named "Quick Terminal", opening
  /// it on their pane (ADR 0064); fails_when=its store keeps a list of its own, the source is blank
  /// or open goes to a workroom window; why_new=#571 bridged only the toast; seam=none;
  /// no_claim=the slide-in animation.
  func testItsNotificationsJoinTheListAndOpenItsPane() throws {
    let controller = makeController()
    defer { controller.close() }
    let registry = joinRegistry(controller)
    controller.toggle()
    let store = try XCTUnwrap(controller.store)
    let target = QuickTerminalController.target()
    let first = try XCTUnwrap(store.terminals.activeTab(for: target)).id
    controller.perform(.newTab)

    store.raiseFinished(
      targetID: target.id, tabID: first, record: ProgramStatusRecord(id: "", state: .idle))
    let note = try XCTUnwrap(registry.notifications.items.first)
    XCTAssertEqual(note.source, "Quick Terminal")
    XCTAssertEqual(registry.aggregateUnread, 1, "it counts in the one count")
    XCTAssertTrue(registry.notifyingHosts.contains { $0 === store }, "its needs-you alerts too")

    controller.hide()
    registry.open(note)
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, first)
    XCTAssertTrue(registry.notifications.items.isEmpty, "opening dismisses it")
  }

  /// Value: protects=a Quick Terminal agent's own notification, "needs you" request and finished turn
  /// each landing in the app's list as a workroom terminal's do, and a request opening the Quick
  /// Terminal on its pane (#573); fails_when=its sessions, its store in notifyingHosts or its route
  /// in WindowRegistry.open go; why_new=the parts were tested apart, never as one agent's run;
  /// seam=none; no_claim=a real Claude Code or Codex (the daemon's status and the OSC are simulated).
  func testAQuickTerminalAgentsNotificationsWorkAsAnyTerminals() throws {
    let controller = makeController(backend: .ready(version: "test"))
    defer { controller.close() }
    let registry = joinRegistry(controller)
    controller.toggle()
    let store = try XCTUnwrap(controller.store)
    let monitor = ProgramStatusMonitor()
    store.terminals.programStatus = monitor
    let alerts = ProgramStatusAlerts()
    alerts.monitor = monitor
    alerts.stores = { registry.notifyingHosts }
    alerts.isEnabled = { true }
    alerts.isFinishEnabled = { true }
    alerts.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    alerts.start()
    // A pane opened under the simulated daemon, so its status reaches it.
    controller.perform(.newTab)
    let target = QuickTerminalController.target()
    let tab = try XCTUnwrap(store.terminals.activeTab(for: target))
    let session = try XCTUnwrap(store.terminals.sessionID(forTab: tab.id, inTarget: target.id))

    // An agent's own OSC notification, from a pane nobody is watching: the first tab, behind the one
    // just opened. Not the open tab: whether that counts as watched turns on whether the Quick
    // Terminal's window got key, which parallel test processes racing for the front decide.
    let behind = try XCTUnwrap(store.terminals.allTabs(for: target).first { $0.id != tab.id })
    store.terminals.onEvent?(
      .activity(target.id, behind.id, .osc(title: "Build done", body: nil)))
    XCTAssertTrue(registry.notifications.items.contains { $0.title == "Build done" })

    // It asks for permission: a "needs you" alert, waiting.
    monitor.seed(
      session,
      records: [
        ProgramStatusRecord(
          id: "", state: .blocked, kind: .permission, message: "Apply?", episode: 1, notify: true)
      ])
    let request = try XCTUnwrap(registry.notifications.items.first { $0.episode != nil })
    XCTAssertEqual(request.source, "Quick Terminal")
    XCTAssertEqual(alerts.waiting.map(\.session), [session])

    // Going to it slides the Quick Terminal in on that pane.
    controller.hide()
    alerts.open(try XCTUnwrap(alerts.waiting.first))
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, tab.id)

    // It carries on and finishes its turn.
    monitor.seed(session, records: [ProgramStatusRecord(id: "", state: .working)])
    monitor.seed(
      session,
      records: [ProgramStatusRecord(id: "", state: .done, message: "Fixed it", notify: true)])
    XCTAssertTrue(registry.notifications.items.contains { $0.title.hasSuffix("finished") })
  }

  /// Value: protects=closing it dropping its notifications, as a closing window's go (#573 D3);
  /// fails_when=its rows outlive it and open nothing; why_new=new path; seam=none;
  /// no_claim=banner withdrawal on the real notification center.
  func testClosingItDropsItsNotifications() throws {
    let controller = makeController()
    let registry = joinRegistry(controller)
    controller.toggle()
    let store = try XCTUnwrap(controller.store)
    let tab = try XCTUnwrap(store.terminals.activeTab(for: QuickTerminalController.target())).id
    store.raiseFinished(
      targetID: QuickTerminalController.targetID, tabID: tab,
      record: ProgramStatusRecord(id: "", state: .idle))
    XCTAssertEqual(registry.notifications.items.count, 1)

    controller.close()
    XCTAssertTrue(registry.notifications.items.isEmpty)
  }

  /// Value: protects=a toast showing in the Quick Terminal while it is the front window (#573 D2);
  /// fails_when=it goes to the workroom window behind it; why_new=new; seam=WindowRegistry.keyWindow
  /// (production caller: keyStore and frontHost, defaulting to NSApp.keyWindow); no_claim=rendering.
  func testAToastShowsInTheQuickTerminalWhileItIsInFront() throws {
    let controller = makeController()
    defer { controller.close() }
    let registry = joinRegistry(controller)
    controller.toggle()
    let store = try XCTUnwrap(controller.store)
    registry.keyWindow = { controller.currentWindow }
    store.isAppActive = { true }

    store.raiseFinished(
      targetID: QuickTerminalController.targetID, tabID: UUID(),
      record: ProgramStatusRecord(id: "", state: .idle))
    XCTAssertEqual(store.toasts.count, 1)
  }

  /// Value: protects=a notification from the Quick Terminal pane you are watching counting as seen,
  /// as a workroom's does (#573, O4); fails_when=its target is never on screen for want of a
  /// selection; why_new=handleActivity read the selected workroom only; seam=none; no_claim=focus as
  /// AppKit reports it on screen (a key window stands in).
  func testAWatchedPaneIsSeen() throws {
    let controller = makeController()
    defer { controller.close() }
    let registry = joinRegistry(controller)
    controller.toggle()
    let store = try XCTUnwrap(controller.store)
    let tab = try XCTUnwrap(store.terminals.activeTab(for: QuickTerminalController.target())).id
    store.hostWindow = AlwaysKeyWindow()

    store.terminals.onEvent?(
      .activity(QuickTerminalController.targetID, tab, .osc(title: "done", body: nil)))
    XCTAssertTrue(registry.notifications.items.isEmpty, "you were looking at it")
  }

  func testANotificationClickSlidesInOnItsPane() throws {
    // The app's notification routing finds stores through WindowRegistry, which this one is not in.
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    let sessions = try XCTUnwrap(controller.store).terminals
    let target = QuickTerminalController.target()
    let first = try XCTUnwrap(sessions.activeTab(for: target)).id
    controller.perform(.newTab)
    controller.hide()
    XCTAssertFalse(controller.isVisible)

    controller.reveal(tab: first)
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(sessions.activeTab(for: target)?.id, first)
  }

  // Value: protects=the key monitor takes exactly ⌘W/T/D/⇧⌘D/⌘1-9 in the Quick Terminal; fails_when=a chord maps wrong or a stray one is swallowed; why_new=no test calls classify; seam=none; no_claim=the monitor wiring in AppDelegate
  func testKeyClassificationTakesOnlyItsOwnChords() {
    typealias Key = QuickTerminalKey
    XCTAssertEqual(Key.classify(flags: .command, characters: "w"), .closePane)
    XCTAssertEqual(Key.classify(flags: .command, characters: "t"), .newTab)
    XCTAssertEqual(Key.classify(flags: .command, characters: "d"), .splitRight)
    XCTAssertEqual(Key.classify(flags: [.command, .shift], characters: "D"), .splitDown)
    XCTAssertEqual(Key.classify(flags: .command, characters: "1"), .selectTab(0))
    XCTAssertEqual(Key.classify(flags: .command, characters: "9"), .selectTab(8))
    XCTAssertEqual(
      Key.classify(flags: [.command, .control], characters: nil, keyCode: 123), .focusPane(.left))
    XCTAssertEqual(
      Key.classify(flags: [.command, .control], characters: nil, keyCode: 126), .focusPane(.up))
    XCTAssertNil(
      Key.classify(flags: [.command, .option], characters: nil, keyCode: 124),
      "⌥⌘arrows cycle tabs in a workroom, not panes")
    XCTAssertEqual(
      Key.classify(flags: [.command, .capsLock, .numericPad], characters: "w"), .closePane,
      "only the four real modifiers count")

    XCTAssertNil(Key.classify(flags: .command, characters: "0"), "⌘0 is no tab")
    XCTAssertNil(Key.classify(flags: .command, characters: "c"), "copy stays the terminal's")
    XCTAssertNil(Key.classify(flags: [], characters: "w"), "a bare key is typing")
    XCTAssertNil(Key.classify(flags: [.command, .option], characters: "d"))
    XCTAssertNil(Key.classify(flags: .control, characters: "d"), "^D is EOF")
    XCTAssertNil(Key.classify(flags: .command, characters: nil))
  }

  func testCloseMidSlideOutTearsDown() {
    let controller = makeController()
    controller.toggle()  // VISIBLE
    controller.toggle()  // sliding out
    XCTAssertFalse(controller.isVisible, "a slide-out counts as hidden, so the next ⌥§ shows")
    controller.close()
    XCTAssertFalse(controller.hasWindow)
  }
}

/// The hotkey-dispatch fix (issue #39): with two global hotkeys live, each installed Carbon handler
/// sees every press, so it must act only on its own id — otherwise the first-installed handler
/// swallows every press and fires the wrong action. `GlobalHotkey.matches` is that filter.
final class GlobalHotkeyDispatchTests: XCTestCase {
  func testMatchesOnlyOwnSignatureAndID() {
    let ours = EventHotKeyID(signature: GlobalHotkey.signature, id: 2)
    XCTAssertTrue(GlobalHotkey.matches(ours, id: 2), "our id-2 hotkey handles its own press")
    XCTAssertFalse(GlobalHotkey.matches(ours, id: 1), "id-1 instance must ignore the id-2 press")
  }

  func testIgnoresForeignSignature() {
    let foreign = EventHotKeyID(signature: OSType(0x1234_5678), id: 1)
    XCTAssertFalse(
      GlobalHotkey.matches(foreign, id: 1), "another app's hotkey id must never be handled")
  }
}

/// A window that is key whatever the test host's activation state.
private final class AlwaysKeyWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
