import Foundation
import WorkroomVCS

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
    if s.failure == .asleep {
      // Not a failure: the box is asleep, and a probe would have woken it.
      return StatusDot(symbol: "moon.zzz", semantic: .neutral, accessibility: "asleep")
    }
    if s.isUnknown {
      // gh-style "absent" never reaches here; only genuine probe failures render unknown.
      let why: String
      switch s.failure {
      case .unavailable: why = "repository service unavailable"
      case .registrationRequired: why = "repository registration required"
      case .missingPath: why = "status unavailable, directory missing"
      case .notRepository: why = "status unavailable, not a repository"
      case .timeout: why = "status unavailable, timed out"
      case .busy: why = "status unavailable, repository is busy"
      case .staleWorkingCopy: why = "status unavailable, working copy is out of date"
      case .olderLayout: why = "status unavailable, workroom needs creating again"
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

  /// Tooltip / VoiceOver text for the Changes header's `+N −M`, or `nil` when there's no line delta to
  /// describe (the header falls back to the status dot). One helper because the tooltip and the
  /// VoiceOver label must say the same thing — they were two copies of the same string before.
  ///
  /// A conflicted working copy has its conflict markers materialized ON DISK, so those lines really are
  /// in the file, and every tool that measures the same state counts them: `git diff` on a conflicted
  /// worktree, and our own changeset header. So the count stays inclusive and SAYS so — suppressing it
  /// would make the two halves of our own UI disagree about the same file.
  static func lineCountsHelp(_ s: WorkroomStatus) -> String? {
    let ins = s.insertions ?? 0
    let del = s.deletions ?? 0
    guard ins > 0 || del > 0 else { return nil }
    let counts = "\(ins) insertions, \(del) deletions"
    guard s.conflicted else { return counts }
    return "conflicted — counts include conflict markers, \(counts)"
  }

  /// The full composed VoiceOver phrase for a row/chip, e.g. "dirty, CI failing".
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
    /// The typed identity (user login / team slug) — drives the avatar image URL.
    let identity: Reviewer.Identity
    let symbol: String
    let semantic: ReviewSemantic
    let stateLabel: String
    let accessibility: String
    /// The reviewer's submitted-review permalink (from `Reviewer.url`), or `nil` when there's no
    /// review to open. Drives whether the row is a tappable open-on-GitHub link.
    let url: String?
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
      id: r.id, displayName: name, identity: r.identity, symbol: symbol, semantic: semantic,
      stateLabel: label, accessibility: "\(name) \(label)", url: r.url)
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

  // MARK: Per-check rows (issue #75)

  enum CheckSemantic: Equatable {
    case passing, failing, pending, skipped, cancelled
  }
  /// One CI-check row: SF Symbol + semantic + a human state label, plus the check's details URL
  /// (`nil` ⇒ row not tappable). `id` is the check's collision-free identity, a stable `ForEach` key.
  struct CheckBadge: Equatable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let semantic: CheckSemantic
    let stateLabel: String
    let accessibility: String
    let link: String?
  }

  /// The check rows for the PR panel, sorted by attention then grouping: failing first, then
  /// pending, then pass/skip/cancel; within a severity band, same-workflow jobs stay together (so a
  /// matrix's `test (ubuntu)`/`test (macos)` don't scatter), then by name. This is the ONLY place
  /// check order is decided. Pure → unit-testable.
  static func checks(_ checks: [CICheck]) -> [CheckBadge] {
    checks
      .sorted { lhs, rhs in
        let l = checkSortRank(lhs.state)
        let r = checkSortRank(rhs.state)
        if l != r { return l < r }
        let lw = lhs.workflow ?? ""
        let rw = rhs.workflow ?? ""
        if lw != rw { return lw < rw }
        return lhs.name < rhs.name
      }
      .map(badge(for:))
  }

  private static func checkSortRank(_ s: CICheck.State) -> Int {
    switch s {
    case .failing: return 0
    case .pending: return 1
    case .passing: return 2
    case .skipped: return 3
    case .cancelled: return 4
    }
  }

  private static func badge(for c: CICheck) -> CheckBadge {
    let symbol: String
    let semantic: CheckSemantic
    let label: String
    switch c.state {
    case .passing:
      symbol = "checkmark.circle.fill"
      semantic = .passing
      label = "passing"
    case .failing:
      symbol = "xmark.octagon.fill"
      semantic = .failing
      label = "failing"
    case .pending:
      symbol = "clock.arrow.circlepath"
      semantic = .pending
      label = "running"
    case .skipped:
      symbol = "minus.circle"
      semantic = .skipped
      label = "skipped"
    case .cancelled:
      symbol = "minus.circle"
      semantic = .cancelled
      label = "cancelled"
    }
    let link = c.link.flatMap { $0.isEmpty ? nil : $0 }
    return CheckBadge(
      id: c.id, name: c.name, symbol: symbol, semantic: semantic, stateLabel: label,
      accessibility: "\(c.name) \(label)", link: link)
  }

  /// The aggregate summary glyph for the panel's CI line, *derived from the per-check list* so the
  /// summary and the rows can never contradict. Failure dominates > pending > passing > neutral
  /// (skip/cancel).
  /// `nil` when there are no checks → the panel shows no summary line. Reuses `CIGlyph` so the
  /// summary row renderer is unchanged.
  static func checksSummary(_ checks: [CICheck]) -> VCSStatusPresentation.CIGlyph? {
    guard !checks.isEmpty else { return nil }
    var anyPending = false
    var anyPassing = false
    var anyNeutral = false
    for c in checks {
      switch c.state {
      case .failing:
        return VCSStatusPresentation.CIGlyph(
          symbol: "xmark.octagon.fill", semantic: .ciFail, accessibility: "CI failing")
      case .pending: anyPending = true
      case .passing: anyPassing = true
      case .skipped, .cancelled: anyNeutral = true
      }
    }
    if anyPending {
      return VCSStatusPresentation.CIGlyph(
        symbol: "clock.arrow.circlepath", semantic: .ciRunning, accessibility: "CI running")
    }
    if anyPassing {
      return VCSStatusPresentation.CIGlyph(
        symbol: "checkmark.circle.fill", semantic: .ciPass, accessibility: "CI passing")
    }
    if anyNeutral {
      return VCSStatusPresentation.CIGlyph(
        symbol: "minus.circle", semantic: .neutral, accessibility: "CI cancelled")
    }
    return nil
  }

  /// Whether the PR's CI is failing — drives the red header number badge (issue #77). Uses the
  /// loaded per-check list when authoritative (`checksCheckedAt` set, mirroring the panel's
  /// `checksSummaryGlyph`), falling back to the branch CI aggregate (`WorkroomStatus.ci`) before the
  /// checks probe returns. Pure → unit-testable.
  static func isFailing(_ s: WorkroomStatus) -> Bool {
    if s.checksCheckedAt != nil {
      return checksSummary(s.checks ?? [])?.semantic == .ciFail
    }
    return s.ci == .failing
  }
}
