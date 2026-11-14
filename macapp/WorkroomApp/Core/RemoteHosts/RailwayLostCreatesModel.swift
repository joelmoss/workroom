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

  /// Seams, the app's own by default: the lost creates (this Mac's Railway folder and sign-in),
  /// and the sandboxes config's records name (`HostDriverRegistry.railwayRecordedSandboxes`).
  init(
    lost: @escaping @Sendable () -> RailwayLostCreates = RailwayLostCreatesModel.appLostCreates,
    recorded: @escaping @Sendable () -> Set<String>? = {
      RemoteHosts.shared.registry.railwayRecordedSandboxes
    }
  ) {
    self.lost = lost
    self.recorded = recorded
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

  /// Reads the ledger again (no call to Railway).
  func refresh() async {
    let lost = self.lost
    creates = (try? await Task.detached { try await lost().creates() }.value) ?? []
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
