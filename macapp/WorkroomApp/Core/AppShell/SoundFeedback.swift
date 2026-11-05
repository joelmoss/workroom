import AppKit

/// Admit sound before allocating work, so terminal output cannot build an audio-task backlog.
@MainActor
final class SoundFeedback {
  enum Kind: Hashable, Sendable {
    case notification
    case terminalBell

    var interval: Double { self == .notification ? 0.5 : 0.25 }
  }

  static let shared = SoundFeedback(
    now: { ProcessInfo.processInfo.systemUptime },
    play: playOffMain)

  nonisolated private static func playOffMain(_ kind: Kind) async {
    await SoundPlayer.shared.play(kind)
  }

  private var pending: Set<Kind> = []
  private var lastAccepted: [Kind: Double] = [:]
  private let now: () -> Double
  private let play: @Sendable (Kind) async -> Void

  init(
    now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
    play: @escaping @Sendable (Kind) async -> Void
  ) {
    self.now = now
    self.play = play
  }

  @discardableResult
  func request(_ kind: Kind) -> Task<Void, Never>? {
    guard !pending.contains(kind) else { return nil }
    let time = now()
    if let last = lastAccepted[kind], time - last < kind.interval { return nil }
    pending.insert(kind)
    lastAccepted[kind] = time
    return Task {
      await play(kind)
      pending.remove(kind)
    }
  }
}

/// Sound creation and playback calls are serialized off main. The actor retains its named sound
/// for playback's lifetime and never shares a mutable NSSound with the UI.
private actor SoundPlayer {
  static let shared = SoundPlayer()
  private var chime: NSSound?

  func play(_ kind: SoundFeedback.Kind) {
    switch kind {
    case .notification:
      if chime == nil { chime = NSSound(named: NotificationSound.name) }
      chime?.play()
    case .terminalBell:
      NSSound.beep()
    }
  }
}
