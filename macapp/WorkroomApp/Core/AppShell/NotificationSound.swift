import AppKit

/// Plays the in-app arrival chime for a foreground notification (issue #31). macOS exposes no
/// public API to play the exact OS *default notification* sound from inside an app, so this uses a
/// built-in named system sound (the same library the Sound preferences pane lists). The native
/// banner keeps its own `UNNotificationSound.default` for the backgrounded case — the two paths are
/// mutually exclusive (see `NotificationGate`), so there's never a double chime.
///
/// The caller selects foreground arrivals; SoundFeedback shares burst chimes and runs audio setup
/// off main. Recording the notification and presenting its toast remain independent of the sound.
enum NotificationSound {
  /// The system sound name to play. `NSSound(named:)` resolves it from the standard sound library;
  /// returns nil (and we no-op) if the name is ever unavailable.
  static let name = NSSound.Name("Ping")

  @discardableResult
  @MainActor static func play() -> Task<Void, Never>? {
    SoundFeedback.shared.request(.notification)
  }
}
