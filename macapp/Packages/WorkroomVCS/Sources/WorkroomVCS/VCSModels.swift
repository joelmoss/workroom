import Foundation

/// App-native VCS domain models. Both readers (local git via SwiftGitX, remote git via wr-agent) map
/// their own types into THESE — the UI depends only on these, never on `SwiftGitX.*` or the agent's
/// wire DTOs. That keeps the UI decoupled from the library/wire shapes and lets a reader change
/// without touching views.

public enum VCSChangeKind: Equatable, Sendable {
  case added, modified, deleted, renamed, copied, conflicted, other
}

public struct VCSAuthor: Equatable, Hashable, Sendable {
  public let name: String
  public let email: String

  public init(name: String, email: String) {
    self.name = name
    self.email = email
  }
}

/// Whether a commit has reached the project's remote. `.unknown` is NOT "no": it means there was
/// nothing to compare against (no `origin`) or the reachability read failed, so the UI renders NOTHING
/// for it — a missing badge beats a wrong one.
///
/// "Pushed" = reachable from a tip of `origin` (`refs/remotes/origin/*`). Deliberately origin-scoped, not any-remote: a commit sitting on a backup remote or a
/// fork isn't on the shared repo, which is what the badge claims. Deliberately not `@{u}` either —
/// workrooms are `git worktree add -b` branches with no upstream, so the badge would never appear
/// where it matters most.
///
/// Computed from LOCAL remote-tracking state, so it reflects whatever the last fetch or push wrote —
/// never the server's live state.
public enum VCSPushState: Equatable, Sendable {
  case pushed, unpushed, unknown
}

/// What a page's/changeset's push state was measured against, for tooltip copy. `refName` is set only
/// when `origin` has exactly one branch (so the tooltip can say "not on origin/main"); otherwise
/// `count` drives "not on any of origin's N branches".
public struct VCSPushScope: Equatable, Sendable {
  public let refName: String?
  public let count: Int

  /// The tooltip for an unpushed badge, shared by every surface that shows one (history row and
  /// changeset header) so the claim is worded identically in both.
  ///
  /// It says "local remote-tracking refs", NOT "your last fetch": a local `git push` updates those refs
  /// too, so naming only fetch would be wrong half the time. Either way the badge is a statement about
  /// what this machine knows, never about the server's current state.
  public static func unpushedHelp(_ scope: VCSPushScope?) -> String {
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

  public init(refName: String?, count: Int) {
    self.refName = refName
    self.count = count
  }
}

/// One row of history. `commitID` is the stable identity (git SHA) used for dedupe and diffing.
/// `refs` are git branch+tag names.
public struct VCSCommit: Equatable, Identifiable, Sendable {
  public let commitID: String
  public let shortID: String
  public let summary: String
  /// The commit message below the summary line, trimmed. Empty when the message is a single line.
  public let body: String
  public let authors: [VCSAuthor]
  public let timestamp: Date
  public let refs: [String]
  public let parentIDs: [String]
  /// Whether this commit is on `origin` — see `VCSPushState`. Defaulted so the many existing call
  /// sites (fixtures, tests, the changeset paths) needn't pass it and read as `.unknown`.
  public var pushState: VCSPushState = .unknown
  public var id: String { commitID }
  /// The single place the badge rule lives: render only for a DEFINITE `.unpushed`.
  public var showsUnpushedBadge: Bool { pushState == .unpushed }

  public init(
    commitID: String, shortID: String, summary: String, body: String, authors: [VCSAuthor],
    timestamp: Date, refs: [String], parentIDs: [String], pushState: VCSPushState = .unknown
  ) {
    self.commitID = commitID
    self.shortID = shortID
    self.summary = summary
    self.body = body
    self.authors = authors
    self.timestamp = timestamp
    self.refs = refs
    self.parentIDs = parentIDs
    self.pushState = pushState
  }
}

public struct VCSHistoryPage: Equatable, Sendable {
  public let commits: [VCSCommit]
  /// True when the backend yielded fewer than the requested count (no older commits).
  public let reachedEnd: Bool
  /// What the page's `pushState`s were measured against (tooltip copy). `nil` ⇒ nothing to compare, so
  /// every commit is `.unknown` and no badge renders.
  public var pushScope: VCSPushScope? = nil

  public init(commits: [VCSCommit], reachedEnd: Bool, pushScope: VCSPushScope? = nil) {
    self.commits = commits
    self.reachedEnd = reachedEnd
    self.pushScope = pushScope
  }
}

/// The kind of a repo's current ref (the sidebar root-row label). `detached` is HEAD on a raw
/// commit, no branch.
public enum VCSRefKind: Equatable, Sendable {
  case branch, detached, none
}

/// A repo's current ref: git's current branch (or a short SHA when detached). `name` is nil only for `.none`.
public struct VCSRef: Equatable, Sendable {
  public let name: String?
  public let kind: VCSRefKind

  public static let none = VCSRef(name: nil, kind: .none)

  public init(name: String?, kind: VCSRefKind) {
    self.name = name
    self.kind = kind
  }
}

public struct VCSChangedFile: Equatable, Identifiable, Sendable {
  public let path: String
  /// Set for renames/copies.
  public let oldPath: String?
  public let kind: VCSChangeKind
  public var id: String { path }

  public init(path: String, oldPath: String?, kind: VCSChangeKind) {
    self.path = path
    self.oldPath = oldPath
    self.kind = kind
  }
}

public struct VCSChangeset: Equatable, Sendable {
  public let commit: VCSCommit
  public let fullMessage: String
  public let files: [VCSChangedFile]
  /// >1 parent ⇒ a merge; the git diff basis is the first parent.
  public let isMerge: Bool
  /// Total lines added / removed across the changeset (vs its first parent), for the detail header's
  /// `+N −M` summary. `nil` ⇒ not resolved (older data / a backend that couldn't produce it) → the
  /// header omits the summary rather than showing a misleading zero.
  public var insertions: Int? = nil
  public var deletions: Int? = nil
  /// What `commit.pushState` was measured against (tooltip copy). `nil` ⇒ nothing to compare.
  public var pushScope: VCSPushScope? = nil

  public init(
    commit: VCSCommit, fullMessage: String, files: [VCSChangedFile], isMerge: Bool,
    insertions: Int? = nil, deletions: Int? = nil, pushScope: VCSPushScope? = nil
  ) {
    self.commit = commit
    self.fullMessage = fullMessage
    self.files = files
    self.isMerge = isMerge
    self.insertions = insertions
    self.deletions = deletions
    self.pushScope = pushScope
  }
}

/// Typed VCS failures. Each maps to a distinct, recoverable UI state (inline message + retry),
/// never a silent empty result.
public enum VCSError: Error, Equatable, Sendable {
  case unsupportedRepo(String)
  case notFound(String)
  case lockContention
  case staleSnapshot
  case partialData(String)
  case backendVersion(String)
  case io(String)
}

// MARK: - Remote state (the VCS inspector's toolbar)

/// How far a local ref has diverged from the remote ref its push/pull actually acts on.
///
/// `comparedTo` is the short form git itself prints — `origin/main` — because the toolbar's tooltip quotes it verbatim (the `VCSPushScope.unpushedHelp` rule: name the
/// ref, don't make the user guess what "behind" is behind).
///
/// Counts are always from the LOCAL ref's point of view: `ahead` = local commits the remote doesn't
/// have (what Push sends), `behind` = remote commits we don't have (what Pull brings).
///
/// `nil` counts mean "unanswerable", never zero: a branch with no counterpart under `refs/remotes/`. A missing badge beats a wrong one (same rule as
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
public struct VCSTracking: Equatable, Sendable {
  public let comparedTo: String
  public let ahead: Int?
  public let behind: Int?
  /// The counterpart ref is gone from the remote (or was never pushed). Counts are meaningless; the
  /// toolbar offers Publish rather than Push.
  public let gone: Bool

  public init(comparedTo: String, ahead: Int?, behind: Int?, gone: Bool) {
    self.comparedTo = comparedTo
    self.ahead = ahead
    self.behind = behind
    self.gone = gone
  }
}

/// When the repo last fetched. Three-way rather than `Date?` because the copy differs per case and
/// "can't tell" must never render as "no" (the `VCSPushState.unknown` rule).
public enum VCSLastFetch: Equatable, Sendable {
  case at(Date)
  /// No fetch has ever been recorded: git has no `FETCH_HEAD` (`clone`/`init` never write one).
  case never
  /// Unanswerable — the git dir couldn't be located, `FETCH_HEAD`'s attributes were unreadable, the
  /// user has `fetch.writeFetchHEAD=false`. Renders NO timestamp, and
  /// specifically never the word "never".
  case unknown
}

/// Everything the VCS inspector's toolbar renders, read as ONE coherent snapshot so the branch name
/// and the counts beside it can't come from two different reads of a moving repo.
public struct VCSRemoteState: Equatable, Sendable {
  /// The current branch, straight from `VCSProviding.currentRef` — the app's existing canonical
  /// answer, including `.detached`.
  public let current: VCSRef
  /// Divergence for `current`. `nil` ⇒ nothing to compare against (no counterpart on the remote,
  /// detached HEAD) ⇒ no counts render.
  public let tracking: VCSTracking?
  /// Configured remote names, first-listed first. Empty ⇒ no remote ⇒ every action is disabled.
  /// Derived from the ref list (`refs/remotes/<remote>/*`), so it costs no extra process.
  public let remotes: [String]
  /// The remote fetch/push/pull act on: `origin` when present, else the first remote, else `nil`.
  /// Interpolated into every UI string — the copy must never hardcode "origin", because
  /// `remote.pushDefault` can legitimately make that the wrong name.
  public let primaryRemote: String?
  /// Per-PROJECT, not per-workroom: fetch always runs at the project root, so every workroom of a
  /// project shares one answer. (git's `FETCH_HEAD` is per-worktree, so this is read from the COMMON
  /// git dir — see `CLIVCSWriter.commonGitDir`.)
  public let lastFetch: VCSLastFetch
  /// When this snapshot was read — the TTL key, and the `now` reference for the relative label.
  public let resolvedAt: Date

  public init(
    current: VCSRef, tracking: VCSTracking?, remotes: [String], primaryRemote: String?,
    lastFetch: VCSLastFetch, resolvedAt: Date
  ) {
    self.current = current
    self.tracking = tracking
    self.remotes = remotes
    self.primaryRemote = primaryRemote
    self.lastFetch = lastFetch
    self.resolvedAt = resolvedAt
  }
}
