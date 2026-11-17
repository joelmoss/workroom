import AppKit
import DesignSystem
import Observation
import SwiftUI

/// Records keys for Settings ▸ Keyboard Shortcuts (#148): one row at a time, or the search field's
/// record button. Click, press the keys, done; Escape cancels.
///
/// While it records, `Shortcuts.isRecording` is on: the app's key monitor stands down and the global
/// hotkeys are let go, so every press, including ⌘W and the keys a global shortcut holds, reaches
/// this recorder rather than acting.
@MainActor
@Observable
final class ShortcutRecorderModel {
  /// What a recording is for.
  enum Target: Equatable {
    case action(ShortcutAction)
    /// The search field's: find the row holding the keys.
    case search
  }

  /// A recorded shortcut that takes keys other actions hold, awaiting the user's say.
  struct PendingConflict: Identifiable, Equatable {
    let id = UUID()
    let action: ShortcutAction
    let binding: ShortcutBinding
    let conflicts: [ShortcutAction]
  }

  private(set) var target: Target?
  /// Why the last press was refused, by row.
  private(set) var problems: [ShortcutAction: String] = [:]
  var pending: PendingConflict?
  /// The keys the search's record button caught.
  var searchChord: KeyChord?

  private let shortcuts: Shortcuts
  private let isGloballyAvailable: (KeyChord) -> Bool
  @ObservationIgnored private var monitor: Any?
  @ObservationIgnored private var resignObserver: NSObjectProtocol?

  init(
    shortcuts: Shortcuts = .shared,
    isGloballyAvailable: @escaping (KeyChord) -> Bool = GlobalHotkey.isAvailable
  ) {
    self.shortcuts = shortcuts
    self.isGloballyAvailable = isGloballyAvailable
  }

  func isRecording(_ target: Target) -> Bool { self.target == target }

  func toggle(_ target: Target) {
    self.target == target ? stop() : start(target)
  }

  func start(_ target: Target) {
    stop()
    if case .action(let action) = target { problems[action] = nil }
    self.target = target
    shortcuts.isRecording = true
    // Local: only this app's key presses, while Settings is in front. Returning nil keeps the keys
    // from also reaching the menu or the focused control.
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let chord = KeyChord(event)
      MainActor.assumeIsolated { self?.record(chord) }
      return nil
    }
    // Clicking away, or another window coming forward, ends it: keys pressed there aren't for it.
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = nil
    target = nil
    shortcuts.isRecording = false
  }

  /// One press while recording.
  func record(_ chord: KeyChord?) {
    switch target {
    case .search:
      if chord?.keyCode == KeyChord.escapeKeyCode, chord?.modifiers.isEmpty == true {
        return stop()
      }
      searchChord = chord
      stop()
    case .action(let action):
      switch ShortcutRecording.verdict(
        for: action, chord: chord, table: shortcuts.table,
        isGloballyAvailable: isGloballyAvailable)
      {
      case .cancel:
        stop()
      case .refuse(let reason):
        // Keep recording, so the next press is the next try.
        problems[action] = reason
      case .accept(let binding, let conflicts):
        problems[action] = nil
        stop()
        if conflicts.isEmpty {
          shortcuts.set(binding, for: action)
        } else {
          pending = PendingConflict(action: action, binding: binding, conflicts: conflicts)
        }
      }
    case nil:
      break
    }
  }

  /// Reset: back to the default. A default whose keys another action holds asks, as recording
  /// those keys would, rather than staying unset: whether the row was displaced, rebound or unset.
  /// Nothing changes until the alert's Use, so Cancel keeps the row as it was.
  func reset(_ action: ShortcutAction) {
    stop()
    let table = shortcuts.table
    guard let binding = action.defaultBinding else { return shortcuts.reset(action) }
    let conflicts = table.conflicts(assigning: binding, to: action)
    if let pinned = conflicts.first(where: { table.resolved[$0]?.source == .systemSettings }) {
      problems[action] = "System Settings sets those keys for \(pinned.label)."
      return
    }
    guard !conflicts.isEmpty else { return shortcuts.reset(action) }
    pending = PendingConflict(action: action, binding: binding, conflicts: conflicts)
  }

  /// The alert's "Use for …": take the keys, unsetting their holders.
  func confirm(_ pending: PendingConflict) {
    shortcuts.set(pending.binding, for: pending.action, unsetting: pending.conflicts)
    self.pending = nil
  }
}

/// A row's recorder: shows the shortcut, or "Record shortcut" when it has none, and records a
/// new one when clicked. Drawn as a field, with a hover fill, rather than a push button.
struct ShortcutRecorderButton: View {
  let action: ShortcutAction
  let model: ShortcutRecorderModel
  let table: ShortcutTable
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let recording = model.isRecording(.action(action))
    let keys = table.label(for: action)
    Button {
      model.toggle(.action(action))
    } label: {
      Group {
        if recording {
          Text("Type Shortcut…")
        } else if let keys {
          ShortcutKeysText(keys)
        } else {
          // No shortcut: muted and smaller, so the bound rows stand out. A hidden key glyph in
          // the keys' own font keeps the field exactly as tall as one showing keys.
          ZStack {
            ShortcutKeysText("⌘").hidden()
            Text("Record shortcut")
              .font(.callout)
              .foregroundStyle(tokens.fgMuted)
          }
        }
      }
      .frame(minWidth: 112)
    }
    .buttonStyle(ShortcutFieldStyle(recording: recording))
    .help(recording ? "Press the new keys, or Escape to cancel." : "Record a new shortcut.")
    .accessibilityLabel(
      recording
        ? "Recording shortcut for \(action.label)"
        : "\(action.label) shortcut \(keys ?? "None")"
    )
    .accessibilityIdentifier("settings.shortcuts.record.\(action.rawValue)")
  }
}

/// The recorder's field: a bordered well that fills more strongly on hover and takes the accent while recording.
private struct ShortcutFieldStyle: ButtonStyle {
  let recording: Bool

  func makeBody(configuration: Configuration) -> some View {
    Field(configuration: configuration, recording: recording)
  }

  private struct Field: View {
    let configuration: Configuration
    let recording: Bool
    @Environment(\.themeTokens) private var tokens
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
      configuration.label
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          shape.fill(
            recording
              ? tokens.accentSoft
              : (hovering && isEnabled || configuration.isPressed
                ? tokens.tabActive : tokens.surface))
        )
        .overlay(shape.strokeBorder(recording ? tokens.accent : tokens.border, lineWidth: 1))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
  }
}

/// A shortcut's glyphs ("⇧⌘P"), monospaced and spaced apart: run together, the modifier glyphs are
/// hard to tell apart.
struct ShortcutKeysText: View {
  let keys: String

  init(_ keys: String) { self.keys = keys }

  var body: some View {
    Text(keys)
      .font(.system(.body, design: .monospaced))
      .tracking(3)
  }
}
