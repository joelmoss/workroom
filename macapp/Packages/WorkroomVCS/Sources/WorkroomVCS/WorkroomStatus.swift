import Foundation

/// CI conclusion for a workroom's branch, from GitHub's status-check rollup for the branch-tip
/// commit (#76) — *all* check types (Actions + external commit statuses + check-run apps), not just
/// Actions runs. `nil` (absent) means "no CI to show" — gh missing, no remote, or the commit has no
/// checks. Absent renders as *nothing* (no glyph); it is NOT a state. `.neutral` is no longer
/// produced by the sidebar rollup path (rollup folds skipped/neutral into passing), but the PR
/// panel's per-check `checksSummary` still distinguishes it, so the case stays.
public enum CIState: Equatable, Sendable {
  case passing
  case failing
  case running
  case neutral  // cancelled / skipped — completed without pass or fail
}

/// A write action on a pull request (Phase 2b), mapped to a `gh pr …` invocation. Pure so the
/// command, label, and state-availability are unit-testable without spawning `gh`.
public enum PRAction: String, CaseIterable, Sendable {
  case markReady, convertToDraft, close, reopen

  public var label: String {
    switch self {
    case .markReady: return "Ready for Review"
    case .convertToDraft: return "Convert to Draft"
    case .close: return "Close Pull Request"
    case .reopen: return "Reopen Pull Request"
    }
  }

  public var systemImage: String {
    switch self {
    case .markReady: return "checkmark.circle"
    case .convertToDraft: return "pencil.circle"
    case .close: return "xmark.circle"
    case .reopen: return "arrow.uturn.left.circle"
    }
  }

  /// Closing a PR is outward-facing enough to confirm first (it's reversible via reopen, but it
  /// changes the PR for everyone). The other actions act on the user's deliberate menu click.
  public var needsConfirmation: Bool { self == .close }
  public var isDestructive: Bool { self == .close }

  /// `gh` arguments for the action against PR `number`.
  public func arguments(number: Int) -> [String] {
    switch self {
    case .markReady: return ["pr", "ready", "\(number)"]
    case .convertToDraft: return ["pr", "ready", "\(number)", "--undo"]
    case .close: return ["pr", "close", "\(number)"]
    case .reopen: return ["pr", "reopen", "\(number)"]
    }
  }

  /// The actions offered for a PR in its current state.
  public static func available(for pr: PullRequestInfo) -> [PRAction] {
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
public enum GitHubCLIStatus: Equatable, Sendable {
  case available
  case notInstalled  // gh not on PATH (env exit 127)
  case notAuthenticated  // gh present but `gh auth status` fails (not logged in)
  /// gh is installed and possibly signed in, but too old to answer us: it rejects `--active` /
  /// `--json` (both gh ≥ 2.57) outright rather than ignoring them, so no probe can ever succeed.
  /// Distinct from `notAuthenticated` because `gh auth login` cannot fix it — only an upgrade can,
  /// and telling such a user they're "not signed in" sends them down the wrong path entirely.
  case tooOld
}

/// Why a status probe couldn't produce a clean/dirty answer. Drives the "unknown" badge.
/// `notRepository` is distinct from `clean`: a path the model says is a repo but isn't is
/// broken/stale, not clean.
public enum VCSStatusFailure: Equatable, Sendable {
  case unavailable
  case registrationRequired
  case missingPath  // workroom directory gone
  case notRepository  // path exists but isn't the expected VCS repo (git exit 128)
  case timeout  // probe exceeded its deadline (slow disk, index.lock contention)
  case busy  // the repository refused the read as busy (lock contention)
  case staleWorkingCopy  // the working tree changed while it was being read; a retry settles it
  case asleep  // a boxd box its provider put to sleep; a probe leaves it be (#356)
  case olderLayout  // a host an older Nightly made before the daemon was renamed (#525)
}

/// One changed path in the working tree, with its change kind (for the detail panel grouping).
///
/// `oldPath` is the pre-move path, set only for `.renamed` (renames are detected via libgit2's status
/// rename options, or git's own rename detection on the agent path). It stays
/// out of `id` on purpose — a row's identity is where the file is NOW, so a rename doesn't reshuffle
/// selection when the old path changes.
public struct ChangedFile: Equatable, Hashable, Identifiable, Sendable {
  public enum Change: String, Equatable, Sendable {
    case modified, added, deleted, renamed, untracked, conflicted, other
  }
  public let path: String
  public let change: Change
  public var oldPath: String?
  public var id: String { "\(change.rawValue):\(path)" }

  public init(path: String, change: Change, oldPath: String? = nil) {
    self.path = path
    self.change = change
    self.oldPath = oldPath
  }
}

/// One reviewer on a pull request (issue #52): either someone who has *submitted* a review
/// (`latestReviews`) or someone who's been *requested* but hasn't yet (`reviewRequests`). The
/// identity is typed so a requested team (which has a `slug`, not a `login`) can never collide
/// with a user in the dedup. Pure data — the per-reviewer glyph/label/sort live in `PRPresentation`.
public struct Reviewer: Equatable, Sendable, Identifiable {
  /// A user (keyed by GitHub `login`) or a requested team (keyed by `slug`). Prefixed in `id` so
  /// `user:octocat` and `team:octocat` are distinct keys.
  public enum Identity: Equatable, Sendable, Hashable {
    case user(login: String)
    case team(slug: String)
  }
  /// `requested` = in `reviewRequests` (asked, no submitted review yet). The rest mirror GitHub's
  /// submitted-review states; an unrecognised state is dropped at parse time, never stored.
  public enum State: Equatable, Sendable {
    case requested
    case approved, changesRequested, commented, dismissed
  }
  public let identity: Identity
  public let state: State
  /// Permalink to this reviewer's submitted review (`…/pull/N#pullrequestreview-<id>`), so the row
  /// can deep-link straight to their comment. `nil` for a pending (`requested`) reviewer or a team
  /// (no review to open yet). `gh pr list --json` blanks review urls, so a follow-up GraphQL probe
  /// (`resolvePR`) fills this in — `classifyPR` alone always leaves it `nil`.
  public var url: String?
  public var id: String {
    switch identity {
    case .user(let login): return "user:\(login)"
    case .team(let slug): return "team:\(slug)"
    }
  }

  public init(identity: Identity, state: State, url: String? = nil) {
    self.identity = identity
    self.state = state
    self.url = url
  }
}

/// The pull request for a workroom's branch (Phase 2), resolved via `gh pr list --head`. Read-only
/// in this iteration — the Pull Request inspector section shows it; create/merge/etc. come later.
public struct PullRequestInfo: Equatable, Sendable {
  /// GitHub's PR `state` (a draft is still `open` — see `isDraft`).
  public enum State: String, Equatable, Sendable { case open, merged, closed }
  /// GitHub's `reviewDecision`; `nil` when no review is required or none has been given yet. Kept
  /// (issue #52) as the aggregate header above the per-reviewer rows — branch-protection/CODEOWNERS
  /// can require a review with no concrete reviewer rows, so the rows alone can't carry this signal.
  public enum ReviewDecision: String, Equatable, Sendable {
    case approved, changesRequested, reviewRequired
  }
  /// GitHub's `mergeStateStatus` (issue #88) — the richer merge signal behind the Merge button.
  /// `.unknown` is GitHub still computing (transient after a push); an unrecognised future value
  /// also maps here so it's treated as not-yet-mergeable rather than misread as clean.
  public enum MergeState: String, Equatable, Sendable {
    case clean, blocked, behind, unstable, dirty, draft, hasHooks, unknown
  }
  public let number: Int
  public let title: String
  public let state: State
  public let isDraft: Bool
  public let url: String
  public let reviewDecision: ReviewDecision?
  /// Per-reviewer status (issue #52). No default: every construction site must pass it, so the
  /// compiler — not a runtime test — guarantees a rebuild (e.g. `applyOptimisticPRAction`) can't
  /// silently drop reviewers. Order is not significant here; `PRPresentation.reviewers` sorts.
  public let reviewers: [Reviewer]
  /// GitHub's `mergeable` (issue #88): `MERGEABLE` → `true`, `CONFLICTING` → `false`, `UNKNOWN`
  /// / absent → `nil` (also "not yet probed"). `nil`/`false` hides the Merge button. Optional with
  /// a default so it's additive — every construction site need not pass it (unlike `reviewers`).
  public var mergeable: Bool? = nil
  /// GitHub's `mergeStateStatus` (issue #88), mapped to `MergeState`; `nil` = not probed / absent.
  public var mergeState: MergeState? = nil

  /// Whether the split-button Merge action should be offered (issue #88): an open, non-draft PR
  /// that GitHub reports as mergeable with a merge-state that actually permits merging. Deliberately
  /// conservative — a state we can't confirm as mergeable (conflicts, branch-protection block, draft,
  /// or GitHub still computing) hides the button rather than showing one that would just error.
  public var canMerge: Bool {
    guard state == .open, !isDraft, mergeable == true else { return false }
    switch mergeState {
    case .clean, .unstable, .hasHooks, .behind: return true
    case .blocked, .dirty, .draft, .unknown, .none: return false
    }
  }

  public init(
    number: Int, title: String, state: State, isDraft: Bool, url: String,
    reviewDecision: ReviewDecision?, reviewers: [Reviewer], mergeable: Bool? = nil,
    mergeState: MergeState? = nil
  ) {
    self.number = number
    self.title = title
    self.state = state
    self.isDraft = isDraft
    self.url = url
    self.reviewDecision = reviewDecision
    self.reviewers = reviewers
    self.mergeable = mergeable
    self.mergeState = mergeState
  }
}

/// One CI check on a pull request (issue #75), from `gh pr checks <n> --json
/// name,state,bucket,link,workflow`. `state` is mapped from gh's normalized `bucket` (the most
/// reliable field — `state` is the raw conclusion). `link` is the per-check details URL, blank for a
/// check with nowhere to deep-link (then the row isn't tappable, like a pending reviewer). Pure data
/// — the per-check glyph/label/sort live in `PRPresentation`.
public struct CICheck: Equatable, Sendable, Identifiable {
  /// Mapped from gh's `bucket`: pass/fail/pending/skipping/cancel. An unknown bucket maps to
  /// `.skipped` (quiet) rather than being dropped, so a future gh value still renders a row.
  public enum State: Equatable, Sendable { case passing, failing, pending, skipped, cancelled }
  public let name: String
  public let state: State
  public let workflow: String?  // workflow name; groups matrix jobs in the sort
  public let link: String?  // per-check URL; nil/"" ⇒ row not tappable
  /// `workflow:name` so two checks of the same name in different workflows stay distinct `ForEach` keys.
  public var id: String { "\(workflow ?? "_"):\(name)" }

  public init(name: String, state: State, workflow: String?, link: String?) {
    self.name = name
    self.state = state
    self.workflow = workflow
    self.link = link
  }
}

/// A status clock that compares by whether it is set, never by its time (#503).
///
/// Only the sweep's TTL gates and `mergeLocalStatus`'s read ordering read a clock's value; views ask
/// only whether one is set (the Changes panel's "Checking…", the PR panel's loaded markers). So a
/// probe that changed nothing on screen yields an equal status, and the `@Observable` store stores an
/// equal value without notifying: the fresh clocks are kept and nothing redraws. That needs every
/// status write to be a whole-value set, as `AppStore.workroomStatuses`'s proxy makes it; an in-place
/// subscript write on the store itself would notify regardless.
@propertyWrapper
public struct PresenceEquatable<Value: Sendable>: Equatable, Sendable {
  public var wrappedValue: Value?

  public init(wrappedValue: Value?) {
    self.wrappedValue = wrappedValue
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    (lhs.wrappedValue == nil) == (rhs.wrappedValue == nil)
  }
}

/// A point-in-time snapshot of one workroom's VCS + CI status, resolved app-side.
///
/// `dirty == nil` means **unknown** (a probe failed) — never rendered as clean. `clean` is
/// `dirty == false`. `changedFiles` is the
/// (capped) working-tree change list used by the detail panel. `ci` is filled by a separate,
/// slower second-stage probe so a wedged `gh` never blocks the dirty dot. `branchForCI` is the
/// git branch name (used to look up CI) when resolvable. PR fields are intentionally reserved
/// for Phase 2 so this snapshot *extends* rather than gets replaced. Its five clocks compare by
/// presence (`PresenceEquatable`); every other field by value.
public struct WorkroomStatus: Equatable, Sendable {
  public var dirty: Bool?
  public var conflicted: Bool = false
  public var changedFiles: [ChangedFile]?
  /// Working-tree line counts vs the last commit, summed per-file patch stats.
  /// `nil` ⇒ not resolved; both 0 ⇒ no line delta (e.g. only untracked files, which git omits).
  ///
  /// While `conflicted`, the totals INCLUDE the materialized conflict markers, because those lines
  /// really are in the file — git reports the same for a conflicted worktree. The header says so
  /// rather than quietly under- or over-reporting; see `VCSStatusPresentation.lineCountsHelp`.
  public var insertions: Int?
  public var deletions: Int?
  public var ci: CIState?
  public var failure: VCSStatusFailure?
  public var branchForCI: String?
  /// The branch's pull request (Phase 2), resolved by a separate slow `gh` probe like `ci`. `nil` ⇒
  /// none resolved (no PR, no remote, gh missing, or not yet probed).
  public var pr: PullRequestInfo?
  /// The PR's individual CI checks (issue #75), resolved by a separate `gh pr checks` probe on
  /// selection. Three-state, deliberately: `nil` ⇒ **not loaded** (probe hasn't returned, so the
  /// panel falls back to the branch CI aggregate summary, `WorkroomStatus.ci`); `[]` ⇒ **loaded, no checks** (the PR
  /// genuinely has none, so the panel shows no summary/list rather than the stale aggregate);
  /// non-empty ⇒ the checks to list. `checksCheckedAt` is the loaded marker that disambiguates `nil`
  /// from `[]`. Cleared whenever the PR's identity changes or the PR goes away (see `applyPRStatus`).
  public var checks: [CICheck]?
  @PresenceEquatable public var lastChecked: Date?
  /// When the local read behind these values FINISHED, stamped by
  /// `WorkroomStatusResolver.resolve(location:)`. Five independent lanes probe local status (see
  /// `AppStore+WorkroomStatus`), none ordered against the others, so a slow probe can merge after a
  /// faster one that read the tree LATER — and `lastChecked` cannot tell those apart, because it
  /// records the landing, not the read. This is what `mergeLocalStatus` compares to refuse a result
  /// stamped earlier than the one it already holds. Local-probe fields only; the CI/PR stages keep
  /// their own clocks above.
  @PresenceEquatable public var localReadAt: Date?
  /// When CI was last probed — separate from `lastChecked` because CI has a much longer TTL
  /// (the local git probe refreshes often; the network `gh` call should not).
  @PresenceEquatable public var ciCheckedAt: Date?
  /// When the PR was last probed — its own TTL/backoff, like `ciCheckedAt`.
  @PresenceEquatable public var prCheckedAt: Date?
  /// When the PR's checks were last probed. The loaded marker for `checks`: `nil` ⇒ not yet probed
  /// (panel uses the run-list aggregate fallback); set ⇒ `checks` (possibly `[]`) is authoritative.
  @PresenceEquatable public var checksCheckedAt: Date?

  /// Not yet probed (first render before the sweep resolves it).
  public static let unresolved = WorkroomStatus()

  public var isUnknown: Bool { dirty == nil }
  public var isClean: Bool { dirty == false && !conflicted }

  /// Scan-severity for the project-row aggregate: higher wins.
  /// missingPath/notRepository(unknown) > conflicted > dirty > clean/unresolved.
  public var aggregateWeight: Int {
    if conflicted { return 3 }
    switch failure {
    // Unknown-because-the-probe-failed: above clean, below dirty. `.timeout` is left out, as before.
    case .unavailable, .registrationRequired, .missingPath, .notRepository, .busy,
      .staleWorkingCopy, .olderLayout:
      return 1
    case .timeout, .asleep, nil: break
    }
    if dirty == true { return 2 }
    return 0
  }

  public init(
    dirty: Bool? = nil, conflicted: Bool = false, changedFiles: [ChangedFile]? = nil,
    insertions: Int? = nil, deletions: Int? = nil, ci: CIState? = nil,
    failure: VCSStatusFailure? = nil, branchForCI: String? = nil, pr: PullRequestInfo? = nil,
    checks: [CICheck]? = nil, lastChecked: Date? = nil, localReadAt: Date? = nil,
    ciCheckedAt: Date? = nil, prCheckedAt: Date? = nil, checksCheckedAt: Date? = nil
  ) {
    self.dirty = dirty
    self.conflicted = conflicted
    self.changedFiles = changedFiles
    self.insertions = insertions
    self.deletions = deletions
    self.ci = ci
    self.failure = failure
    self.branchForCI = branchForCI
    self.pr = pr
    self.checks = checks
    self.lastChecked = lastChecked
    self.localReadAt = localReadAt
    self.ciCheckedAt = ciCheckedAt
    self.prCheckedAt = prCheckedAt
    self.checksCheckedAt = checksCheckedAt
  }
}
