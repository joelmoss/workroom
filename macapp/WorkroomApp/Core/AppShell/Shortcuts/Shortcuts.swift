import AppKit
import Defaults
import Observation
import os

extension Defaults.Keys {
  /// `Shortcuts.overridesKey` as `Defaults` sees it: the user's changes, a dictionary of JSON
  /// strings. Only `@Default` reads it, in the menu bar, whose `Commands` body Observation doesn't
  /// re-run when `Shortcuts.shared` changes; a write to the key does.
  static let shortcutOverridesRaw = Key<[String: String]>(
    Shortcuts.overridesKey, default: [:], suite: .app)
}

/// Every shortcut Workroom has, the one place the menus, the key monitor, the terminal's reserved
/// keys, the global hotkeys and Settings read them from (#148, ADR 0076).
@MainActor
@Observable
final class Shortcuts {
  static let shared = Shortcuts(publishes: true)

  /// The bindings in effect. Views and menus read this, so they follow every change.
  private(set) var table: ShortcutTable
  /// True while a Settings row records keys: the key monitor stands down, and the global hotkeys
  /// are let go so the keys they hold can be recorded again.
  var isRecording = false {
    didSet {
      guard isRecording != oldValue else { return }
      let recording = isRecording
      if publishes { Self.recordingFlag.withLock { $0 = recording } }
      NotificationCenter.default.post(name: .shortcutsGlobalsChanged, object: nil)
    }
  }

  /// The user's changes to shortcuts, by `ShortcutAction` id: rebinds and explicit removals only
  /// (#148, ADR 0076). A dictionary of JSON strings, in `UserDefaults.app`.
  nonisolated static let overridesKey = "shortcuts.overrides"
  /// Set once the settings Settings ▸ Keyboard Shortcuts replaced have been carried over.
  nonisolated static let migratedKey = "shortcuts.migrated"

  private let suite: UserDefaults
  private let systemSettings: () -> [String: KeyChord]
  /// Whether this is the app's registry, the one the key monitor and the terminal read through
  /// `current` and `recording`. A test's registry, on a suite of its own, must not change what the
  /// rest of the process sees.
  private let publishes: Bool

  init(
    suite: UserDefaults = .app,
    systemSettings: @escaping () -> [String: KeyChord] = { Shortcuts.readSystemSettings(.app) },
    publishes: Bool = false
  ) {
    self.suite = suite
    self.systemSettings = systemSettings
    self.publishes = publishes
    Self.migrate(suite)
    let overrides = Self.overrides(in: suite)
    self.overrides = overrides
    self.table = ShortcutTable(overrides: overrides, systemSettings: systemSettings())
    publish()
  }

  // MARK: Reading off the main actor

  private nonisolated static let snapshot = OSAllocatedUnfairLock(
    initialState: ShortcutTable.defaults)
  private nonisolated static let recordingFlag = OSAllocatedUnfairLock(initialState: false)

  /// The bindings in effect, for the key monitor and the terminal view, which run on every key
  /// press and outside the main actor's isolation.
  nonisolated static var current: ShortcutTable { snapshot.withLock { $0 } }
  nonisolated static var recording: Bool { recordingFlag.withLock { $0 } }

  // MARK: Changing them

  /// The saved changes, as last read from or written to the suite.
  private(set) var overrides: [String: ShortcutOverride]

  /// Bind `binding` to `action`, unsetting each action in `unsetting` (the conflicts the user
  /// agreed to give up).
  func set(_ binding: ShortcutBinding, for action: ShortcutAction, unsetting: [ShortcutAction] = [])
  {
    var changes = overrides
    changes[action.rawValue] =
      binding == action.defaultBinding && table.resolved[action]?.displacedBy == nil
      ? nil : .bound(binding)
    for other in unsetting where other != action {
      changes[other.rawValue] = other.defaultBinding == nil ? nil : .unset
    }
    save(changes)
  }

  /// Remove `action`'s shortcut.
  func unset(_ action: ShortcutAction) {
    var changes = overrides
    changes[action.rawValue] = action.defaultBinding == nil ? nil : .unset
    save(changes)
  }

  /// Back to the default. A default other keys took meanwhile stays unset, as the table resolves it.
  func reset(_ action: ShortcutAction) {
    var changes = overrides
    changes[action.rawValue] = nil
    save(changes)
  }

  /// How many shortcuts the user changed, for Restore Defaults' confirmation.
  var customCount: Int {
    overrides.keys.count { ShortcutAction(rawValue: $0) != nil }
  }

  func restoreDefaults() { save([:]) }

  /// Read the saved changes and System Settings' App Shortcuts again: the latter change outside
  /// the app, and a fixture launch clears the former in the suite.
  func refreshSystemSettings() {
    overrides = Self.overrides(in: suite)
    rebuild()
  }

  private func save(_ changes: [String: ShortcutOverride]) {
    suite.set(Self.encode(changes), forKey: Self.overridesKey)
    overrides = changes
    rebuild()
  }

  private func rebuild() {
    let table = ShortcutTable(overrides: overrides, systemSettings: systemSettings())
    guard table != self.table else { return }
    let globalsChanged =
      ShortcutAction.allCases.filter(\.isGlobal).contains {
        table.binding(for: $0) != self.table.binding(for: $0)
      }
    self.table = table
    publish()
    if globalsChanged {
      NotificationCenter.default.post(name: .shortcutsGlobalsChanged, object: nil)
    }
  }

  /// Hand the table to the key monitor and the terminal view: the app's registry only.
  private func publish() {
    guard publishes else { return }
    let table = table
    Self.snapshot.withLock { $0 = table }
  }

  // MARK: Storage

  /// Read through the suite rather than a `Defaults.Key`, whose suite is fixed at declaration, so
  /// a test can hand the registry a suite of its own. Changes saved by a version that doesn't
  /// know an action, or can't read its shape, are skipped rather than failing the rest.
  static func overrides(in suite: UserDefaults) -> [String: ShortcutOverride] {
    guard let raw = suite.dictionary(forKey: Self.overridesKey) else {
      return [:]
    }
    var overrides: [String: ShortcutOverride] = [:]
    for (id, value) in raw {
      guard let text = value as? String, let data = text.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(ShortcutOverride.self, from: data)
      else { continue }
      overrides[id] = decoded
    }
    return overrides
  }

  /// The same shape `Defaults` writes a `[String: Codable]` in: a dictionary of JSON strings.
  static func encode(_ overrides: [String: ShortcutOverride]) -> [String: String] {
    overrides.compactMapValues { value in
      (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
  }

  // MARK: System Settings

  /// System Settings ▸ Keyboard ▸ App Shortcuts, as macOS stores them: menu title → key equivalent,
  /// in the app's domain (this app) merged over the global one (All Applications).
  nonisolated static func readSystemSettings(_ defaults: UserDefaults) -> [String: KeyChord] {
    guard let raw = defaults.dictionary(forKey: "NSUserKeyEquivalents") else { return [:] }
    return raw.compactMapValues { ($0 as? String).flatMap(KeyChord.init(userKeyEquivalent:)) }
  }

}

extension Notification.Name {
  /// A global shortcut changed, or recording started or stopped: `AppDelegate` registers its
  /// hotkeys again.
  static let shortcutsGlobalsChanged = Notification.Name("workroom.shortcutsGlobalsChanged")
}
