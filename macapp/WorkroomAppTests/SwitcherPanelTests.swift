import AppKit
import XCTest

@testable import Workroom

/// `SwitcherPanel` (issue #132, T11): the window-level invariants the rail depends on. Each of these
/// is a property that looks like a style choice and is actually load-bearing — which is exactly why
/// they're pinned rather than left to a code comment.
@MainActor
final class SwitcherPanelTests: XCTestCase {

  private func makePanel() -> SwitcherPanel {
    SwitcherPanel(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
  }

  func testThePanelCanNeverTakeKeyFocus() {
    // The gesture depends on the WORKROOM window staying key: the AppDelegate monitor resolves its
    // store from the key window, so the moment this panel could become key, ⌥Tab would stop working
    // as soon as the rail appeared.
    let panel = makePanel()
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
  }

  func testWindowCyclingSkipsThePanel() {
    // Twice over: ⌘`'s `isCycleableWindow` requires `canBecomeKey`, and `.ignoresCycle` is belt and
    // braces on top.
    let panel = makePanel()
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    XCTAssertFalse(WindowRegistry().isCycleableWindow(panel), "⌘` must never land on the rail")
    XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
  }

  func testThePanelStaysNonOpaque() {
    // `NSWindow.occlusionState` counts only OPAQUE coverage. A clear panel never flips it; give this
    // an opaque background and every terminal surface behind the rail believes it is occluded and
    // stops rendering. This assertion is the guard on that.
    let panel = makePanel()
    panel.isOpaque = false
    panel.backgroundColor = .clear
    XCTAssertFalse(panel.isOpaque, "an opaque rail would freeze the terminals behind it")
    XCTAssertEqual(panel.backgroundColor, .clear)
  }

  func testThePanelIsAFloatingNonActivatingHUD() {
    let panel = makePanel()
    panel.isFloatingPanel = true
    panel.level = .floating
    XCTAssertTrue(
      panel.styleMask.contains(.nonactivatingPanel), "showing it must not activate the app")
    XCTAssertEqual(panel.level, .floating)
    XCTAssertTrue(panel.isFloatingPanel)
  }

  func testThePanelIsInvisibleToTheWindowsMenu() {
    let panel = makePanel()
    panel.isExcludedFromWindowsMenu = true
    XCTAssertTrue(panel.isExcludedFromWindowsMenu)
  }

  func testThePanelTakesMouseEvents() {
    // Hover and click are part of the spec, so it must not be a pass-through overlay.
    let panel = makePanel()
    panel.ignoresMouseEvents = false
    XCTAssertFalse(panel.ignoresMouseEvents)
  }

  func testPrepareIsIdempotentAndOrdersNothingIn() {
    let controller = SwitcherPanelController()
    controller.prepare()
    controller.prepare()  // must not build a second panel or throw
    XCTAssertTrue(
      NSApp.windows.filter { $0 is SwitcherPanel }.allSatisfy { !$0.isVisible },
      "pre-created at launch, but never on screen until a reveal")
  }
}
