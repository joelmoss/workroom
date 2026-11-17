import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The modifier keys a shortcut holds, in one spelling for AppKit, SwiftUI and Carbon (#148).
struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
  let rawValue: Int

  static let control = KeyModifiers(rawValue: 1 << 0)
  static let option = KeyModifiers(rawValue: 1 << 1)
  static let shift = KeyModifiers(rawValue: 1 << 2)
  static let command = KeyModifiers(rawValue: 1 << 3)

  init(rawValue: Int) { self.rawValue = rawValue }

  /// The four modifiers an event carries, ignoring Caps Lock, Fn and the numeric-pad flag.
  init(_ flags: NSEvent.ModifierFlags) {
    var modifiers: KeyModifiers = []
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.command) }
    self = modifiers
  }

  /// Whether it holds ⌘, ⌥ or ⌃: what makes a key press a shortcut rather than typing.
  var hasPrimary: Bool { !isDisjoint(with: [.command, .option, .control]) }

  /// "⌃⌥⇧⌘", in the order macOS menus list modifiers.
  var glyphs: String {
    var glyphs = ""
    if contains(.control) { glyphs += "⌃" }
    if contains(.option) { glyphs += "⌥" }
    if contains(.shift) { glyphs += "⇧" }
    if contains(.command) { glyphs += "⌘" }
    return glyphs
  }

  /// The words a search for these modifiers may use.
  var names: [String] {
    var names: [String] = []
    if contains(.control) { names += ["control", "ctrl"] }
    if contains(.option) { names += ["option", "opt", "alt"] }
    if contains(.shift) { names += ["shift"] }
    if contains(.command) { names += ["command", "cmd"] }
    return names
  }

  var eventFlags: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if contains(.control) { flags.insert(.control) }
    if contains(.option) { flags.insert(.option) }
    if contains(.shift) { flags.insert(.shift) }
    if contains(.command) { flags.insert(.command) }
    return flags
  }

  var eventModifiers: SwiftUI.EventModifiers {
    var modifiers: SwiftUI.EventModifiers = []
    if contains(.control) { modifiers.insert(.control) }
    if contains(.option) { modifiers.insert(.option) }
    if contains(.shift) { modifiers.insert(.shift) }
    if contains(.command) { modifiers.insert(.command) }
    return modifiers
  }

  /// A Carbon modifier mask, for `RegisterEventHotKey`.
  var carbon: Int {
    var mask = 0
    if contains(.control) { mask |= controlKey }
    if contains(.option) { mask |= optionKey }
    if contains(.shift) { mask |= shiftKey }
    if contains(.command) { mask |= cmdKey }
    return mask
  }

  init(carbon mask: Int) {
    var modifiers: KeyModifiers = []
    if mask & controlKey != 0 { modifiers.insert(.control) }
    if mask & optionKey != 0 { modifiers.insert(.option) }
    if mask & shiftKey != 0 { modifiers.insert(.shift) }
    if mask & cmdKey != 0 { modifiers.insert(.command) }
    self = modifiers
  }
}

/// One key press as a shortcut: modifiers plus a key (#148, ADR 0076).
///
/// Letters, digits and punctuation are matched by `character`, the key's unshifted character on the
/// layout it was pressed on, as macOS menus match: a shortcut reads as the key you press. Named keys
/// (arrows, Tab, Return, Space, Delete, Escape, the paging keys and F1–F12) have no `character` and
/// are matched by `keyCode`, which does not move between layouts. `keyCode` is kept for every chord,
/// because a global shortcut is registered with Carbon by key code.
struct KeyChord: Codable, Hashable, Sendable {
  var modifiers: KeyModifiers
  /// The virtual key code (`kVK_*`), or -1 for a default whose key has no fixed code.
  var keyCode: Int
  /// The unshifted character, lowercased; nil for a named key.
  var character: String?

  init(modifiers: KeyModifiers, keyCode: Int, character: String?) {
    self.modifiers = modifiers
    self.keyCode = keyCode
    self.character = character
  }

  /// A character key, as the catalog's defaults are written.
  static func key(_ character: String, _ modifiers: KeyModifiers) -> KeyChord {
    let character = character.lowercased()
    return KeyChord(
      modifiers: modifiers, keyCode: Self.ansiKeyCodes[character] ?? -1, character: character)
  }

  /// A named key, by its virtual key code.
  static func named(_ keyCode: Int, _ modifiers: KeyModifiers) -> KeyChord {
    KeyChord(modifiers: modifiers, keyCode: keyCode, character: nil)
  }

  /// A key press as a chord, or nil for a key that can't be one (a dead key, or one with no
  /// character). `unshifted` is the key's character without ⇧ (`KeyChord.unshifted(_:)`). Says
  /// nothing about whether the press is allowed as a shortcut: that is `ShortcutRecording`'s call.
  init?(keyCode: Int, flags: NSEvent.ModifierFlags, unshifted: String?) {
    let modifiers = KeyModifiers(flags)
    if Self.namedKeys[keyCode] != nil {
      self.init(modifiers: modifiers, keyCode: keyCode, character: nil)
      return
    }
    guard let unshifted, let scalar = unshifted.unicodeScalars.first,
      !Self.isUnprintable(scalar)
    else { return nil }
    self.init(modifiers: modifiers, keyCode: keyCode, character: unshifted.lowercased())
  }

  /// The chord a key event is, from `NSEvent`'s parts.
  init?(_ event: NSEvent) {
    guard event.type == .keyDown || event.type == .keyUp else { return nil }
    self.init(
      keyCode: Int(event.keyCode), flags: event.modifierFlags, unshifted: Self.unshifted(event))
  }

  /// The key's character with every modifier but ⌘ left out. Shift is, so ⇧⌘` reads as "`", not
  /// "~". ⌘ is kept because a held ⌘ picks the layout's ⌘ layer: on a non-Latin layout (Russian,
  /// Greek, Hebrew) that is the Latin letter macOS menus match, where no modifiers at all gives the
  /// layout's own letter and ⌘T would never be ⌘T.
  static func unshifted(_ event: NSEvent) -> String? {
    event.characters(byApplyingModifiers: event.modifierFlags.intersection(.command))
      ?? event.charactersIgnoringModifiers
  }

  private static func isUnprintable(_ scalar: Unicode.Scalar) -> Bool {
    // Controls, and AppKit's function-key range (NSUpArrowFunctionKey and friends).
    scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value)
  }

  // MARK: Equality

  /// What makes two chords the same shortcut: their modifiers, and their character, or their key
  /// code for a named key.
  private var identity: String {
    if let character { return "\(modifiers.rawValue)c\(character)" }
    return "\(modifiers.rawValue)k\(keyCode)"
  }

  static func == (lhs: KeyChord, rhs: KeyChord) -> Bool { lhs.identity == rhs.identity }
  func hash(into hasher: inout Hasher) { hasher.combine(identity) }

  func with(modifiers: KeyModifiers) -> KeyChord {
    KeyChord(modifiers: modifiers, keyCode: keyCode, character: character)
  }

  // MARK: Reading it

  var isNamed: Bool { character == nil }
  var isFunctionKey: Bool { Self.functionKeyCodes.contains(keyCode) && character == nil }

  /// The key alone: "T", "§", "←", "F5".
  var keyLabel: String {
    if let character { return character.uppercased() }
    return Self.namedKeys[keyCode]?.label ?? "?"
  }

  /// "⌃⌥⇧⌘K".
  var label: String { modifiers.glyphs + keyLabel }

  /// The words a search for this chord may use: modifier names and the key's own name.
  var searchNames: [String] {
    var names = modifiers.names
    if let character {
      names.append(character)
    } else {
      names += Self.namedKeys[keyCode]?.names ?? []
    }
    return names
  }

  /// The menu item's key equivalent.
  var keyboardShortcut: KeyboardShortcut? {
    guard let equivalent = keyEquivalent else { return nil }
    return KeyboardShortcut(equivalent, modifiers: modifiers.eventModifiers)
  }

  var keyEquivalent: KeyEquivalent? {
    if let character, let first = character.first { return KeyEquivalent(first) }
    return Self.namedKeys[keyCode].map { KeyEquivalent($0.equivalent) }
  }

  // MARK: Keys

  static let escapeKeyCode = kVK_Escape
  static let tabKeyCode = kVK_Tab
  static let arrowKeyCodes = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
  static let functionKeyCodes: [Int] = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
    kVK_F12,
  ]

  /// Keys whose character is unprintable, blank or layout-free: named, and matched by key code.
  static let namedKeys: [Int: (label: String, equivalent: Character, names: [String])] = {
    var keys: [Int: (label: String, equivalent: Character, names: [String])] = [
      kVK_Space: ("Space", " ", ["space"]),
      kVK_Return: ("↩", "\r", ["return", "enter"]),
      kVK_ANSI_KeypadEnter: ("⌤", "\u{3}", ["enter"]),
      kVK_Tab: ("⇥", "\t", ["tab"]),
      kVK_Delete: ("⌫", KeyEquivalent.delete.character, ["delete", "backspace"]),
      kVK_ForwardDelete: ("⌦", KeyEquivalent.deleteForward.character, ["delete", "forward"]),
      kVK_Escape: ("⎋", KeyEquivalent.escape.character, ["escape", "esc"]),
      kVK_LeftArrow: ("←", functionKey(NSLeftArrowFunctionKey), ["left", "arrow"]),
      kVK_RightArrow: ("→", functionKey(NSRightArrowFunctionKey), ["right", "arrow"]),
      kVK_UpArrow: ("↑", functionKey(NSUpArrowFunctionKey), ["up", "arrow"]),
      kVK_DownArrow: ("↓", functionKey(NSDownArrowFunctionKey), ["down", "arrow"]),
      kVK_Home: ("↖", functionKey(NSHomeFunctionKey), ["home"]),
      kVK_End: ("↘", functionKey(NSEndFunctionKey), ["end"]),
      kVK_PageUp: ("⇞", functionKey(NSPageUpFunctionKey), ["page", "up"]),
      kVK_PageDown: ("⇟", functionKey(NSPageDownFunctionKey), ["page", "down"]),
    ]
    for (index, code) in functionKeyCodes.enumerated() {
      keys[code] = ("F\(index + 1)", functionKey(NSF1FunctionKey + index), ["f\(index + 1)"])
    }
    return keys
  }()

  /// The named key an AppKit function-key character stands for, as `NSUserKeyEquivalents` writes
  /// arrows and F-keys.
  static func namedKeyCode(forEquivalent character: Character) -> Int? {
    namedKeys.first { $0.value.equivalent == character }?.key
  }

  private static func functionKey(_ code: Int) -> Character {
    Character(UnicodeScalar(UInt16(code))!)
  }

  /// US key codes for the characters the catalog's defaults use, so a default global shortcut can
  /// be registered. A recorded chord carries the code of the key actually pressed.
  static let ansiKeyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
    "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
    "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    "z": kVK_ANSI_Z, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "0": kVK_ANSI_0, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ",": kVK_ANSI_Comma,
    ".": kVK_ANSI_Period, "`": kVK_ANSI_Grave, "§": kVK_ISO_Section, "/": kVK_ANSI_Slash,
    ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
    "\\": kVK_ANSI_Backslash,
  ]

  // MARK: System Settings ▸ Keyboard ▸ App Shortcuts

  /// A key equivalent as `NSUserKeyEquivalents` stores one: `@` ⌘, `~` ⌥, `^` ⌃, `$` ⇧, then the
  /// key. Nil for a string that isn't one.
  init?(userKeyEquivalent: String) {
    var modifiers: KeyModifiers = []
    var rest = Substring(userKeyEquivalent)
    while let first = rest.first, rest.count > 1, "@~^$".contains(first) {
      switch first {
      case "@": modifiers.insert(.command)
      case "~": modifiers.insert(.option)
      case "^": modifiers.insert(.control)
      default: modifiers.insert(.shift)
      }
      rest = rest.dropFirst()
    }
    guard rest.count == 1, let key = rest.first else { return nil }
    if let code = Self.namedKeyCode(forEquivalent: key) {
      self.init(modifiers: modifiers, keyCode: code, character: nil)
    } else {
      let character = String(key)
      if character != character.lowercased() { modifiers.insert(.shift) }
      self = .key(character, modifiers)
    }
  }
}
