import Foundation

/// Carrying the settings Settings ▸ Keyboard Shortcuts replaced into the registry (#148).
extension Shortcuts {
  /// Carry the settings Settings ▸ Keyboard Shortcuts replaces into the user's changes, once: the
  /// Quick Terminal's recorded shortcut, the quick switchers' modifiers, and the global-hotkey
  /// toggle, whose Off leaves both global shortcuts unset. The old keys are then removed.
  /// The keys the settings before #148 were saved under, all removed once carried over.
  private enum LegacyKey {
    static let quickTerminal = "quickTerminalShortcut"
    static let workroomSwitcher = "switcher.workroomModifier"
    static let paneSwitcher = "switcher.paneModifier"
    static let globalHotkey = "globalHotkeyEnabled"
    static let all = [quickTerminal, workroomSwitcher, paneSwitcher, globalHotkey]
  }

  static func migrate(_ suite: UserDefaults) {
    let migrated = Self.migratedKey
    guard !suite.bool(forKey: migrated) else { return }
    defer { suite.set(true, forKey: migrated) }

    var changes = overrides(in: suite)
    if let quickTerminal = legacyGlobalShortcut(suite.object(forKey: LegacyKey.quickTerminal)),
      .chord(quickTerminal) != ShortcutAction.quickTerminal.defaultBinding
    {
      changes[ShortcutAction.quickTerminal.rawValue] = .bound(.chord(quickTerminal))
    }
    let switchers: [(String, ShortcutAction)] = [
      (LegacyKey.workroomSwitcher, .lastUsedWorkroom), (LegacyKey.paneSwitcher, .lastUsedPane),
    ]
    for (key, action) in switchers {
      guard let raw = suite.string(forKey: key), let modifiers = legacySwitcherModifiers(raw),
        .modifiers(modifiers) != action.defaultBinding
      else { continue }
      changes[action.rawValue] = .bound(.modifiers(modifiers))
    }
    // Only an explicit Off: never set means it was on.
    if suite.object(forKey: LegacyKey.globalHotkey) != nil,
      !suite.bool(forKey: LegacyKey.globalHotkey)
    {
      for action in ShortcutAction.allCases where action.isGlobal {
        changes[action.rawValue] = .unset
      }
    }
    suite.set(encode(changes), forKey: Self.overridesKey)
    LegacyKey.all.forEach(suite.removeObject(forKey:))
  }

  /// The Quick Terminal shortcut as it was saved before #148: `{keyCode, carbonModifiers, key}`.
  static func legacyGlobalShortcut(_ value: Any?) -> KeyChord? {
    struct Legacy: Decodable {
      let keyCode: Int
      let carbonModifiers: Int
      let key: String
    }
    let data: Data?
    switch value {
    case let text as String: data = text.data(using: .utf8)
    case let raw as Data: data = raw
    default: data = nil
    }
    guard let data, let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else {
      return nil
    }
    let modifiers = KeyModifiers(carbon: legacy.carbonModifiers)
    if KeyChord.namedKeys[legacy.keyCode] != nil { return .named(legacy.keyCode, modifiers) }
    return KeyChord(
      modifiers: modifiers, keyCode: legacy.keyCode, character: legacy.key.lowercased())
  }

  /// A quick switcher's modifier as it was saved before #148.
  static func legacySwitcherModifiers(_ raw: String) -> KeyModifiers? {
    switch raw {
    case "option": .option
    case "control": .control
    case "commandOption": [.command, .option]
    case "commandControl": [.command, .control]
    default: nil
    }
  }

}
