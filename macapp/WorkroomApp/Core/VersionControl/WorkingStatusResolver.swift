import DaemonConnection
import Foundation
import WorkroomSystem
import WorkroomVCS

/// Resolves a workroom's working status (dirty, conflicted, changed files) through the repository
/// router: the fast, local stage of a status sweep, which never waits on the network
/// (`GitHubStatusResolver` is the slow stage). App-side, not in the `workroom --json` contract, for
/// the same reasons as `BranchResolver`: GUI-only, keeps `list` instant, isolates a slow repo to its
/// own row.
struct WorkingStatusResolver: Sendable {
  var timeout: TimeInterval
  /// Where local and remote status reads are routed. `.shared` in the app; tests inject a router
  /// whose `localReader` is a double, so the sweep's real path is the one under test.
  let router: RepositoryRouter

  init(timeout: TimeInterval = 3, router: RepositoryRouter = .shared) {
    self.timeout = timeout
    self.router = router
  }

  func resolveLocal(path: String) async -> WorkroomStatus {
    do {
      return await resolve(location: try await RepositoryLocation.local(path))
    } catch {
      return WorkroomStatus(dirty: nil, failure: .unavailable)
    }
  }

  func resolve(item: VCSStatusService.StatusWorkItem) async -> WorkroomStatus {
    if let location = item.location { return await resolve(location: location) }
    return await resolveLocal(path: item.path)
  }

  func resolve(location: RepositoryLocation) async -> WorkroomStatus {
    let interval = LaunchSignposts.begin("Working status")
    defer { LaunchSignposts.end("Working status", interval) }
    var status: WorkroomStatus
    do {
      if location.host == .local {
        let exists = try await runBlocking { FileManager.default.fileExists(atPath: location.path) }
        guard exists else {
          var missing = WorkroomStatus(dirty: nil, failure: .missingPath)
          missing.localReadAt = Date()
          return missing
        }
      }
      let reader = try await router.reader(for: location)
      status = try await withTimeout(seconds: timeout) {
        try await reader.workingStatus()
      }
    } catch RepositoryRoutingError.registrationRequired {
      status = WorkroomStatus(dirty: nil, failure: .registrationRequired)
    } catch RepositoryRoutingError.asleep {
      status = WorkroomStatus(dirty: nil, failure: .asleep)
    } catch RepositoryRoutingError.olderLayout {
      status = WorkroomStatus(dirty: nil, failure: .olderLayout)
    } catch RepositoryRoutingError.signedOut {
      status = WorkroomStatus(dirty: nil, failure: .signedOut)
    } catch RepositoryRoutingError.gone {
      status = WorkroomStatus(dirty: nil, failure: .gone)
    } catch is RepositoryRoutingError, is HostConnectionError {
      status = WorkroomStatus(dirty: nil, failure: .unavailable)
    } catch is VCSTimeoutError, is VCSCancellationError {
      status = WorkroomStatus(dirty: nil, failure: .timeout)
    } catch let error as VCSError {
      status = WorkroomStatus(dirty: nil, failure: Self.failure(for: error))
    } catch { status = WorkroomStatus(dirty: nil, failure: .notRepository) }
    // Stamp when this read FINISHED, so `mergeLocalStatus` can order results that its five unordered
    // lanes produce. It has to be stamped here rather than by the caller: a read can queue behind
    // others for a while before it observes anything, so the caller's invocation time can say a
    // probe is older when it actually saw a LATER tree. Completion is the closest observable
    // bound on when the tree was seen. (Two overlapping reads can still finish in the opposite order
    // to their observations; closing that needs a filesystem generation number, not a clock.)
    status.localReadAt = Date()
    return status
  }

  /// Which "unknown" badge a typed backend error earns. Pure, so the mapping is unit-tested without
  /// a repo.
  ///
  /// Only the two states a *retry* can clear get their own badge: a repository that refused the
  /// read as busy (`.busy`) and a working tree that moved under the read (`.staleWorkingCopy`) — both
  /// self-describing in the sidebar tooltip and the Changes panel.
  /// Everything else stays `.notRepository`, which is also the honest answer for the common git case:
  /// `GitProvider` can't bind SwiftGitX's typed error (a Swift 6 SIL crash — see its doc), so a
  /// missing/broken repo arrives as `.io` and must keep reading as "not a repository".
  static func failure(for error: VCSError) -> VCSStatusFailure {
    switch error {
    case .lockContention: return .busy
    case .staleSnapshot: return .staleWorkingCopy
    case .unsupportedRepo, .notFound, .partialData, .backendVersion, .io: return .notRepository
    }
  }
}
