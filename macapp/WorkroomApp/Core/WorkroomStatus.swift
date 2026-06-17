import Foundation

/// CI conclusion for a workroom's branch, collapsed from the latest GitHub Actions run per
/// workflow. `nil` (absent) means "no CI to show" — gh missing, no remote, no runs, or the
/// runs are for a different commit. Absent renders as *nothing* (no glyph); it is NOT a state.
enum CIState: Equatable, Sendable {
  case passing
  case failing
  case running
  case neutral  // cancelled / skipped — completed without pass or fail
}

/// A write action on a pull request (Phase 2b), mapped to a `gh pr …` invocation. Pure so the
/// command, label, and state-availability are unit-testable without spawning `gh`.
enum PRAction: String, CaseIterable, Sendable {
  case markReady, convertToDraft, close, reopen

  var label: String {
    switch self {
    case .markReady: return "Mark Ready for Review"
    case .convertToDraft: return "Convert to Draft"
    case .close: return "Close Pull Request"
    case .reopen: return "Reopen Pull Request"
    }
  }

  var systemImage: String {
    switch self {
    case .markReady: return "checkmark.circle"
    case .convertToDraft: return "pencil.circle"
    case .close: return "xmark.circle"
    case .reopen: return "arrow.uturn.left.circle"
    }
  }

  /// Closing a PR is outward-facing enough to confirm first (it's reversible via reopen, but it
  /// changes the PR for everyone). The other actions act on the user's deliberate menu click.
  var needsConfirmation: Bool { self == .close }
  var isDestructive: Bool { self == .close }

  /// `gh` arguments for the action against PR `number`.
  func arguments(number: Int) -> [String] {
    switch self {
    case .markReady: return ["pr", "ready", "\(number)"]
    case .convertToDraft: return ["pr", "ready", "\(number)", "--undo"]
    case .close: return ["pr", "close", "\(number)"]
    case .reopen: return ["pr", "reopen", "\(number)"]
    }
  }

  /// The actions offered for a PR in its current state.
  static func available(for pr: PullRequestInfo) -> [PRAction] {
    switch pr.state {
    case .open: return [pr.isDraft ? .markReady : .convertToDraft, .close]
    case .closed: return [.reopen]
    case .merged: return []
    }
  }
}

/// Whether the GitHub CLI (`gh`) is usable for the PR/CI probes (machine-global, not per-workroom).
/// `available` is the optimistic default so no warning flashes before the first check; the others
/// drive a warning in the Pull Request inspector section and gate the `gh` probes so we don't spawn
/// `gh` pointlessly.
enum GitHubCLIStatus: Equatable, Sendable {
  case available
  case notInstalled  // gh not on PATH (env exit 127)
  case notAuthenticated  // gh present but `gh auth status` fails (not logged in)
}

/// Why a status probe couldn't produce a clean/dirty answer. Drives the "unknown" badge.
/// `notRepository` is distinct from `clean`: a path the model says is a repo but isn't is
/// broken/stale, not clean.
enum VCSStatusFailure: Equatable, Sendable {
  case missingPath  // workroom directory gone
  case notRepository  // path exists but isn't the expected VCS repo (git exit 128)
  case timeout  // probe exceeded its deadline (slow disk, index.lock contention)
}

/// One changed path in the working tree, with its change kind (for the detail panel grouping).
struct ChangedFile: Equatable, Hashable, Identifiable, Sendable {
  enum Change: String, Equatable, Sendable {
    case modified, added, deleted, renamed, untracked, conflicted, other
  }
  let path: String
  let change: Change
  var id: String { "\(change.rawValue):\(path)" }
}

/// One reviewer on a pull request (issue #52): either someone who has *submitted* a review
/// (`latestReviews`) or someone who's been *requested* but hasn't yet (`reviewRequests`). The
/// identity is typed so a requested team (which has a `slug`, not a `login`) can never collide
/// with a user in the dedup. Pure data — the per-reviewer glyph/label/sort live in `PRPresentation`.
struct Reviewer: Equatable, Sendable, Identifiable {
  /// A user (keyed by GitHub `login`) or a requested team (keyed by `slug`). Prefixed in `id` so
  /// `user:octocat` and `team:octocat` are distinct keys.
  enum Identity: Equatable, Sendable, Hashable {
    case user(login: String)
    case team(slug: String)
  }
  /// `requested` = in `reviewRequests` (asked, no submitted review yet). The rest mirror GitHub's
  /// submitted-review states; an unrecognised state is dropped at parse time, never stored.
  enum State: Equatable, Sendable {
    case requested
    case approved, changesRequested, commented, dismissed
  }
  let identity: Identity
  let state: State
  var id: String {
    switch identity {
    case .user(let login): return "user:\(login)"
    case .team(let slug): return "team:\(slug)"
    }
  }
}

/// The pull request for a workroom's branch (Phase 2), resolved via `gh pr list --head`. Read-only
/// in this iteration — the Pull Request inspector section shows it; create/merge/etc. come later.
struct PullRequestInfo: Equatable, Sendable {
  /// GitHub's PR `state` (a draft is still `open` — see `isDraft`).
  enum State: String, Equatable, Sendable { case open, merged, closed }
  /// GitHub's `reviewDecision`; `nil` when no review is required or none has been given yet. Kept
  /// (issue #52) as the aggregate header above the per-reviewer rows — branch-protection/CODEOWNERS
  /// can require a review with no concrete reviewer rows, so the rows alone can't carry this signal.
  enum ReviewDecision: String, Equatable, Sendable {
    case approved, changesRequested, reviewRequired
  }
  let number: Int
  let title: String
  let state: State
  let isDraft: Bool
  let url: String
  let reviewDecision: ReviewDecision?
  /// Per-reviewer status (issue #52). No default: every construction site must pass it, so the
  /// compiler — not a runtime test — guarantees a rebuild (e.g. `applyFixturePRAction`) can't
  /// silently drop reviewers. Order is not significant here; `PRPresentation.reviewers` sorts.
  let reviewers: [Reviewer]
}

/// A point-in-time snapshot of one workroom's VCS + CI status, resolved app-side.
///
/// `dirty == nil` means **unknown** (a probe failed) — never rendered as clean. `clean` is
/// `dirty == false`. `ahead`/`behind` are `nil` when there's no upstream (git) or for jj
/// (Phase 1 omits jj ahead/behind rather than fake git semantics). `changedFiles` is the
/// (capped) working-tree change list used by the detail panel. `ci` is filled by a separate,
/// slower second-stage probe so a wedged `gh` never blocks the dirty dot. `branchForCI` is the
/// git branch name (used to look up CI) when resolvable. PR fields are intentionally reserved
/// for Phase 2 so this snapshot *extends* rather than gets replaced.
struct WorkroomStatus: Equatable, Sendable {
  var dirty: Bool?
  var conflicted: Bool = false
  var ahead: Int?
  var behind: Int?
  var changedFiles: [ChangedFile]?
  /// Working-tree line counts vs the last commit (git: `diff --shortstat HEAD`; jj: `diff --stat`).
  /// `nil` ⇒ not resolved; both 0 ⇒ no line delta (e.g. only untracked files, which git omits).
  var insertions: Int?
  var deletions: Int?
  var ci: CIState?
  var failure: VCSStatusFailure?
  var branchForCI: String?
  /// jj only: the working-copy change's bookmarks + tags (git uses `branchForCI`). `nil` ⇒ a git
  /// repo; an empty array ⇒ a jj change with no bookmark/tag. Drives the Changes-panel header.
  var jjRefs: [String]?
  /// jj only: the working-copy change's description first line; `nil` ⇒ "(no description set)".
  var jjDescription: String?
  /// jj only: the working copy's (`@`) ids for the Changes header. `jjChangeID` is the change-id's
  /// shortest unique prefix on its own (no padding); `jjCommitID` is the shortest-8 commit-id. So
  /// the header shows the jj-log line for the changeset, not just the bookmark.
  var jjChangeID: String?
  var jjCommitID: String?
  /// The branch's pull request (Phase 2), resolved by a separate slow `gh` probe like `ci`. `nil` ⇒
  /// none resolved (no PR, no remote, gh missing, or not yet probed).
  var pr: PullRequestInfo?
  var lastChecked: Date?
  /// When CI was last probed — separate from `lastChecked` because CI has a much longer TTL
  /// (the local git probe refreshes often; the network `gh` call should not).
  var ciCheckedAt: Date?
  /// When the PR was last probed — its own TTL/backoff, like `ciCheckedAt`.
  var prCheckedAt: Date?

  /// Not yet probed (first render before the sweep resolves it).
  static let unresolved = WorkroomStatus()

  var isUnknown: Bool { dirty == nil }
  var isClean: Bool { dirty == false && !conflicted }
  var hasUpstream: Bool { ahead != nil || behind != nil }

  /// Scan-severity for the project-row aggregate: higher wins.
  /// missingPath/notRepository(unknown) > conflicted > dirty > clean/unresolved.
  var aggregateWeight: Int {
    if conflicted { return 3 }
    if failure == .missingPath || failure == .notRepository { return 1 }  // unknown, low
    if dirty == true { return 2 }
    return 0
  }
}

/// Pure mapping from a `WorkroomStatus` to the badge's SF Symbol + semantic color + composed
/// accessibility text. Extracted from the view so it's unit-testable and shared by the sidebar
/// row, tab chip, and project aggregate. Glyph + label carry meaning *without* color (color is
/// additive) so color-blind users and window-blur dimming (issue #43) don't lose the signal.
enum VCSStatusPresentation {
  /// The dirty/conflict/unknown status dot. `nil` = clean → render nothing (clean is quiet, so
  /// dirty pops). Color names map to semantic SwiftUI colors at the view layer.
  struct StatusDot: Equatable {
    let symbol: String  // SF Symbol name
    let semantic: Semantic
    let accessibility: String
  }
  /// CI glyph. `nil` = no CI to show → render nothing.
  struct CIGlyph: Equatable {
    let symbol: String
    let semantic: Semantic
    let accessibility: String
  }
  enum Semantic: Equatable { case dirty, conflict, unknown, ciPass, ciFail, ciRunning, neutral }

  static func dot(_ s: WorkroomStatus) -> StatusDot? {
    if s.conflicted {
      return StatusDot(
        symbol: "exclamationmark.triangle.fill", semantic: .conflict, accessibility: "conflicted")
    }
    if s.isUnknown {
      // gh-style "absent" never reaches here; only genuine probe failures render unknown.
      let why: String
      switch s.failure {
      case .missingPath: why = "status unavailable, directory missing"
      case .notRepository: why = "status unavailable, not a repository"
      case .timeout: why = "status unavailable, timed out"
      default: why = "status unavailable"
      }
      return StatusDot(symbol: "questionmark.circle", semantic: .unknown, accessibility: why)
    }
    if s.dirty == true {
      return StatusDot(
        symbol: "circle.fill", semantic: .dirty, accessibility: "working tree has changes")
    }
    return nil  // clean → nothing
  }

  static func ci(_ s: WorkroomStatus) -> CIGlyph? {
    guard let ci = s.ci else { return nil }
    switch ci {
    case .passing:
      return CIGlyph(
        symbol: "checkmark.circle.fill", semantic: .ciPass, accessibility: "CI passing")
    case .failing:
      return CIGlyph(symbol: "xmark.octagon.fill", semantic: .ciFail, accessibility: "CI failing")
    case .running:
      return CIGlyph(
        symbol: "clock.arrow.circlepath", semantic: .ciRunning, accessibility: "CI running")
    case .neutral:
      return CIGlyph(symbol: "minus.circle", semantic: .neutral, accessibility: "CI cancelled")
    }
  }

  /// Ahead/behind compact text + symbols, or nil when there's no upstream / nothing to show.
  /// "↑2 ↓1" semantics rendered with SF Symbols at the view; here we give the counts + a label.
  struct AheadBehind: Equatable {
    let ahead: Int
    let behind: Int
    let accessibility: String
  }
  static func aheadBehind(_ s: WorkroomStatus) -> AheadBehind? {
    let a = s.ahead ?? 0
    let b = s.behind ?? 0
    guard s.hasUpstream, a != 0 || b != 0 else { return nil }
    var parts: [String] = []
    if a != 0 { parts.append("ahead \(a)") }
    if b != 0 { parts.append("behind \(b)") }
    return AheadBehind(ahead: a, behind: b, accessibility: parts.joined(separator: ", "))
  }

  /// The full composed VoiceOver phrase for a row/chip, e.g. "dirty, ahead 2, CI failing".
  /// Empty string when there's nothing to announce (clean, no CI).
  static func accessibilityLabel(_ s: WorkroomStatus) -> String {
    var parts: [String] = []
    if s.conflicted {
      parts.append("conflicted")
    } else if s.isUnknown {
      parts.append(dot(s)?.accessibility ?? "status unavailable")
    } else if s.dirty == true {
      parts.append("dirty")
    } else if s.dirty == false {
      parts.append("clean")
    }
    if let ab = aheadBehind(s) { parts.append(ab.accessibility) }
    if let ci = ci(s) { parts.append(ci.accessibility) }
    return parts.joined(separator: ", ")
  }
}

/// Pure mapping from a `PullRequestInfo` to its state badge (SF Symbol + semantic color + label)
/// and review-decision label. Extracted from the view so it's unit-testable and the badge reads
/// the same way everywhere. A draft outranks `open` for the badge (it's the more useful signal).
enum PRPresentation {
  enum Semantic: Equatable { case open, draft, merged, closed }
  struct StateBadge: Equatable {
    let label: String
    let symbol: String  // SF Symbol name
    let semantic: Semantic
  }

  static func badge(_ pr: PullRequestInfo) -> StateBadge {
    switch pr.state {
    case .merged:
      return StateBadge(label: "Merged", symbol: "arrow.triangle.merge", semantic: .merged)
    case .closed:
      return StateBadge(label: "Closed", symbol: "xmark.circle.fill", semantic: .closed)
    case .open:
      return pr.isDraft
        ? StateBadge(label: "Draft", symbol: "pencil.circle", semantic: .draft)
        : StateBadge(label: "Open", symbol: "arrow.triangle.branch", semantic: .open)
    }
  }

  /// Human label for the aggregate review decision (the header above the per-reviewer rows), or nil
  /// when there's nothing to announce.
  static func reviewLabel(_ decision: PullRequestInfo.ReviewDecision?) -> String? {
    switch decision {
    case .approved: return "Approved"
    case .changesRequested: return "Changes requested"
    case .reviewRequired: return "Review required"
    case nil: return nil
    }
  }

  // MARK: Per-reviewer rows (issue #52)

  enum ReviewSemantic: Equatable {
    case approved, changesRequested, commented, requested, dismissed
  }
  /// One reviewer row: SF Symbol + semantic + a human/bot-aware state label. `id` is the reviewer's
  /// collision-free identity (`user:` / `team:`), so it's a stable, unique `ForEach` key.
  struct ReviewerBadge: Equatable, Identifiable {
    let id: String
    let displayName: String  // bot-friendly (e.g. "Copilot"); team → its slug
    let symbol: String
    let semantic: ReviewSemantic
    let stateLabel: String
    let accessibility: String
  }

  /// The reviewer rows for the PR panel, sorted by attention (changes-requested first) then `id`
  /// for determinism. This is the ONLY place reviewer order is decided. Pure → unit-testable.
  static func reviewers(_ pr: PullRequestInfo) -> [ReviewerBadge] {
    pr.reviewers
      .sorted { lhs, rhs in
        let l = sortRank(lhs.state)
        let r = sortRank(rhs.state)
        return l == r ? lhs.id < rhs.id : l < r
      }
      .map(badge(for:))
  }

  private static func sortRank(_ s: Reviewer.State) -> Int {
    switch s {
    case .changesRequested: return 0
    case .requested: return 1
    case .commented: return 2
    case .approved: return 3
    case .dismissed: return 4
    }
  }

  private static func badge(for r: Reviewer) -> ReviewerBadge {
    let name = displayName(r.identity)
    let symbol: String
    let semantic: ReviewSemantic
    let label: String
    switch r.state {
    case .approved:
      symbol = "checkmark.circle.fill"
      semantic = .approved
      label = "approved"
    case .changesRequested:
      symbol = "xmark.circle.fill"
      semantic = .changesRequested
      label = "changes requested"
    case .commented:
      symbol = "text.bubble"
      semantic = .commented
      label = "commented"
    case .requested:
      // A bot in `reviewRequests` is actively generating ("in progress"); a human just hasn't
      // started yet ("review requested"). The API can't tell us more.
      symbol = "clock.arrow.circlepath"
      semantic = .requested
      label = isBot(r.identity) ? "in progress" : "review requested"
    case .dismissed:
      symbol = "minus.circle"
      semantic = .dismissed
      label = "dismissed"
    }
    return ReviewerBadge(
      id: r.id, displayName: name, symbol: symbol, semantic: semantic, stateLabel: label,
      accessibility: "\(name) \(label)")
  }

  /// Display name: friendly for known bots, the team slug for teams, else the raw login.
  static func displayName(_ identity: Reviewer.Identity) -> String {
    switch identity {
    case .team(let slug): return slug
    case .user(let login):
      if login == "copilot-pull-request-reviewer" { return "Copilot" }
      if login.hasSuffix("[bot]") { return String(login.dropLast("[bot]".count)) }
      return login
    }
  }

  /// Whether this identity is a bot — drives "in progress" vs "review requested". Teams are humans.
  static func isBot(_ identity: Reviewer.Identity) -> Bool {
    guard case .user(let login) = identity else { return false }
    return login.hasSuffix("[bot]") || login == "copilot-pull-request-reviewer"
  }
}
