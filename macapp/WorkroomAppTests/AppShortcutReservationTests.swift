import AppKit
import XCTest

@testable import Workroom

/// `GhosttySurfaceView.isAppShortcut` — which key combinations Workroom keeps for itself instead of
/// letting them reach the terminal.
///
/// This list is load-bearing and silently easy to get wrong. A menu shortcut that ISN'T reserved reaches
/// libghostty, and a TUI running in an enhanced keyboard mode (Claude, Codex) consumes it — so the menu
/// item's key equivalent never fires and the shortcut appears simply not to work, but only while an
/// agent is running. That has shipped twice (most recently issue #128). Until now the function was
/// private and untested; it was split into a pure classifier so these can exist.
final class AppShortcutReservationTests: XCTestCase {

  private func reserved(
    _ key: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0
  ) -> Bool {
    GhosttySurfaceView.isAppShortcut(
      modifierFlags: flags, keyCode: keyCode, charactersIgnoringModifiers: key)
  }

  // MARK: Source Control (the new ones)

  /// ⌥⇧⌘F = Fetch, ⌥⇧⌘P = Pull with Rebase. Three-modifier combinations fail every other branch in the
  /// classifier, so they need their own — which is exactly the kind of gap that has bitten before.
  func testSourceControlThreeModifierShortcutsAreReserved() {
    XCTAssertTrue(reserved("f", [.command, .shift, .option]), "⌥⇧⌘F = Fetch")
    XCTAssertTrue(reserved("p", [.command, .shift, .option]), "⌥⇧⌘P = Pull with Rebase")
  }

  /// ⇧⌘P = Push.
  func testPushIsReserved() {
    XCTAssertTrue(reserved("p", [.command, .shift]), "⇧⌘P = Push")
  }

  /// Every Source Control shortcut, checked against the menu's own declarations.
  func testEverySourceControlShortcutIsReserved() {
    let menuShortcuts: [(String, NSEvent.ModifierFlags, String)] = [
      ("f", [.command, .shift, .option], "Fetch"),
      ("p", [.command, .shift], "Push"),
      ("p", [.command, .shift, .option], "Pull with Rebase"),
    ]
    for (key, flags, name) in menuShortcuts {
      XCTAssertTrue(
        reserved(key, flags),
        "\(name)'s shortcut isn't reserved — a focused TUI will swallow it and the menu item will "
          + "look broken only while an agent is running")
    }
  }

  // MARK: Regression guard for the combinations already reserved

  func testExistingShiftCommandShortcutsStayReserved() {
    for key in ["d", "g", "k", "l", "n", "r"] {
      XCTAssertTrue(reserved(key, [.command, .shift]), "⇧⌘\(key.uppercased())")
    }
  }

  func testExistingOptionCommandShortcutsStayReserved() {
    for key in ["r", "c", "f", "y", "p", "s", "b"] {
      XCTAssertTrue(reserved(key, [.command, .option]), "⌥⌘\(key.uppercased())")
    }
  }

  func testExistingCommandOnlyShortcutsStayReserved() {
    for key in ["n", "t", "w", "o", "d", "q", "h", "m", ",", "[", "]", "r", "f", "g", "b"] {
      XCTAssertTrue(reserved(key, .command), "⌘\(key)")
    }
    for digit in 1...9 {
      XCTAssertTrue(reserved("\(digit)", .command), "⌘\(digit)")
    }
  }

  /// ⌥⌘←/→ and ⇧⌥⌘←/→ are matched by key CODE, because `charactersIgnoringModifiers` returns a
  /// function-key sentinel for arrows rather than a letter.
  func testArrowTabNavigationIsReservedByKeyCode() {
    for code: UInt16 in [123, 124] {
      XCTAssertTrue(reserved("\u{F702}", [.command, .option], keyCode: code))
      XCTAssertTrue(reserved("\u{F702}", [.command, .option, .shift], keyCode: code))
    }
  }

  /// ⌃⌘arrows is split-pane focus — monitor-only with no menu item, so it deliberately passes through
  /// to the terminal at a split's edge.
  func testControlCommandArrowsStayUnreserved() {
    for code: UInt16 in [123, 124] {
      XCTAssertFalse(reserved("\u{F702}", [.command, .control], keyCode: code))
    }
  }

  // MARK: Things that must NOT be reserved

  /// The allowlist is deliberately minimal — anything not a Workroom menu command belongs to the
  /// terminal. Over-reserving is as much a bug as under-reserving: it silently breaks a TUI's own keys.
  func testOrdinaryTerminalKeysArePassedThrough() {
    XCTAssertFalse(reserved("a", []), "plain letters")
    XCTAssertFalse(reserved("c", .command), "⌘C is copy — libghostty's")
    XCTAssertFalse(reserved("v", .command), "⌘V is paste")
    XCTAssertFalse(reserved("z", .command))
    XCTAssertFalse(reserved("c", .control), "⌃C must always reach the terminal")
    XCTAssertFalse(reserved("a", [.command, .shift]))
    XCTAssertFalse(reserved("x", [.command, .shift, .option]), "not a Source Control key")
  }

  /// ⌥⌘N was the Notifications inspector toggle; removed with issue #118, so it must no longer be
  /// reserved. Pinned because a stale reservation steals a key from the terminal for nothing.
  func testRemovedShortcutIsNoLongerReserved() {
    XCTAssertFalse(reserved("n", [.command, .option]), "⌥⌘N was removed with issue #118")
  }

  func testEmptyCharactersAreNotReserved() {
    XCTAssertFalse(
      GhosttySurfaceView.isAppShortcut(
        modifierFlags: .command, keyCode: 0, charactersIgnoringModifiers: nil))
    XCTAssertFalse(
      GhosttySurfaceView.isAppShortcut(
        modifierFlags: .command, keyCode: 0, charactersIgnoringModifiers: ""))
  }

  /// Uppercase arrives when Shift is held; the classifier lowercases before matching.
  func testUppercaseCharactersMatch() {
    XCTAssertTrue(reserved("P", [.command, .shift]), "⇧⌘P arrives as 'P'")
    XCTAssertTrue(reserved("F", [.command, .shift, .option]))
  }
}
