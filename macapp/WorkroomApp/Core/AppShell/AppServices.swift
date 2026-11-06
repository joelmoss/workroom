import Foundation
import WorkroomVCS
import WorkroomWire

/// What the app reaches outside itself, chosen once per process: ADR 0022's services axis as values
/// rather than a flag. `.live` is the real CLI, repositories, Trash, banners and hosts; `.fixture`
/// (`UITestFixture.swift`, Debug only) is the UI-test fixture's fakes, so a Release build compiles
/// none of them. `WorkroomApp.init` installs the process's choice in `current`; each window's
/// `AppStore` holds it, and the views under a store are handed the parts they need. Code asks the
/// service it was given, not which environment it runs in.
///
/// A member is here because the fixture swaps it or a test stands in a fake for it. There is no
/// clock: nothing in the app takes one today.
struct AppServices {
  /// The bundled `workroom` CLI.
  var cli: any WorkroomCLIProtocol
  /// Reads a repository on this Mac directly (history, changesets). Nil reads through
  /// `RepositoryRouter`, as every real repository is.
  var vcsReader: (@Sendable (URL) throws -> LocalVCSProviding)?
  /// Writes to a repository on this Mac directly (commit, fetch, push, pull). Nil writes through
  /// `RepositoryRouter`.
  var vcsWriter: (@Sendable (URL) throws -> LocalVCSWriting)?
  /// Builds a window's VCS toolbar model: its writer and its timing.
  var makeRemoteState: @MainActor () -> RemoteStateModel
  /// Diffs and file contents with no repository behind them. Nil reads the repository.
  var cannedDiffs: CannedDiffs?
  /// Workroom statuses shown instead of probing git and gh, for paths that are not repositories.
  /// Nil probes, and watches the repositories for changes. Read from `current` by the app-wide
  /// `VCSStatusService`, which no single window's store owns.
  var seededStatuses: (@MainActor () -> SeededStatuses)?
  /// What a remote create reaches beyond the app: GitHub and the project's git, the provider's
  /// account, and its hosts.
  var remoteCreate: RemoteCreateServices
  /// The macOS Trash, for a from-disk project delete (issue #108).
  var trasher: Trashing
  /// Native banners.
  var notifier: SystemNotifying
  /// Where a host's layouts are read and written: its daemon, its service connection brought up
  /// first (it can drop while the panes' own links stay up).
  var hostLayoutStore: @Sendable (HostID) async throws -> HostLayoutStore
  /// A host's live sessions, for the host layout's append rule.
  var hostSessions: @Sendable (HostID) async throws -> [SessionDescriptor]

  /// Diffs served without a repository: the diff for a descriptor and its new-side content.
  struct CannedDiffs {
    var diff: (DiffDescriptor) -> DiffResult
    var fileContent: (DiffDescriptor) -> String?
  }

  /// The statuses `seededStatuses` serves: the project root's, its first workroom's, and the
  /// GitHub CLI's (nil leaves the optimistic default).
  struct SeededStatuses {
    var root: WorkroomStatus
    var workroom: WorkroomStatus
    var gitHubCLI: GitHubCLIStatus?
  }

  @MainActor static var live: AppServices {
    AppServices(
      cli: WorkroomCLI.shared,
      vcsReader: nil,
      vcsWriter: nil,
      makeRemoteState: { RemoteStateModel() },
      cannedDiffs: nil,
      seededStatuses: nil,
      remoteCreate: .live,
      trasher: SystemTrasher(),
      notifier: SystemNotifier(),
      hostLayoutStore: { host in
        try await RemoteHosts.shared.reachability.ensureConnected(host)
        return try await HostConnectionManager.shared.layouts(host: host)
      },
      hostSessions: { try await HostConnectionManager.shared.sessions(on: $0) })
  }

  /// This process's services, set once by `WorkroomApp.init`. `.live` before that, which is what a
  /// hosted unit run's own `AppStore()`s get.
  @MainActor static var current = AppServices.live
}
