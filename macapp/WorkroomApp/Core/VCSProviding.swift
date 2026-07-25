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

/// The single seam the app reads VCS data through. Two implementations — `RustJJProvider` (jj, over
/// the Rust/UniFFI core) and `GitProvider` (git, over SwiftGitX) — both return the app-native models
/// in `VCSModels.swift`. Views/models depend on this protocol, not on either backend.
protocol VCSProviding: Sendable {
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
  /// The repo's current ref for the sidebar root-row label — the `@` bookmark / nearest ancestor
  /// bookmark (jj) or current branch / short SHA (git). Read-only; must not take the jj working-copy
  /// lock (backs `BranchResolver`).
  func currentRef(root: URL) async throws -> VCSRef
}

extension VCSProviding {
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

  /// The provider for a repo, or a typed error for an unsupported path.
  static func provider(for root: URL) throws -> VCSProviding {
    switch repoKind(at: root) {
    case .jjColocated, .jjNonColocated: return RustJJProvider()
    case .plainGit: return GitProvider()
    case .unsupported(let reason): throw VCSError.unsupportedRepo(reason)
    }
  }
}
