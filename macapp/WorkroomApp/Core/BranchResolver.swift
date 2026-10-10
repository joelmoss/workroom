import Foundation
import WorkroomDomain

/// Resolves a project root's current branch for the sidebar root-row label — the current branch, or
/// a short SHA when detached — read structurally through `LocalVCSProviding` (SwiftGitX, or wr-agent
/// on the agent path). GUI-only: the `workroom` CLI never
/// shows it, and resolving per project (not inside `list --json`) keeps the list instant and
/// isolates a slow/wedged repo to its own row. Best-effort — any failure or timeout yields
/// `.unresolved` for that project and never affects others.
struct BranchResolver: Sendable {
  /// Per-call ceiling so one hung repo abandons only its own label. `LocalVCSProviding` has no built-in
  /// timeout, so this wraps the read in `withTimeout`.
  var timeout: TimeInterval
  /// The VCS backend, injected for tests. Defaults to the real repo-kind router.
  let makeProvider: (@Sendable (URL) throws -> LocalVCSProviding)?
  var router: RepositoryRouter = .shared

  init(
    timeout: TimeInterval = 3,
    makeProvider: (@Sendable (URL) throws -> LocalVCSProviding)? = nil
  ) {
    self.timeout = timeout
    self.makeProvider = makeProvider
  }

  func resolve(path: String, vcs: String) async -> RootRef {
    // Only git projects have a resolvable root ref; anything else has no label.
    guard vcs == "git" else { return .unresolved }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    do {
      let ref = try await withTimeout(seconds: timeout) {
        // The provider self-offloads its blocking read to GCD (`runBlocking`), so a plain await here
        // never occupies a cooperative-pool thread — no `Task.detached` wrapper needed.
        if let makeProvider { return try await makeProvider(root).currentRef(root: root) }
        let location = try await RepositoryLocation.local(path)
        return try await router.reader(for: location).currentRef()
      }
      return Self.rootRef(from: ref)
    } catch {
      return .unresolved
    }
  }

  func resolve(location: RepositoryLocation) async throws -> RootRef {
    let ref = try await withTimeout(seconds: timeout) {
      try await router.reader(for: location).currentRef()
    }
    return Self.rootRef(from: ref)
  }

  /// Map the backend's `VCSRef` onto the sidebar's `RootRef`. `.none` (or a kind with no name) ⇒
  /// `.unresolved`, so an unlabelled repo never clobbers a prior label (the caller keeps the old
  /// value on `.unresolved`). `branch` is normalized to nil-never-"" per `RootRef`'s contract.
  static func rootRef(from ref: VCSRef) -> RootRef {
    let name = (ref.name?.isEmpty == false) ? ref.name : nil
    switch ref.kind {
    case .none: return .unresolved
    case .branch: return name.map { RootRef(branch: $0, kind: .branch) } ?? .unresolved
    case .detached: return name.map { RootRef(branch: $0, kind: .detached) } ?? .unresolved
    }
  }
}
