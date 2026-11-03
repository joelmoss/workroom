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
      GhosttySurfaceView(workingDirectory: "/tmp", command: nil, spawnsSurface: false)
    }
    return controller
  }

  func testDefaultSurfaceOpensAtHome() {
    // The default factory (the real app path) spawns the shell in the Settings folder, ~/ while it
    // is unset. Inspect it without mounting, so no surface is actually created.
    let surface = QuickTerminalController().makeSurface()
    XCTAssertEqual(
      surface.workingDirectory,
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
    XCTAssertTrue(window.styleMask.contains(.closable), "⌘W's performClose still closes it")
  }

  func testWindowStartsOffScreenOutsideAppKitsConstraint() throws {
    let controller = makeController()
    defer { controller.close() }
    controller.toggle()
    let window = try XCTUnwrap(controller.currentWindow)
    let offScreen = NSRect(x: 0, y: 100_000, width: 400, height: 200)
    XCTAssertEqual(window.constrainFrameRect(offScreen, to: window.screen), offScreen)
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
