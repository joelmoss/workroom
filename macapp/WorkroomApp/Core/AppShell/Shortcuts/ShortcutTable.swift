import Foundation

/// A change the user made to one shortcut: what Settings saves, keyed by `ShortcutAction` id. Only
/// changes are saved, so a shortcut nobody touched follows the app's default (#148, ADR 0076).
enum ShortcutOverride: Codable, Hashable, Sendable {
  /// Removed: the action has no shortcut.
  case unset
  case bound(ShortcutBinding)
}

/// Where a shortcut's binding in effect came from.
enum ShortcutSource: Equatable, Sendable {
  /// The app's default.
  case standard
  /// Recorded, or removed, by the user in Settings.
  case user
  /// Set for its menu item in System Settings ▸ Keyboard ▸ App Shortcuts, which beats ours.
  case systemSettings
}

/// One action's shortcut as it is in effect.
struct ResolvedShortcut: Equatable, Sendable {
  let action: ShortcutAction
  /// Nil when it has none.
  let binding: ShortcutBinding?
  let source: ShortcutSource
  /// Set when its default was left unset because keys the user recorded for this action already
  /// held it: a default an update added after the user had taken those keys (ADR 0076).
  let displacedBy: ShortcutAction?

  init(
    action: ShortcutAction, binding: ShortcutBinding?, source: ShortcutSource,
    displacedBy: ShortcutAction? = nil
  ) {
    self.action = action
    self.binding = binding
    self.source = source
    self.displacedBy = displacedBy
  }

  /// Whether Settings shows Reset: the user changed it.
  var isCustom: Bool { source == .user }
}

/// A key press that is one of Workroom's shortcuts: the action, and for a switcher whether ⇧
/// makes it step back.
struct ShortcutMatch: Equatable, Sendable {
  let action: ShortcutAction
  let reverse: Bool

  init(_ action: ShortcutAction, reverse: Bool = false) {
    self.action = action
    self.reverse = reverse
  }
}

/// Every action's shortcut in effect, and the lookups the app makes of them: what a key press is,
/// what's kept from the terminal, what a new binding would collide with. Pure and `Sendable`, so
/// the key monitor and the terminal view read a snapshot of it without the main actor (#148).
struct ShortcutTable: Equatable, Sendable {
  let resolved: [ShortcutAction: ResolvedShortcut]
  private let index: [KeyChord: ShortcutMatch]
  /// Each bound action's chords, member by member, built once: menus ask on every evaluation.
  private let chords: [ShortcutAction: [KeyChord]]

  static let defaults = ShortcutTable(overrides: [:])

  /// - Parameters:
  ///   - overrides: the user's changes, by action id. Ids of actions that no longer exist are
  ///     ignored.
  ///   - systemSettings: System Settings' App Shortcuts, menu title → chord.
  init(
    overrides: [String: ShortcutOverride], systemSettings: [String: KeyChord] = [:]
  ) {
    var resolved: [ShortcutAction: ResolvedShortcut] = [:]
    // Pass 1: the user's changes and System Settings' are fixed; everything else is a default.
    var pinned: [KeyChord: ShortcutAction] = [:]
    for action in ShortcutAction.allCases {
      if case .single = action.kind,
        let chord = action.menuTitles.lazy.compactMap({ systemSettings[$0] }).first
      {
        resolved[action] = ResolvedShortcut(
          action: action, binding: .chord(chord), source: .systemSettings)
        pinned[chord] = pinned[chord] ?? action
        continue
      }
      switch overrides[action.rawValue] {
      case .unset:
        resolved[action] = ResolvedShortcut(action: action, binding: nil, source: .user)
      case .bound(let binding) where Self.fits(binding, action):
        resolved[action] = ResolvedShortcut(action: action, binding: binding, source: .user)
        for chord in Self.chords(for: action, binding) { pinned[chord] = pinned[chord] ?? action }
      default:
        break
      }
    }
    // Pass 2: a default the user's own keys already hold starts unset.
    for action in ShortcutAction.allCases where resolved[action] == nil {
      guard let binding = action.defaultBinding else {
        resolved[action] = ResolvedShortcut(action: action, binding: nil, source: .standard)
        continue
      }
      let holder = Self.chords(for: action, binding).lazy.compactMap { pinned[$0] }.first
      resolved[action] = ResolvedShortcut(
        action: action, binding: holder == nil ? binding : nil, source: .standard,
        displacedBy: holder)
    }
    self.resolved = resolved

    var index: [KeyChord: ShortcutMatch] = [:]
    var chords: [ShortcutAction: [KeyChord]] = [:]
    for action in ShortcutAction.allCases {
      guard let binding = resolved[action]?.binding else { continue }
      let matches = Self.matches(for: action, binding)
      chords[action] = matches.map(\.0)
      for (chord, match) in matches where index[chord] == nil {
        index[chord] = match
      }
    }
    self.index = index
    self.chords = chords
  }

  // MARK: Lookups

  func binding(for action: ShortcutAction) -> ShortcutBinding? { resolved[action]?.binding }

  /// The shortcut a key press is, if any.
  func match(_ chord: KeyChord) -> ShortcutMatch? { index[chord] }

  /// The chord an action is bound to: its own, or Tab with a switcher's modifiers. Nil when unset.
  func chord(for action: ShortcutAction) -> KeyChord? { chords[action]?.first }

  /// Whether a key press must be kept from a focused terminal: a bound action that reserves its
  /// keys, or a standard macOS item's that must reach its menu.
  func isReserved(_ chord: KeyChord) -> Bool {
    if let match = index[chord] { return match.action.reservesFromTerminal }
    return StandardShortcut.reserved.contains(chord)
  }

  /// "⌘T", "⌥⇥", or nil when unset.
  func label(for action: ShortcutAction) -> String? {
    binding(for: action).map { Self.label(for: action, $0) }
  }

  /// " (⌘R)" to put after a tooltip, or "" when the action has no shortcut.
  func hint(for action: ShortcutAction) -> String {
    label(for: action).map { " (\($0))" } ?? ""
  }

  // MARK: Conflicts

  /// The other actions a binding would take keys from, in catalog order.
  func conflicts(assigning binding: ShortcutBinding, to action: ShortcutAction) -> [ShortcutAction]
  {
    let wanted = Set(Self.chords(for: action, binding))
    return ShortcutAction.allCases.filter { other in
      guard other != action, let theirs = self.binding(for: other) else { return false }
      return !wanted.isDisjoint(with: Self.chords(for: other, theirs))
    }
  }

  // MARK: Shapes

  /// Whether a saved binding still has the shape its action takes (a chord for a single shortcut,
  /// modifiers otherwise), so a change saved by another version can't be misread.
  static func fits(_ binding: ShortcutBinding, _ action: ShortcutAction) -> Bool {
    switch (action.kind, binding) {
    case (.single, .chord), (.switcher, .modifiers): true
    default: false
    }
  }

  /// Every chord a binding takes: one for a single shortcut, and for a switcher Tab and ⇧Tab.
  static func chords(for action: ShortcutAction, _ binding: ShortcutBinding) -> [KeyChord] {
    matches(for: action, binding).map(\.0)
  }

  private static func matches(for action: ShortcutAction, _ binding: ShortcutBinding)
    -> [(KeyChord, ShortcutMatch)]
  {
    switch (action.kind, binding) {
    case (.single, .chord(let chord)):
      return [(chord, ShortcutMatch(action))]
    case (.switcher, .modifiers(let modifiers)):
      let tab = KeyChord.named(KeyChord.tabKeyCode, modifiers)
      return [
        (tab, ShortcutMatch(action)),
        (tab.with(modifiers: modifiers.union(.shift)), ShortcutMatch(action, reverse: true)),
      ]
    default:
      return []
    }
  }

  static func label(for action: ShortcutAction, _ binding: ShortcutBinding) -> String {
    switch (action.kind, binding) {
    case (.switcher, .modifiers(let modifiers)): modifiers.glyphs + "⇥"
    case (_, .chord(let chord)): chord.label
    case (_, .modifiers(let modifiers)): modifiers.glyphs
    }
  }

  /// The words a search for a binding may match: modifier and key names.
  static func searchNames(for action: ShortcutAction, _ binding: ShortcutBinding) -> [String] {
    switch (action.kind, binding) {
    case (.switcher, .modifiers(let modifiers)): modifiers.names + ["tab"]
    case (_, .chord(let chord)): chord.searchNames
    case (_, .modifiers(let modifiers)): modifiers.names
    }
  }
}
