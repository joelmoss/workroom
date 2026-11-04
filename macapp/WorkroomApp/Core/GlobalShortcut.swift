import AppKit
import Carbon.HIToolbox
import Defaults
import SwiftUI

/// A system-wide shortcut the user records in Settings: what `GlobalHotkey` registers, what the menu
/// shows as the item's equivalent, and how it reads in the app.
struct GlobalShortcut: Codable, Equatable, Sendable, Defaults.Serializable {
  /// The virtual key code (`kVK_*`), layout-independent: what Carbon registers.
  var keyCode: Int
  /// A Carbon modifier mask (`cmdKey | optionKey | …`).
  var carbonModifiers: Int
  /// The key's unshifted character on the layout it was recorded with, for the menu equivalent and
  /// the label (special keys are named from `keyCode` instead).
  var key: String

  /// ⌥§ (`kVK_ISO_Section`): the Quick Terminal's shortcut until the user records another.
  static let quickTerminalDefault = GlobalShortcut(
    keyCode: kVK_ISO_Section, carbonModifiers: optionKey, key: "§")
  /// ⌘§, Workroom's own show/hide hotkey, which a recorded shortcut must not take.
  static let showHide = GlobalShortcut(
    keyCode: kVK_ISO_Section, carbonModifiers: cmdKey, key: "§")

  /// Keys whose character is unprintable or blank, named and given their menu equivalent.
  private static let specialKeys: [Int: (label: String, equivalent: Character)] = {
    var keys: [Int: (label: String, equivalent: Character)] = [
      kVK_Space: ("Space", " "), kVK_Return: ("↩", "\r"), kVK_Tab: ("⇥", "\t"),
      kVK_Delete: ("⌫", KeyEquivalent.delete.character),
      kVK_ForwardDelete: ("⌦", KeyEquivalent.deleteForward.character),
      kVK_LeftArrow: ("←", Self.functionKey(NSLeftArrowFunctionKey)),
      kVK_RightArrow: ("→", Self.functionKey(NSRightArrowFunctionKey)),
      kVK_UpArrow: ("↑", Self.functionKey(NSUpArrowFunctionKey)),
      kVK_DownArrow: ("↓", Self.functionKey(NSDownArrowFunctionKey)),
    ]
    let functionKeys = [
      kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
      kVK_F12,
    ]
    for (index, code) in functionKeys.enumerated() {
      keys[code] = ("F\(index + 1)", Self.functionKey(NSF1FunctionKey + index))
    }
    return keys
  }()

  private static func functionKey(_ code: Int) -> Character {
    Character(UnicodeScalar(UInt16(code))!)
  }

  /// A key press as a shortcut, or nil without ⌘, ⌥ or ⌃: a bare or shifted key would swallow
  /// ordinary typing in every app. `unshifted` is the key's character with no modifiers applied.
  init?(keyCode: Int, flags: NSEvent.ModifierFlags, unshifted: String?) {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
    let key = Self.specialKeys[keyCode].map { String($0.equivalent) } ?? unshifted?.lowercased()
    guard let key, !key.isEmpty else { return nil }
    var carbon = 0
    if flags.contains(.command) { carbon |= cmdKey }
    if flags.contains(.option) { carbon |= optionKey }
    if flags.contains(.control) { carbon |= controlKey }
    if flags.contains(.shift) { carbon |= shiftKey }
    self.init(keyCode: keyCode, carbonModifiers: carbon, key: key)
  }

  init(keyCode: Int, carbonModifiers: Int, key: String) {
    self.keyCode = keyCode
    self.carbonModifiers = carbonModifiers
    self.key = key
  }

  /// "⌃⌥⇧⌘K", in the order macOS menus list modifiers.
  var label: String {
    var label = ""
    if carbonModifiers & controlKey != 0 { label += "⌃" }
    if carbonModifiers & optionKey != 0 { label += "⌥" }
    if carbonModifiers & shiftKey != 0 { label += "⇧" }
    if carbonModifiers & cmdKey != 0 { label += "⌘" }
    return label + (Self.specialKeys[keyCode]?.label ?? key.uppercased())
  }

  /// The menu item's equivalent. In Release the registered hotkey takes the keys first, so the
  /// menu only shows it; in a Debug run, which registers none, the menu is what answers it.
  var keyboardShortcut: KeyboardShortcut? {
    guard let character = key.first else { return nil }
    var modifiers: SwiftUI.EventModifiers = []
    if carbonModifiers & cmdKey != 0 { modifiers.insert(.command) }
    if carbonModifiers & optionKey != 0 { modifiers.insert(.option) }
    if carbonModifiers & controlKey != 0 { modifiers.insert(.control) }
    if carbonModifiers & shiftKey != 0 { modifiers.insert(.shift) }
    return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
  }
}
