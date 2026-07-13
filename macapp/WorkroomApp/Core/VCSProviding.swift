import Foundation

/// The single seam the app reads VCS data through. Two implementations — `RustJJProvider` (jj, over
/// the Rust/UniFFI core) and `GitProvider` (git, over SwiftGitX) — both return the app-native models
/// in `VCSModels.swift`. Views/models depend on this protocol, not on either backend.
protocol VCSProviding: Sendable {
  /// A bounded, newest-first page of history.
  func log(root: URL, limit: Int) async throws -> VCSHistoryPage
  /// A single changeset: metadata + full message + changed-file list.
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset
  /// The per-file diff for one path within a changeset, as git-format unified-diff text (fed to the
  /// existing `UnifiedDiff` parser / `DiffViewer`). Lazy — the detail view fetches it on selection.
  func fileDiff(root: URL, commitID: String, path: String) async throws -> String
}

/// Backend selection + routing.
enum VCS {
  /// Classify a repo by pure filesystem inspection (no VCS call, so it can't take the jj
  /// working-copy lock). Colocated jj+git prefers jj (matches how Workroom's own repos are set up).
  static func repoKind(at root: URL) -> VCSRepoKind {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let hasJJ =
      fm.fileExists(atPath: root.appendingPathComponent(".jj").path, isDirectory: &isDir)
      && isDir.boolValue
    // `.git` is a dir for a normal repo, a file for a worktree/submodule — either counts.
    let hasGit = fm.fileExists(atPath: root.appendingPathComponent(".git").path)
    switch (hasJJ, hasGit) {
    case (true, true): return .jjColocated
    case (true, false): return .jjNonColocated
    case (false, true): return .plainGit
    case (false, false): return .unsupported("no .jj or .git at \(root.path)")
    }
  }

  /// The provider for a repo, or a typed error for an unsupported path.
  static func provider(for root: URL) throws -> VCSProviding {
    switch repoKind(at: root) {
    case .jjColocated, .jjNonColocated: return RustJJProvider()
    case .plainGit: return GitProvider()
    case .unsupported(let reason): throw VCSError.unsupportedRepo(reason)
    }
  }
}
