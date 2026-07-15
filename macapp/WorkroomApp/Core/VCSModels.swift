import Foundation

/// App-native VCS domain models. Both backends (jj via the Rust core, git via SwiftGitX) map their
/// own types into THESE — the UI depends only on these, never on `WrVcs.*` or `SwiftGitX.*`. That
/// keeps the UI decoupled from the FFI/library shapes and lets a backend change without touching
/// views (the hybrid-foundation plan's "unify at the Swift model layer").

enum VCSChangeKind: Equatable, Sendable {
  case added, modified, deleted, renamed, copied, conflicted, other
}

struct VCSAuthor: Equatable, Hashable, Sendable {
  let name: String
  let email: String
}

/// One row of history. `commitID` is the stable identity (git SHA / jj commit-id) used for dedupe
/// and diffing; `changeID` is jj-only (display). `refs` are jj bookmarks / git branch+tag names.
struct VCSCommit: Equatable, Identifiable, Sendable {
  let commitID: String
  let shortID: String
  let changeID: String?
  let summary: String
  /// The commit message below the summary line, trimmed. Empty when the message is a single line.
  let body: String
  let authors: [VCSAuthor]
  let timestamp: Date
  let refs: [String]
  let parentIDs: [String]
  let isWorkingCopy: Bool
  var id: String { commitID }
}

struct VCSHistoryPage: Equatable, Sendable {
  let commits: [VCSCommit]
  /// True when the backend yielded fewer than the requested count (no older commits).
  let reachedEnd: Bool
}

/// The kind of a repo's current ref (the sidebar root-row label). `ancestor` is jj-only (the nearest
/// bookmark above a bookmark-less `@`); `detached` is git-only (HEAD on a raw commit, no branch).
enum VCSRefKind: Equatable, Sendable {
  case branch, ancestor, detached, none
}

/// A repo's current ref: jj's `@` bookmark (or nearest ancestor bookmark), or git's current branch
/// (or a short SHA when detached). `name` is nil only for `.none`.
struct VCSRef: Equatable, Sendable {
  let name: String?
  let kind: VCSRefKind

  static let none = VCSRef(name: nil, kind: .none)
}

struct VCSChangedFile: Equatable, Identifiable, Sendable {
  let path: String
  /// Set for renames/copies.
  let oldPath: String?
  let kind: VCSChangeKind
  var id: String { path }
}

struct VCSChangeset: Equatable, Sendable {
  let commit: VCSCommit
  let fullMessage: String
  let files: [VCSChangedFile]
  /// >1 parent ⇒ a merge; the git diff basis is the first parent.
  let isMerge: Bool
  /// Total lines added / removed across the changeset (vs its first parent), for the detail header's
  /// `+N −M` summary. `nil` ⇒ not resolved (older data / a backend that couldn't produce it) → the
  /// header omits the summary rather than showing a misleading zero.
  var insertions: Int? = nil
  var deletions: Int? = nil
}

/// Typed VCS failures. Each maps to a distinct, recoverable UI state (inline message + retry),
/// never a silent empty result.
enum VCSError: Error, Equatable, Sendable {
  case unsupportedRepo(String)
  case notFound(String)
  case lockContention
  case staleSnapshot
  case partialData(String)
  case backendVersion(String)
  case io(String)
}

/// What kind of repo a path is — the backend-selection discriminant. Colocated jj+git prefers jj.
enum VCSRepoKind: Equatable, Sendable {
  case plainGit, jjColocated, jjNonColocated
  case unsupported(String)
}
