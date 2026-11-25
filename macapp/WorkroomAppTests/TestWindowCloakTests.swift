import AppKit
import XCTest

@testable import Workroom

/// `TestWindowCloak`, installed for this whole run: every window the test host shows is hidden from
/// the developer, while it shows and as it closes, still counts as on screen, and keeps what its
/// code set for a test to read. Checked against what the window server shows (`serverAlphas`):
/// AppKit's close animation once ran at full opacity on a window AppKit itself believed opaque.
// Value: protects=the unit suite showing no window over the developer's work, whichever code
// orders it on screen and however it goes; fails_when=a way of showing a window escapes the cloak,
// a window flashes as it closes, the cloak stops a window counting as visible (rendering pauses),
// or what the code set is lost; no_claim=windows a launch opens before the bundle loads
// (`AppEnvironment.opensWindowsAtLaunch`)
@MainActor
final class TestWindowCloakTests: XCTestCase {
  private var windows: [NSWindow] = []

  override func tearDown() async throws {
    for window in windows { window.orderOut(nil) }
    windows = []
    try await super.tearDown()
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 200, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    return window
  }

  /// The alphas the window server shows window `number` at, sampled for `seconds`.
  private func serverAlphas(of number: Int, for seconds: TimeInterval) -> [Double] {
    var seen: [Double] = []
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      let list =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
      if let alpha = list?.first(where: { ($0[kCGWindowNumber as String] as? Int) == number })?[
        kCGWindowAlpha as String] as? Double
      {
        seen.append(alpha)
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return seen
  }

  // The app's own code orders its windows front these ways; none may reach the screen.
  func testEveryWayOfShowingAWindowIsCloaked() {
    let shows: [(String, (NSWindow) -> Void)] = [
      ("orderFront", { $0.orderFront(nil) }),  // check-test-windows: allow (the cloak's own test)
      ("orderFrontRegardless", { $0.orderFrontRegardless() }),  // check-test-windows: allow
      ("makeKeyAndOrderFront", { $0.makeKeyAndOrderFront(nil) }),  // check-test-windows: allow
      ("order(.above)", { $0.order(.above, relativeTo: 0) }),
      ("setIsVisible", { $0.setIsVisible(true) }),
    ]
    for (name, show) in shows {
      let window = makeWindow()
      show(window)
      XCTAssertTrue(window.isVisible, "\(name): not on screen")
      XCTAssertEqual(window.alphaValue, 0, "\(name): it showed opaque")
      XCTAssertTrue(window.ignoresMouseEvents, "\(name): it takes clicks")
      let seen = serverAlphas(of: window.windowNumber, for: 0.3)
      XCTAssertFalse(seen.isEmpty, "\(name): the window server never listed it")
      XCTAssertEqual(seen.filter { $0 > 0 }, [], "\(name): the developer saw it")
    }
  }

  func testACloakedWindowClosesWithoutShowingItself() {
    let hides: [(String, (NSWindow) -> Void)] = [
      ("orderOut", { $0.orderOut(nil) }), ("close", { $0.close() }),
    ]
    for (name, hide) in hides {
      let window = makeWindow()
      window.animationBehavior = .documentWindow  // the default's shrink-and-fade
      showTestWindow(window)
      XCTAssertEqual(window.animationBehavior, .none, "\(name): it would animate opaque")
      let number = window.windowNumber
      hide(window)
      XCTAssertEqual(
        serverAlphas(of: number, for: 0.6).filter { $0 > 0 }, [],
        "\(name): the close animation showed it")
    }
  }

  func testACloakedWindowKeepsWhatItsCodeSet() {
    let window = makeWindow()
    window.alphaValue = 0.4
    window.ignoresMouseEvents = false
    window.animationBehavior = .utilityWindow
    showTestWindow(window)
    var held = TestWindowCloak.requested(window)
    XCTAssertEqual(held.alpha, 0.4, accuracy: 0.001, "set before it showed")
    XCTAssertFalse(held.ignoresMouseEvents)
    XCTAssertEqual(held.animationBehavior, .utilityWindow)
    window.alphaValue = 1  // a fade-in finishing
    window.ignoresMouseEvents = true
    held = TestWindowCloak.requested(window)
    XCTAssertEqual(held.alpha, 1, accuracy: 0.001, "set while shown")
    XCTAssertTrue(held.ignoresMouseEvents)
    XCTAssertEqual(window.alphaValue, 0, "a fade-in uncloaked it")
  }

  func testACloakedWindowStillCountsAsVisible() {
    let window = makeWindow()
    showTestWindow(window)
    settle(3, until: { window.occlusionState.contains(.visible) })
    XCTAssertTrue(
      window.occlusionState.contains(.visible),
      "within 3 s: a cloaked window must still report itself visible, or its terminals stop")
  }

  func testAnExemptWindowShowsAsTheUserWouldSeeIt() {
    let window = makeWindow()
    window.alphaValue = 0.8
    window.animationBehavior = .none  // seen, but for no longer than it must be
    showTestWindowVisibly(window, because: "this test checks the exemption")
    XCTAssertEqual(window.alphaValue, 0.8, accuracy: 0.01)
    XCTAssertFalse(window.ignoresMouseEvents)
    let seen = serverAlphas(of: window.windowNumber, for: 0.3)
    XCTAssertEqual(seen.last ?? 0, 0.8, accuracy: 0.01, "the window server shows it as set")
  }
}
