import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records a global shortcut: click, press the keys, done. Escape cancels. A shortcut another app,
/// or Workroom's own ⌘§, already holds is refused with the reason, keeping the current one.
struct ShortcutRecorder: View {
  @Binding var shortcut: GlobalShortcut
  var defaultShortcut = GlobalShortcut.quickTerminalDefault
  @State private var recording = false
  @State private var monitor: Any?
  @State private var problem: String?
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    HStack {
      if let problem {
        Text(problem)
          .font(.caption)
          .foregroundStyle(tokens.failure)
          .accessibilityIdentifier("settings.control.quickTerminalShortcutProblem")
      }
      if shortcut != defaultShortcut, !recording {
        Button("Reset") { shortcut = defaultShortcut }
          .help("Go back to \(defaultShortcut.label).")
          .accessibilityIdentifier("settings.control.quickTerminalShortcutReset")
      }
      Button(recording ? "Type Shortcut…" : shortcut.label) {
        recording ? stop() : start()
      }
      .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(shortcut.label)")
      .accessibilityIdentifier("settings.control.quickTerminalShortcut")
    }
    .onDisappear(perform: stop)
  }

  private func start() {
    problem = nil
    recording = true
    // Local: only this app's key presses, while Settings is in front. Returning nil keeps the keys
    // from also reaching the menu or the focused control.
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated { record(event) }
      return nil
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = false
  }

  private func record(_ event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if Int(event.keyCode) == kVK_Escape, flags.isEmpty { return stop() }
    switch Self.verdict(
      for: GlobalShortcut(
        keyCode: Int(event.keyCode), flags: flags,
        unshifted: event.characters(byApplyingModifiers: [])),
      current: shortcut, isAvailable: GlobalHotkey.isAvailable)
    {
    case .use(let recorded):
      shortcut = recorded
      problem = nil
      stop()
    case .refuse(let reason):
      // Keep recording, so the next press is the next try.
      problem = reason
    }
  }

  enum Verdict: Equatable {
    case use(GlobalShortcut)
    case refuse(String)
  }

  /// What a recorded press becomes. Pure, apart from the injected availability probe.
  static func verdict(
    for recorded: GlobalShortcut?, current: GlobalShortcut,
    isAvailable: (GlobalShortcut) -> Bool
  ) -> Verdict {
    guard let recorded else { return .refuse("Include ⌘, ⌥ or ⌃.") }
    // Our own registration holds the current one, so the probe would refuse it.
    if recorded == current { return .use(recorded) }
    if recorded == .showHide { return .refuse("Workroom's show/hide shortcut uses that.") }
    guard isAvailable(recorded) else { return .refuse("Another app uses that shortcut.") }
    return .use(recorded)
  }
}
