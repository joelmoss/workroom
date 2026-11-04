import Carbon.HIToolbox
import Defaults
import XCTest

@testable import Workroom

/// The quick-terminal lifecycle (issue #39): ABSENT → summon a fresh ~/ window, hide keeps the
/// surface alive across a re-summon, and a close fully tears it down so the next summon is fresh.
/// Surfaces are injected non-spawning (`spawnsSurface: false`) so no real PTY / Metal renderer is
/// created — mounting and tearing one down is unsafe in the headless test host.
@MainActor
final class QuickTerminalControllerTests: XCTestCase {
  private func makeController() -> QuickTerminalController {
    let controller = QuickTerminalController()
    controller.makeSurface = {
      GhosttySurfaceView(workingDirectory: $0, command: $1, spawnsSurface: false)
    }
    // Key focus moves under the test host's feet; only the focus test opts in.
    controller.hidesWhenUnfocused = { false }
    return controller
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

  func testDragDocksToTheEdgeNearestThePointer() {
    XCTAssertEqual(QuickTerminalEdge.nearest(to: NSPoint(x: 500, y: 880), in: visible), .top)
    XCTAssertEqual(QuickTerminalEdge.nearest(to: NSPoint(x: 500, y: 120), in: visible), .bottom)
    XCTAssertEqual(QuickTerminalEdge.nearest(to: NSPoint(x: 10, y: 500), in: visible), .left)
    XCTAssertEqual(QuickTerminalEdge.nearest(to: NSPoint(x: 990, y: 500), in: visible), .right)
    XCTAssertEqual(
      QuickTerminalEdge.nearest(to: NSPoint(x: 0, y: 900), in: visible), .top,
      "a corner breaks the tie the same way every time")
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
    for handle in found { XCTAssertGreaterThan(handle.frame.height, 15) }
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
    XCTAssertFalse(store.terminals.persistsSessions, "its shells are never kept")
    XCTAssertFalse(store.terminals.allowsDetach, "no pane moves to a window of its own")
    XCTAssertNil(
      WindowRegistry.shared.store(for: try XCTUnwrap(controller.currentWindow)),
      "never registered, so never saved, restored or badged")
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
