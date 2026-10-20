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

  /// The panel `SwitcherPanelController.prepare()` actually builds, so these assertions read the
  /// shipped settings rather than ones the test assigned itself. Found as the one `SwitcherPanel`
  /// window that `prepare()` added; the controller is returned because it owns the panel.
  private func preparedPanel() throws -> (SwitcherPanelController, SwitcherPanel) {
    let before = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = SwitcherPanelController()
    controller.prepare()
    let panel = try XCTUnwrap(
      NSApp.windows.compactMap { $0 as? SwitcherPanel }
        .first { !before.contains(ObjectIdentifier($0)) },
      "prepare() built no SwitcherPanel")
    return (controller, panel)
  }

  func testWindowCyclingSkipsThePanel() throws {
    // Twice over: ⌘`'s `isCycleableWindow` requires `canBecomeKey`, and `.ignoresCycle` is belt and
    // braces on top.
    let (controller, panel) = try preparedPanel()
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    XCTAssertFalse(WindowRegistry().isCycleableWindow(panel), "⌘` must never land on the rail")
    XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
    withExtendedLifetime(controller) {}
  }

  func testThePanelStaysNonOpaque() throws {
    // `NSWindow.occlusionState` counts only OPAQUE coverage. A clear panel never flips it; give this
    // an opaque background and every terminal surface behind the rail believes it is occluded and
    // stops rendering. This assertion is the guard on that.
    let (controller, panel) = try preparedPanel()
    XCTAssertFalse(panel.isOpaque, "an opaque rail would freeze the terminals behind it")
    XCTAssertEqual(panel.backgroundColor, .clear)
    withExtendedLifetime(controller) {}
  }

  func testTheRailDrawsItsOwnShadowRatherThanTheWindow() throws {
    // Measured, not assumed: a borderless non-opaque panel casts NO system shadow — `hasShadow = true`
    // plus `invalidateShadow()` darkened nothing at 6/14/26/44pt out on any side, with glass content and
    // with a solid opaque fill alike. So the rail draws the shadow itself and the window stays shadowless.
    let (controller, panel) = try preparedPanel()
    XCTAssertFalse(
      panel.hasShadow, "a window shadow here would only duplicate the drawn one, squarely")
    withExtendedLifetime(controller) {}
  }

  func testTheHaloDoesNotEatClicksMeantForTheWindowBelow() {
    // The window is bigger than the rail by `shadowMargin` on every side so the drawn shadow has room.
    // That border is empty, and a plain NSView would hit-test it — swallowing clicks that should reach
    // whatever is underneath.
    let content = HaloContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let inner = NSView(frame: content.bounds)
    inner.autoresizingMask = [.width, .height]
    content.addSubview(inner)
    let margin = SwitcherRailLayout.shadowMargin
    XCTAssertNil(
      content.hitTest(NSPoint(x: margin / 2, y: 100)), "the shadow halo must be click-through")
    XCTAssertNotNil(
      content.hitTest(NSPoint(x: 200, y: 100)), "the rail itself still takes hover and clicks")
  }

  func testThePanelIsAFloatingNonActivatingHUD() throws {
    let (controller, panel) = try preparedPanel()
    XCTAssertTrue(
      panel.styleMask.contains(.nonactivatingPanel), "showing it must not activate the app")
    XCTAssertEqual(panel.level, .floating)
    XCTAssertTrue(panel.isFloatingPanel)
    withExtendedLifetime(controller) {}
  }

  func testThePanelIsInvisibleToTheWindowsMenu() throws {
    let (controller, panel) = try preparedPanel()
    XCTAssertTrue(panel.isExcludedFromWindowsMenu)
    withExtendedLifetime(controller) {}
  }

  func testThePanelTakesMouseEvents() throws {
    // Hover and click are part of the spec, so it must not be a pass-through overlay.
    let (controller, panel) = try preparedPanel()
    XCTAssertFalse(panel.ignoresMouseEvents)
    withExtendedLifetime(controller) {}
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
