import Foundation

/// Which working-copy revision a `workingFileDiff` is against:
///   - `.workingCopy` — the uncommitted changes: worktree/index vs `HEAD`.
/// Sent to wr-agent as `base: "working_copy"`, which the agent's wire protocol still requires.
enum VCSWorkingDiffBase: Sendable, Equatable {
  case workingCopy
}

/// Local engine interface. RepositoryRouter wraps these engines in a context-bound VCSProviding;
/// application callers never supply an engine with a remote path. Synchronous native operations
/// are offloaded by BoundLocalReader and keep their coordination tail until actual completion.
protocol LocalVCSProviding: Sendable {
  /// A bounded, newest-first page of history.
  ///
  /// "Newest-first" is deliberately git's OWN CLI order — the page is what `git log` would print, so
  /// History never contradicts the tool the user reaches for: reverse-chronological (libgit2's
  /// default `GIT_SORT_NONE`, matching git's date-ordered default rather than its opt-in
  /// `--topo-order`).
  func log(root: URL, limit: Int) throws -> VCSHistoryPage
  /// A single changeset: metadata + full message + changed-file list.
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset
  /// The per-file diff for one path within a changeset, as git-format unified-diff text (fed to the
  /// existing `UnifiedDiff` parser / `DiffViewer`). Lazy — the detail view fetches it on selection.
  func fileDiff(root: URL, commitID: String, path: String) async throws -> String
  /// The per-file diff for one path in the working copy, as git-format unified-diff
  /// text — the working-copy counterpart of `fileDiff`. Lazy, per-file (never a whole-tree diff).
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String
  /// The full content of `path` at revision `rev` (a git commit id), for syntax-highlighting a diff's
  /// new side. `nil` ⇒ absent at that rev / binary / over the highlight cap → the caller renders
  /// plain. Read-only.
  func fileContent(root: URL, rev: String, path: String) async throws -> String?
  /// The pre-image (old side) content of `path` for a commit's file diff — the file at the commit's
  /// first parent — for syntax-highlighting the diff's DELETED lines. The backend resolves its own
  /// parent (git `^`). `nil` ⇒ added at this commit (no parent version) / root commit /
  /// merge / binary / over cap → deletions render plain. Read-only.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String?
  /// The pre-image content of `path` for a working-copy file diff's base (git `HEAD`), for
  /// highlighting the diff's deleted lines. `nil` ⇒ absent / binary / over cap → deletions render
  /// plain.
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  /// The working copy's status: dirty flag, changed files, ± line counts, and the branch CI should
  /// be looked up for. Synchronous and throwing, with no timeout of its own — callers that need one
  /// wrap it (`WorkroomStatusResolver` bounds it with `withTimeout`).
  ///
  /// Returns a `WorkroomStatus` with `ci`, `failure` and `localReadAt` unset: those are the
  /// resolver's to fill, not a backend's.
  func workingStatus(root: URL) throws -> WorkroomStatus

  /// The repo's current ref for the sidebar root-row label — the current branch, or a short SHA
  /// when detached. Read-only (backs `BranchResolver`).
  func currentRef(root: URL) async throws -> VCSRef
}

extension LocalVCSProviding {
  /// Default: **throws**, rather than reporting a clean working copy.
  ///
  /// `GitProvider` implements this; the default exists for conformers that are not a
  /// VCS at all — the test stubs that drive History and diff resolution, which never ask for
  /// status. It throws rather than returning an empty `WorkroomStatus` on purpose: a backend that
  /// silently reported every workroom clean would look like a working app with a broken badge,
  /// which is the kind of failure that survives a whole release. A throw surfaces as
  /// `.notRepository` on the row instead.
  func workingStatus(root: URL) throws -> WorkroomStatus {
    throw VCSError.unsupportedRepo("\(Self.self) does not implement workingStatus")
  }

  /// Default: no pre-image source, so deletions render plain. `GitProvider` overrides
  /// these; other conformers (tests, fixtures) inherit the no-op.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String? {
    nil
  }
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  { nil }
}

/// Backend selection + routing.
enum VCS {
  /// Classify a repo by pure filesystem inspection (no VCS call). `.git` is a dir for a normal
  /// repo, a file for a worktree/submodule — either counts.
  static func repoKind(at root: URL) -> VCSRepoKind {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
      ? .plainGit : .unsupported("no .git at \(root.path)")
  }

}
