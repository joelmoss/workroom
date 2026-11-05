import Foundation
import WorkroomDomain

/// A remote provider's first-time setup (`ExeDevSetup`, `BoxdSetup`): the steps a user it has never
/// seen goes through before their first workroom there, each checked from the provider itself, shown
/// in the provider's sheet on `RemoteSetupSheet`. A create that finds one needed holds here
/// (`PendingRemoteSetup`) and carries on from Create Workroom.
@MainActor
protocol RemoteSetup: AnyObject {
  /// Every step done, or its check couldn't answer (the provider's own error then decides).
  var isReady: Bool { get }
  /// The sheet is gone: stop every check and anything a step started.
  func cancel()
}

/// The provider setup sheet on screen in this window. Keyed on the provider: every create waiting
/// on it shares the one sheet (R2, #483), and its Create Workroom carries all of them on.
struct PendingRemoteSetup: Identifiable {
  let place: RemoteWorkrooms.Place
  let setup: any RemoteSetup
  var id: String { place.displayName }
}

/// The creates waiting on one provider's setup (R2, #483), in `ProjectStore.remoteSetupWaits`. A
/// create that finds setup missing while one is waiting for the same provider joins it rather than
/// raising a second sheet. Each waiting create resumes with true on Create Workroom, false on Cancel.
@MainActor
final class RemoteSetupWait {
  let place: RemoteWorkrooms.Place
  let setup: any RemoteSetup
  /// The window the first create started in, which shows the sheet.
  weak var window: AppStore?
  var waiting: [CheckedContinuation<Bool, Never>] = []

  init(place: RemoteWorkrooms.Place, setup: any RemoteSetup, window: AppStore) {
    self.place = place
    self.setup = setup
    self.window = window
  }
}

/// Checks a setup's waiting steps 3 s after the user acts, then backing off to every 30 s, until
/// none is waiting: a sheet left open while the user is away mustn't keep asking the provider.
@MainActor
final class SetupPoller {
  private var polling: Task<Void, Never>?
  /// Which poll is current, so one replaced mid-check doesn't clear its successor.
  private var pollID = UUID()
  private let first: Duration
  private let cap: Duration

  init(first: Duration = .seconds(3), cap: Duration = .seconds(30)) {
    self.first = first
    self.cap = cap
  }

  /// Starts again from the first delay, replacing any poll already running.
  func start(
    while isWaiting: @escaping @MainActor () -> Bool,
    check: @escaping @MainActor () async -> Void
  ) {
    polling?.cancel()
    let id = UUID()
    pollID = id
    let (first, cap) = (first, cap)
    polling = Task { [weak self] in
      var delay = first
      while isWaiting(), !Task.isCancelled {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { break }
        await check()
        delay = min(delay * 2, cap)
      }
      if self?.pollID == id { self?.polling = nil }
    }
  }

  var isPolling: Bool { polling != nil }

  func cancel() {
    polling?.cancel()
    polling = nil
  }
}
