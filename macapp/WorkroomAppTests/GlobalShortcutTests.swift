import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest

@testable import Workroom

/// The Quick Terminal's recorded global shortcut: what a key press records, how it reads, and
/// which presses the recorder refuses.
final class GlobalShortcutTests: XCTestCase {
  func testDefaultIsOptionSection() {
    XCTAssertEqual(GlobalShortcut.quickTerminalDefault.label, "⌥§")
    XCTAssertEqual(
      GlobalShortcut.quickTerminalDefault.keyboardShortcut,
      KeyboardShortcut("§", modifiers: .option))
  }

  func testRecordsModifiersInCarbonAndMenuOrder() throws {
    let shortcut = try XCTUnwrap(
      GlobalShortcut(keyCode: kVK_ANSI_T, flags: [.command, .shift, .control], unshifted: "t"))
    XCTAssertEqual(shortcut.carbonModifiers, cmdKey | shiftKey | controlKey)
    XCTAssertEqual(shortcut.label, "⌃⇧⌘T")
    XCTAssertEqual(
      shortcut.keyboardShortcut, KeyboardShortcut("t", modifiers: [.command, .shift, .control]))
  }

  func testNamesSpecialKeys() throws {
    let space = try XCTUnwrap(
      GlobalShortcut(keyCode: kVK_Space, flags: .option, unshifted: " "))
    XCTAssertEqual(space.label, "⌥Space")
    let f5 = try XCTUnwrap(GlobalShortcut(keyCode: kVK_F5, flags: .control, unshifted: "\u{F708}"))
    XCTAssertEqual(f5.label, "⌃F5")
    XCTAssertEqual(f5.keyboardShortcut?.key, KeyEquivalent(Character(UnicodeScalar(0xF708)!)))
  }

  func testRefusesAKeyWithoutCommandOptionOrControl() {
    XCTAssertNil(GlobalShortcut(keyCode: kVK_ANSI_A, flags: [], unshifted: "a"))
    XCTAssertNil(
      GlobalShortcut(keyCode: kVK_ANSI_A, flags: .shift, unshifted: "a"), "⇧A is typing")
  }

  func testRoundTripsThroughCodable() throws {
    let shortcut = GlobalShortcut(
      keyCode: kVK_ANSI_K, carbonModifiers: cmdKey | optionKey, key: "k")
    let data = try JSONEncoder().encode(shortcut)
    XCTAssertEqual(try JSONDecoder().decode(GlobalShortcut.self, from: data), shortcut)
  }

  @MainActor func testRecorderVerdicts() {
    let current = GlobalShortcut.quickTerminalDefault
    let other = GlobalShortcut(keyCode: kVK_ANSI_K, carbonModifiers: optionKey, key: "k")
    let free: (GlobalShortcut) -> Bool = { _ in true }
    let taken: (GlobalShortcut) -> Bool = { _ in false }

    XCTAssertEqual(
      ShortcutRecorder.verdict(for: nil, current: current, isAvailable: free),
      .refuse("Include ⌘, ⌥ or ⌃."))
    XCTAssertEqual(
      ShortcutRecorder.verdict(for: other, current: current, isAvailable: free), .use(other))
    XCTAssertEqual(
      ShortcutRecorder.verdict(for: other, current: current, isAvailable: taken),
      .refuse("Another app uses that shortcut."))
    XCTAssertEqual(
      ShortcutRecorder.verdict(for: current, current: current, isAvailable: taken), .use(current),
      "our own registration holds the current one; re-recording it is fine")
    XCTAssertEqual(
      ShortcutRecorder.verdict(for: .showHide, current: current, isAvailable: free),
      .refuse("Workroom's show/hide shortcut uses that."))
  }

  /// The real Carbon probe: a shortcut this test holds is taken, and free once let go.
  @MainActor func testAvailabilityProbeSeesAHeldShortcut() throws {
    let shortcut = GlobalShortcut(
      keyCode: kVK_F19, carbonModifiers: cmdKey | optionKey | controlKey | shiftKey, key: "x")
    XCTAssertTrue(GlobalHotkey.isAvailable(shortcut), "nothing holds ⌃⌥⇧⌘F19")
    var held = GlobalHotkey.quickTerminal(shortcut) {}
    XCTAssertNotNil(held)
    XCTAssertFalse(GlobalHotkey.isAvailable(shortcut), "held by us now")
    held = nil
    XCTAssertTrue(GlobalHotkey.isAvailable(shortcut), "let go again")
    _ = held
  }
}
