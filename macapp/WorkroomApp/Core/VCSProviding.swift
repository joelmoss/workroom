import Foundation

/// Which working-copy revision a `workingFileDiff` is against — backend-neutral so `DiffResolver`
/// maps its UI `DiffSource` onto it without knowing the backend:
///   - `.workingCopy` — the uncommitted changes: git = worktree/index vs `HEAD`; jj = `@` (vs `@-`).
///   - `.parent`      — jj only: the working copy's parent (`@-`) own changes (vs `@--`). Git has no
///     equivalent surface (git repos never request it) and reports it unsupported.
enum VCSWorkingDiffBase: Sendable, Equatable {
  case workingCopy
  case parent
}

/// Local engine interface. RepositoryRouter wraps these engines in a context-bound VCSProviding;
/// application callers never supply an engine with a remote path. Synchronous native operations
/// are offloaded by BoundLocalReader and keep their coordination tail until actual completion.
protocol LocalVCSProviding: Sendable {
  /// A bounded, newest-first page of history.
  ///
  /// "Newest-first" is deliberately each backend's OWN CLI order, not a shared one — the page is what
  /// `jj log` / `git log` would print, so History never contradicts the tool the user reaches for:
  /// jj is topological (children before parents, jj-lib's descending commit position), while git is
  /// reverse-chronological (libgit2's default `GIT_SORT_NONE`, matching git's date-ordered default
  /// rather than its opt-in `--topo-order`). So a repo with out-of-order commit timestamps can page
  /// differently on the two backends by design; don't "unify" it without changing both CLIs' truth.
  func log(root: URL, limit: Int) throws -> VCSHistoryPage
  /// A single changeset: metadata + full message + changed-file list.
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset
  /// The per-file diff for one path within a changeset, as git-format unified-diff text (fed to the
  /// existing `UnifiedDiff` parser / `DiffViewer`). Lazy — the detail view fetches it on selection.
  func fileDiff(root: URL, commitID: String, path: String) async throws -> String
  /// The per-file diff for one path in the working copy (or its parent), as git-format unified-diff
  /// text — the working-copy counterpart of `fileDiff`. Lazy, per-file (never a whole-tree diff).
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String
  /// The full content of `path` at revision `rev` (a git commit id, or a jj revset like `@-`), for
  /// syntax-highlighting a diff's new side. `nil` ⇒ absent at that rev / binary / over the highlight
  /// cap → the caller renders plain. Read-only; must not take the jj working-copy lock (jj uses
  /// `--ignore-working-copy`).
  func fileContent(root: URL, rev: String, path: String) async throws -> String?
  /// The pre-image (old side) content of `path` for a commit's file diff — the file at the commit's
  /// first parent — for syntax-highlighting the diff's DELETED lines. The backend resolves its own
  /// parent (git `^` / jj `-`). `nil` ⇒ added at this commit (no parent version) / root commit /
  /// merge / binary / over cap → deletions render plain. Read-only; must not lock the jj working copy.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String?
  /// The pre-image content of `path` for a working-copy file diff's base (git `HEAD`; jj `@-` for
  /// `.workingCopy`, `@--` for `.parent`), for highlighting the diff's deleted lines. `nil` ⇒
  /// absent / unsupported base / binary / over cap → deletions render plain.
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  /// The working copy's status: dirty flag, changed files, ± line counts, and the branch CI should
  /// be looked up for. Synchronous and throwing, with no timeout of its own — callers that need one
  /// wrap it (`WorkroomStatusResolver` bounds it with `withTimeout` and, for jj, serialises it
  /// through `JJSnapshotGate`).
  ///
  /// **The one read that mutates, on jj.** jj's working copy is itself a commit, so on-disk edits do
  /// not exist to jj-lib until snapshotted — this takes the working-copy lock and rewrites `@`.
  /// Working-copy diffs can snapshot too. The bound reader gates both operations by registered
  /// shared repository identity. Immutable revision reads do not acquire the gate.
  ///
  /// Returns a `WorkroomStatus` with `ci`, `failure` and `localReadAt` unset: those are the
  /// resolver's to fill, not a backend's.
  func workingStatus(root: URL) throws -> WorkroomStatus

  /// The repo's current ref for the sidebar root-row label — the `@` bookmark / nearest ancestor
  /// bookmark (jj) or current branch / short SHA (git). Read-only; must not take the jj working-copy
  /// lock (backs `BranchResolver`).
  func currentRef(root: URL) async throws -> VCSRef
}

extension LocalVCSProviding {
  /// Default: **throws**, rather than reporting a clean working copy.
  ///
  /// The two real backends both implement this; the default exists for conformers that are not a
  /// VCS at all — the test stubs that drive History and diff resolution, which never ask for
  /// status. It throws rather than returning an empty `WorkroomStatus` on purpose: a backend that
  /// silently reported every workroom clean would look like a working app with a broken badge,
  /// which is the kind of failure that survives a whole release. A throw surfaces as
  /// `.notRepository` on the row instead.
  func workingStatus(root: URL) throws -> WorkroomStatus {
    throw VCSError.unsupportedRepo("\(Self.self) does not implement workingStatus")
  }

  /// Default: no pre-image source, so deletions render plain. `GitProvider`/`RustJJProvider` override
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

}
