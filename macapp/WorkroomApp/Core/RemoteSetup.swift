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

/// A create held until the user's account at `place` is ready. `id` keys the sheet on the project,
/// so a second create for it while one is up doesn't stack a second sheet.
struct PendingRemoteSetup: Identifiable {
  let project: Project
  let splitAnchor: SidebarID?
  let place: RemoteWorkrooms.Place
  let setup: any RemoteSetup
  var id: String { project.path }
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
