import AppKit
import XCTest

@testable import Workroom

/// The rows' double-click gate reads the system's click count, not when its handler ran.
final class RepeatClickTests: XCTestCase {
  private func mouse(_ type: NSEvent.EventType, clicks: Int) -> NSEvent? {
    NSEvent.mouseEvent(
      with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
  }

  func testTheSecondClickOfADoubleClickIsARepeat() {
    XCTAssertTrue(RepeatClick.isRepeat(mouse(.leftMouseUp, clicks: 2)))
    XCTAssertTrue(RepeatClick.isRepeat(mouse(.leftMouseDown, clicks: 3)))
  }

  func testASingleClickIsNotARepeat() {
    XCTAssertFalse(RepeatClick.isRepeat(mouse(.leftMouseUp, clicks: 1)))
  }

  /// A keyboard-driven press (VoiceOver, Space) has no click count; reading one would raise.
  func testANonMouseEventOrNoEventIsNotARepeat() {
    let key = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
      keyCode: 49)
    XCTAssertFalse(RepeatClick.isRepeat(key))
    XCTAssertFalse(RepeatClick.isRepeat(nil))
  }
}
