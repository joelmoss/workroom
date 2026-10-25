import AppKit
import XCTest

@testable import Workroom

@MainActor
final class CopyConfirmationTests: XCTestCase {
  func testConfirmationIsCentredJustAboveTheButton() {
    let button = NSRect(x: 200, y: 100, width: 20, height: 18)
    let size = NSSize(width: 65, height: 28)
    let origin = CopyConfirmation.origin(
      for: button, size: size, within: NSRect(x: 0, y: 0, width: 800, height: 600))
    XCTAssertEqual(origin.x + size.width / 2, button.midX)
    XCTAssertEqual(origin.y - button.maxY, 4)
  }

  func testConfirmationFitsBelowAButtonAtTheTopRightOfTheScreen() {
    let button = NSRect(x: 775, y: 570, width: 20, height: 18)
    let size = NSSize(width: 65, height: 28)
    let origin = CopyConfirmation.origin(
      for: button, size: size, within: NSRect(x: 0, y: 0, width: 800, height: 600))
    XCTAssertEqual(button.minY - (origin.y + size.height), 4)
    XCTAssertLessThanOrEqual(origin.x + size.width, 792)
  }

  func testCopyShowsALegibleConfirmationWithoutTakingFocusThenDismisses() async throws {
    let source = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    source.isReleasedWhenClosed = false
    defer { source.close() }
    let anchor = NSView(frame: NSRect(x: 100, y: 100, width: 20, height: 18))
    source.contentView?.addSubview(anchor)
    source.orderFront(nil)
    let keyWindow = NSApp.keyWindow
    CopyConfirmation.copy("copy confirmation test", relativeTo: anchor)
    let panel = try XCTUnwrap(
      NSApp.windows.first { $0.accessibilityIdentifier() == "copy.confirmation" })
    defer { panel.orderOut(nil) }

    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(panel.parent === source)
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
    XCTAssertGreaterThan(panel.frame.width, 40)
    XCTAssertGreaterThan(panel.frame.height, 20)
    let revealDeadline = ContinuousClock.now + .milliseconds(800)
    while panel.alphaValue < 0.9, ContinuousClock.now < revealDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThan(panel.alphaValue, 0.9, "a visible window must not stay transparent")
    let anchorOnScreen = source.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    XCTAssertEqual(panel.frame.midX, anchorOnScreen.midX, accuracy: 1)
    XCTAssertEqual(panel.frame.minY, anchorOnScreen.maxY + 4, accuracy: 1)
    let label = try XCTUnwrap(panel.contentView?.subviews.first as? NSTextField)
    XCTAssertEqual(label.stringValue, "Copied!")
    XCTAssertGreaterThan(label.frame.width, 20, "the confirmation text must be laid out")
    XCTAssertGreaterThan(label.frame.height, 10)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copy confirmation test")

    let deadline = ContinuousClock.now + .seconds(5)
    while panel.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(panel.isVisible, "the confirmation dismisses without another click")
  }
}
