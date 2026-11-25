import AppKit
import XCTest

@testable import Workroom

/// Glass's window blur (#727, ADR 0080): the private CoreGraphics window-blur call, resolved at
/// runtime. A glass window asks for the fixed radius and an opaque one clears it; a Mac without the
/// call gets a clear, unblurred window, never a broken one.
@MainActor
final class WindowBlurTests: XCTestCase {
  private var windows: [NSWindow] = []
  /// Every call the blur made, in order.
  private var calls: [(window: Int, radius: Int)] = []

  override func setUp() async throws {
    try await super.setUp()
    WindowBlur.setRadius = { [weak self] in self?.calls.append((window: $0, radius: $1)) }
  }

  override func tearDown() async throws {
    WindowBlur.setRadius = WindowBlur.system
    for window in windows { window.close() }
    windows = []
    try await super.tearDown()
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    windows.append(window)
    return window
  }

  /// The window server is asked only when the window turns glass or opaque: a re-apply of the same
  /// appearance on a SwiftUI update, or an opacity change within glass, makes no call.
  func testGlassBlursAtTheFixedRadiusOnceAndOpaqueClearsIt() {
    let window = makeWindow()
    XCTAssertGreaterThan(window.windowNumber, 0)

    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.8))
    WindowBackgroundThemer.apply(to: window, glass: .opaque)
    WindowBackgroundThemer.apply(to: window, glass: .opaque)

    XCTAssertEqual(calls.map(\.window), Array(repeating: window.windowNumber, count: 2))
    XCTAssertEqual(calls.map(\.radius), [20, 0], "the radius is fixed; opaque is 0")
  }

  /// Value: protects=a window the window server hasn't numbered yet is never asked, and waits to
  /// turn glass, so it turns with its blur rather than staying unblurred glass for good;
  /// fails_when=`apply` turns an unnumbered window glass, or never turns it once it is numbered;
  /// seam=`WindowBlur.setRadius`, recorded; no_claim=what the window server draws
  func testAWindowWithNoWindowServerNumberIsNotAskedAndTurnsOnceNumbered() {
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    windows.append(window)
    XCTAssertLessThanOrEqual(window.windowNumber, 0)
    XCTAssertFalse(WindowBlur.setBlurRadius(WindowBlur.glassRadius, of: window))
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    XCTAssertTrue(calls.isEmpty)
    XCTAssertTrue(window.isOpaque, "unnumbered: it stays opaque rather than turn without its blur")
    XCTAssertEqual(window.backgroundColor, ThemeFill.panel.nsColor())

    showTestWindow(window)
    XCTAssertGreaterThan(window.windowNumber, 0)
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    XCTAssertFalse(window.isOpaque, "numbered: the next apply turns it")
    XCTAssertEqual(calls.map(\.window), [window.windowNumber])
    XCTAssertEqual(calls.map(\.radius), [WindowBlur.glassRadius], "and blurs it on the turn")
  }

  func testAMissingCallLeavesAClearUnblurredGlassWindow() {
    WindowBlur.setRadius = nil
    let window = makeWindow()
    XCTAssertFalse(WindowBlur.setBlurRadius(WindowBlur.glassRadius, of: window), "nothing to ask")
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    XCTAssertFalse(window.isOpaque)
  }

  func testThisMacHasTheCall() {
    WindowBlur.setRadius = WindowBlur.system
    let window = makeWindow()
    XCTAssertNotNil(WindowBlur.system, "CGSSetWindowBackgroundBlurRadius should resolve")
    XCTAssertTrue(WindowBlur.setBlurRadius(0, of: window), "the window server was asked")
  }

  /// The blur is the window's, not a view's: glass adds no subview to the frame view, which AppKit
  /// warns about as an "unknown subview".
  func testGlassAddsNoViewToTheWindow() throws {
    let window = makeWindow()
    let frame = try XCTUnwrap(window.contentView?.superview)
    // AppKit drops its own window-background material once the window has a background colour of
    // its own, so compare what was added, not the whole list.
    let before = frame.subviews
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    XCTAssertEqual(frame.subviews.filter { !before.contains($0) }, [])
    WindowBackgroundThemer.apply(to: window, glass: .opaque)
    XCTAssertEqual(frame.subviews.filter { !before.contains($0) }, [])
  }
}
