import Foundation
import HostDrivers

/// The app's view of this Mac's Railway creates whose reply was lost (`RailwayLostCreates`, ADR
/// 0071's amendment): each may have left a sandbox billing that nothing names, and Workroom never
/// guesses which. The Details pane of a Railway workroom and Settings ▸ Remote Hosts ▸ Railway
/// show each one, with the sandboxes it may have made, read fresh each time, for the user to
/// destroy one of or to dismiss.
@MainActor
final class RailwayLostCreatesModel: ObservableObject {
  static let shared = RailwayLostCreatesModel()

  @Published private(set) var creates: [RailwayLostCreates.Create] = []

  enum Failure: Error, LocalizedError {
    /// Config hasn't been read yet this launch, so a sandbox only a record names would read as a
    /// candidate.
    case recordsUnread

    var errorDescription: String? {
      "Workroom hasn't read its workrooms yet. Try again in a moment."
    }
  }

  private let lost: @Sendable () -> RailwayLostCreates
  private let recorded: @Sendable () -> Set<String>?
  /// How old an entry must be to show (`RailwayLostCreates.creates`).
  private let grace: TimeInterval
  /// The read due when the next young entry leaves its grace, so a view already open shows it.
  private var wake: Task<Void, Never>?

  /// Seams, the app's own by default: the lost creates (this Mac's Railway folder and sign-in),
  /// the sandboxes config's records name (`HostDriverRegistry.railwayRecordedSandboxes`), and the
  /// grace an entry waits out before it shows.
  init(
    lost: @escaping @Sendable () -> RailwayLostCreates = RailwayLostCreatesModel.appLostCreates,
    recorded: @escaping @Sendable () -> Set<String>? = {
      RemoteHosts.shared.registry.railwayRecordedSandboxes
    },
    grace: TimeInterval = RailwayHostDriver.sweepGrace
  ) {
    self.lost = lost
    self.recorded = recorded
    self.grace = grace
  }

  /// This Mac's: its Railway folder's ledger, its sign-in, and its placement for an entry from
  /// before entries named their environment.
  nonisolated static func appLostCreates() -> RailwayLostCreates {
    let placement = RailwayAccount.placement.read()
    return RailwayLostCreates(
      api: RailwayAccount.shared.api, directory: RailwayAccount.directory,
      placement: placement.environmentID.map {
        .init(
          environmentID: $0, workspaceID: placement.workspaceID, projectID: placement.projectID)
      })
  }

  /// Reads the ledger again (no call to Railway), and reads it again when the next entry still
  /// within its grace leaves it: a create that lost its reply only shows once its grace is over,
  /// and a view already open would otherwise never read it.
  func refresh() async {
    let lost = self.lost
    let grace = self.grace
    let read = try? await Task.detached {
      let ledger = lost()
      let now = Date()
      return (
        try await ledger.creates(now: now, grace: grace),
        try await ledger.nextDue(now: now, grace: grace)
      )
    }.value
    creates = read?.0 ?? []
    wake?.cancel()
    wake = nil
    guard let due = read?.1 else { return }
    // A little after, so the entry is past its grace when read.
    let delay = max(0, due.timeIntervalSinceNow) + 0.1
    wake = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.wake = nil
      await self.refresh()
    }
  }

  /// A Railway create failed, which may have left an entry with no sandbox on the ledger: read it
  /// again, which also schedules the read for when that entry leaves its grace.
  nonisolated static func createFailed() {
    Task { @MainActor in await shared.refresh() }
  }

  /// The sandboxes `create` may have made, read from Railway now.
  func candidates(of create: RailwayLostCreates.Create) async throws -> [RailwaySandbox] {
    guard let recorded = recorded() else { throw Failure.recordsUnread }
    let lost = self.lost
    return try await Task.detached {
      try await lost().candidates(of: create, recorded: recorded)
    }.value
  }

  /// Destroys `sandbox` as `create`'s, which resolves it once Railway confirms.
  func destroy(_ sandbox: String, of create: RailwayLostCreates.Create) async throws {
    guard let recorded = recorded() else { throw Failure.recordsUnread }
    let lost = self.lost
    try await refreshing {
      try await Task.detached {
        try await lost().destroy(sandbox, of: create, recorded: recorded)
      }.value
    }
  }

  /// Resolves `create` without destroying anything.
  func dismiss(_ create: RailwayLostCreates.Create) async throws {
    let lost = self.lost
    try await refreshing { try await Task.detached { try await lost().dismiss(create) }.value }
  }

  /// Runs `change`, then reads the ledger again, whether or not it threw: the other build may have
  /// resolved the create meanwhile.
  private func refreshing(_ change: () async throws -> Void) async throws {
    do {
      try await change()
    } catch {
      await refresh()
      throw error
    }
    await refresh()
  }
}
