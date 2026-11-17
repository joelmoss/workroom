import Foundation

/// What a key press made while recording a shortcut becomes (#148). Pure, apart from the injected
/// probe for a global shortcut another app holds.
enum ShortcutRecording {
  enum Verdict: Equatable {
    /// Use it. `conflicts` are the actions it would take keys from: empty, it's free.
    case accept(ShortcutBinding, conflicts: [ShortcutAction])
    /// Keep the current shortcut, and say why.
    case refuse(String)
    /// Escape: stop recording, nothing changed.
    case cancel
  }

  /// - Parameters:
  ///   - chord: the press, or nil for a key that can't be one.
  ///   - isGloballyAvailable: whether a global shortcut can be registered, false when another app
  ///     holds it. Asked only for a global action, and only for keys it doesn't already have.
  static func verdict(
    for action: ShortcutAction, chord: KeyChord?, table: ShortcutTable,
    isGloballyAvailable: (KeyChord) -> Bool
  ) -> Verdict {
    guard let chord else { return .refuse("That key can't be a shortcut.") }
    if chord.keyCode == KeyChord.escapeKeyCode, chord.modifiers.isEmpty { return .cancel }
    // A shortcut is pressed with ⌘, ⌥ or ⌃ (⇧ alone is typing). Only a single shortcut may be a
    // bare F-key: a switcher's keys are always held with modifiers.
    let needsPrimary = "Include ⌘, ⌥ or ⌃."
    let primary = chord.modifiers.subtracting(.shift).hasPrimary

    let binding: ShortcutBinding
    switch action.kind {
    case .switcher:
      guard chord.keyCode == KeyChord.tabKeyCode, chord.isNamed else {
        return .refuse("This switcher steps with Tab; choose its modifiers.")
      }
      // ⇧ steps back, so it is never part of the trigger.
      let modifiers = chord.modifiers.subtracting(.shift)
      guard primary else { return .refuse(needsPrimary) }
      if modifiers == .command { return .refuse("⌘⇥ switches apps in macOS.") }
      binding = .modifiers(modifiers)
    case .single:
      guard primary || chord.isFunctionKey else { return .refuse(needsPrimary) }
      binding = .chord(chord)
    }

    // Nothing changes: no conflict with itself, and no probe its own registration would fail.
    if table.binding(for: action) == binding { return .accept(binding, conflicts: []) }

    for chord in ShortcutTable.chords(for: action, binding) {
      if let standard = StandardShortcut.all.first(where: { $0.chord == chord }) {
        return .refuse("\(chord.label) is \(standard.name), a standard macOS shortcut.")
      }
    }
    let conflicts = table.conflicts(assigning: binding, to: action)
    // System Settings' own App Shortcuts can't be unset from here.
    if let pinned = conflicts.first(where: { table.resolved[$0]?.source == .systemSettings }) {
      return .refuse("System Settings sets that for \(pinned.label).")
    }
    if action.isGlobal, case .chord(let chord) = binding, !isGloballyAvailable(chord),
      !conflicts.contains(where: \.isGlobal)
    {
      return .refuse("Another app uses that shortcut.")
    }
    return .accept(binding, conflicts: conflicts)
  }

  /// The note under a row whose keys a terminal program would otherwise get: an in-app shortcut
  /// with no ⌘. One that hands its keys back when it can't act (a switcher with nothing to switch
  /// to) says when the terminal still gets them. Nil otherwise.
  static func terminalNote(for action: ShortcutAction, _ binding: ShortcutBinding?) -> String? {
    guard let binding, !action.isGlobal else { return nil }
    guard !binding.heldModifiers.contains(.command) else { return nil }
    let keys = ShortcutTable.label(for: action, binding)
    guard action.reservesFromTerminal else {
      return "Terminal programs get \(keys) only when \(action.label) has nothing to do."
    }
    return "Terminal programs will no longer get \(keys)."
  }

  /// The alert's message for keys other actions hold.
  static func conflictMessage(
    for action: ShortcutAction, _ binding: ShortcutBinding, conflicts: [ShortcutAction]
  ) -> String {
    let keys = ShortcutTable.label(for: action, binding)
    let names = conflicts.map(\.label)
    let used = ListFormatter.localizedString(byJoining: names)
    let loses =
      conflicts.count == 1
      ? "\(names[0]) will have no shortcut."
      : "They will have no shortcut."
    return "\(keys) is used by \(used). Use it for \(action.label) instead? \(loses)"
  }
}
