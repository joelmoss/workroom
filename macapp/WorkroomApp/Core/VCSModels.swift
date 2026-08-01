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

/// Whether a commit has reached the project's remote. `.unknown` is NOT "no": it means there was
/// nothing to compare against (no `origin`) or the reachability read failed, so the UI renders NOTHING
/// for it — a missing badge beats a wrong one.
///
/// "Pushed" = reachable from a tip of `origin` (git `refs/remotes/origin/*`, jj tracked `@origin`
/// bookmarks). Deliberately origin-scoped, not any-remote: a commit sitting on a backup remote or a
/// fork isn't on the shared repo, which is what the badge claims. Deliberately not `@{u}` either —
/// workrooms are `git worktree add -b` branches with no upstream, so the badge would never appear
/// where it matters most.
///
/// Computed from LOCAL remote-tracking state, so it reflects whatever the last fetch or push wrote —
/// never the server's live state.
enum VCSPushState: Equatable, Sendable {
  case pushed, unpushed, unknown
}

/// What a page's/changeset's push state was measured against, for tooltip copy. `refName` is set only
/// when `origin` has exactly one branch (so the tooltip can say "not on origin/main"); otherwise
/// `count` drives "not on any of origin's N branches".
struct VCSPushScope: Equatable, Sendable {
  let refName: String?
  let count: Int

  /// The tooltip for an unpushed badge, shared by every surface that shows one (history row, hover
  /// card, changeset header) so the claim is worded identically in all three.
  ///
  /// It says "local remote-tracking refs", NOT "your last fetch": a local `git push` updates those refs
  /// too, so naming only fetch would be wrong half the time. Either way the badge is a statement about
  /// what this machine knows, never about the server's current state.
  static func unpushedHelp(_ scope: VCSPushScope?) -> String {
    let target: String
    switch scope {
    case let scope? where scope.refName != nil:
      target = scope.refName!
    case let scope? where scope.count > 1:
      target = "any of origin's \(scope.count) branches"
    default:
      target = "origin"
    }
    return "Not pushed — this commit isn't on \(target), based on your local remote-tracking refs."
  }
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
  /// jj-only: this commit's offset within its divergent set (the `/N` in `xl/0`). `nil` unless the
  /// change ID is divergent. Set on both a divergent commit and each of its `divergentSiblings`.
  var changeOffset: Int? = nil
  /// jj-only: the OTHER visible commits sharing this commit's change ID — the divergent copies that
  /// live off the `::@` history line. Empty unless divergent; never nested. Defaulted so non-jj /
  /// test call sites needn't pass it.
  var divergentSiblings: [VCSCommit] = []
  /// Whether this commit is on `origin` — see `VCSPushState`. Defaulted so the many existing call
  /// sites (fixtures, tests, the changeset paths) needn't pass it and read as `.unknown`.
  var pushState: VCSPushState = .unknown
  /// jj-only: the repo's virtual **root commit** (`◆ root() 00000000` in `jj log`) — the all-zero-id
  /// commit every jj history terminates in. It's a real row on the log page (`::@` includes it, so
  /// `jj log` prints it), but it carries no author, description or changes, and is stamped at the
  /// epoch — so `HistoryRootRow` renders it as `root()` rather than letting it read as a
  /// description-less commit from 1970. Defaulted false: git has no such pseudo-commit.
  var isRoot: Bool = false
  var id: String { commitID }
  /// jj-only: true when this commit's change ID diverges — it resolves to more than one visible
  /// commit, so `divergentSiblings` carries the other copies. Always false for git (no change ID).
  var isDivergent: Bool { !divergentSiblings.isEmpty }
  /// The `id/N` label jj shows for a divergent copy (e.g. `xl/2`) — change ID plus its `/N` offset.
  /// `nil` without both. Used to label the sibling copies in the History pane's divergence expander.
  var divergentLabel: String? {
    guard let changeID, let changeOffset else { return nil }
    return "\(changeID)/\(changeOffset)"
  }
  /// The single place both badge-suppression rules live: render only for a DEFINITE `.unpushed`, and
  /// never for jj's working-copy `@` (a pending change, not a commit you'd push).
  var showsUnpushedBadge: Bool { pushState == .unpushed && !isWorkingCopy }
}

struct VCSHistoryPage: Equatable, Sendable {
  let commits: [VCSCommit]
  /// True when the backend yielded fewer than the requested count (no older commits).
  let reachedEnd: Bool
  /// What the page's `pushState`s were measured against (tooltip copy). `nil` ⇒ nothing to compare, so
  /// every commit is `.unknown` and no badge renders.
  var pushScope: VCSPushScope? = nil
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
  /// What `commit.pushState` was measured against (tooltip copy). `nil` ⇒ nothing to compare.
  var pushScope: VCSPushScope? = nil
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

// MARK: - Remote state (the VCS inspector's toolbar)

/// How far a local ref has diverged from the remote ref its push/pull actually acts on.
///
/// `comparedTo` is the short form the backend itself prints — git `origin/main`, jj `main@origin` —
/// because the toolbar's tooltip quotes it verbatim (the `VCSPushScope.unpushedHelp` rule: name the
/// ref, don't make the user guess what "behind" is behind).
///
/// Counts are always from the LOCAL ref's point of view: `ahead` = local commits the remote doesn't
/// have (what Push sends), `behind` = remote commits we don't have (what Pull brings). **jj states its
/// own counts from the REMOTE ref's perspective and they are swapped on ingest** — see
/// `CLIVCSWriter.parseJJBookmarks`.
///
/// `nil` counts mean "unanswerable", never zero: an untracked jj remote bookmark, or a git branch with
/// no counterpart under `refs/remotes/`. A missing badge beats a wrong one (same rule as
/// `VCSPushState.unknown`).
///
/// Counts come from an explicit `git rev-list --left-right --count`, **not** from git's
/// `%(push:track)` / `%(upstream:track)` for-each-ref fields. Those resolve to nothing for a branch
/// with no upstream under `push.default=simple` (git's built-in default) — which is *every* workroom,
/// since a workroom is `git worktree add -b`. Deriving counts from them leaves the badge permanently
/// blank on any machine not set to `push.default=current`.
///
/// Like every push-state answer in this app, this is computed from LOCAL remote-tracking refs, so it
/// reflects the last fetch — never the server's live state. That's why the toolbar shows "last fetched
/// N ago" beside it.
struct VCSTracking: Equatable, Sendable {
  let comparedTo: String
  let ahead: Int?
  let behind: Int?
  /// The counterpart ref is gone from the remote (or was never pushed). Counts are meaningless; the
  /// toolbar offers Publish rather than Push.
  let gone: Bool
}

/// When the repo last fetched. Three-way rather than `Date?` because the copy differs per case and
/// "can't tell" must never render as "no" (the `VCSPushState.unknown` rule).
enum VCSLastFetch: Equatable, Sendable {
  case at(Date)
  /// No fetch has ever been recorded: git has no `FETCH_HEAD` (`clone`/`init` never write one), or
  /// jj's op log holds no fetch op within the scanned window.
  case never
  /// Unanswerable — the git dir couldn't be located, `FETCH_HEAD`'s attributes were unreadable, the
  /// user has `fetch.writeFetchHEAD=false`, or the jj op-log read failed. Renders NO timestamp, and
  /// specifically never the word "never".
  case unknown
}

/// Everything the VCS inspector's toolbar renders, read as ONE coherent snapshot so the branch name
/// and the counts beside it can't come from two different reads of a moving repo.
struct VCSRemoteState: Equatable, Sendable {
  /// The current branch/bookmark, straight from `VCSProviding.currentRef` — the app's existing
  /// canonical answer, including jj `.ancestor` (an unbookmarked `@`) and git `.detached`.
  let current: VCSRef
  /// Divergence for `current`. `nil` ⇒ nothing to compare against (no counterpart on the remote,
  /// detached HEAD, untracked bookmark) ⇒ no counts render.
  let tracking: VCSTracking?
  /// Configured remote names, first-listed first. Empty ⇒ no remote ⇒ every action is disabled.
  /// Derived from the ref list (git `refs/remotes/<remote>/*`, jj `<name>@<remote>`), so it costs no
  /// extra process — and deliberately NOT from `jj git remote list`, which takes the repo's
  /// git import/export lock even to read.
  let remotes: [String]
  /// The remote fetch/push/pull act on: `origin` when present, else the first remote, else `nil`.
  /// Interpolated into every UI string — the copy must never hardcode "origin", because
  /// `remote.pushDefault` can legitimately make that the wrong name.
  let primaryRemote: String?
  /// Per-PROJECT, not per-workroom: fetch always runs at the project root, so every workroom of a
  /// project shares one answer. (git's `FETCH_HEAD` is per-worktree, so this is read from the COMMON
  /// git dir — see `CLIVCSWriter.commonGitDir`.)
  let lastFetch: VCSLastFetch
  /// When this snapshot was read — the TTL key, and the `now` reference for the relative label.
  let resolvedAt: Date
}
