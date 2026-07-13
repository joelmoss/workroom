import Foundation

/// Resolves a project root's current branch/bookmark for the sidebar root-row label — the `@`
/// bookmark / nearest ancestor bookmark (jj) or current branch / short SHA (git) — read structurally
/// through `VCSProviding` (jj via jj-lib, git via SwiftGitX). GUI-only: the `workroom` CLI never
/// shows it, and resolving per project (not inside `list --json`) keeps the list instant and
/// isolates a slow/wedged repo to its own row. Best-effort — any failure or timeout yields
/// `.unresolved` for that project and never affects others.
///
/// (Previously shelled `git symbolic-ref` / `jj log -T bookmarks` and parsed the output; the jj
/// bookmark cleaning + nearest-ancestor walk now live in the Rust core's `current_ref`, and jj-lib's
/// `local_bookmarks()` yields clean names — no `*`/`?`/`@` decoration to strip. The read stays
/// lock-safe: `current_ref` never snapshots the working copy, so it can't self-trigger the
/// `.jj` file watcher.)
struct BranchResolver: Sendable {
  /// Per-call ceiling so one hung repo abandons only its own label. `VCSProviding` has no built-in
  /// timeout, so this wraps the read in `withTimeout`.
  var timeout: TimeInterval
  /// The VCS backend, injected for tests. Defaults to the real repo-kind router.
  let makeProvider: @Sendable (URL) throws -> VCSProviding

  init(
    timeout: TimeInterval = 3,
    makeProvider: @escaping @Sendable (URL) throws -> VCSProviding = { try VCS.provider(for: $0) }
  ) {
    self.timeout = timeout
    self.makeProvider = makeProvider
  }

  func resolve(path: String, vcs: String) async -> RootRef {
    // Only git/jj projects have a resolvable root ref; anything else has no label. (The provider
    // itself routes jj vs git by repo kind — this guard just skips the unsupported case.)
    guard vcs == "git" || vcs == "jj" else { return .unresolved }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    do {
      let ref = try await withTimeout(seconds: timeout) {
        // Off the main actor: the providers do blocking work (libgit2 / jj-lib over UniFFI).
        try await Task.detached(priority: .userInitiated) {
          try await makeProvider(root).currentRef(root: root)
        }.value
      }
      return Self.rootRef(from: ref)
    } catch {
      return .unresolved
    }
  }

  /// Map the backend's `VCSRef` onto the sidebar's `RootRef`. `.none` (or a kind with no name) ⇒
  /// `.unresolved`, so an unlabelled repo never clobbers a prior label (the caller keeps the old
  /// value on `.unresolved`). `branch` is normalized to nil-never-"" per `RootRef`'s contract.
  static func rootRef(from ref: VCSRef) -> RootRef {
    let name = (ref.name?.isEmpty == false) ? ref.name : nil
    switch ref.kind {
    case .none: return .unresolved
    case .branch: return name.map { RootRef(branch: $0, kind: .branch) } ?? .unresolved
    case .ancestor: return name.map { RootRef(branch: $0, kind: .ancestor) } ?? .unresolved
    case .detached: return name.map { RootRef(branch: $0, kind: .detached) } ?? .unresolved
    }
  }
}
