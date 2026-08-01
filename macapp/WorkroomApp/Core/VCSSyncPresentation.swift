import Foundation

/// What the VCS toolbar's middle segment is currently doing.
enum VCSSyncActivity: Equatable, Sendable {
  case idle
  case running(VCSRemoteAction)
}

/// Everything the toolbar's sync segment renders, resolved from one state snapshot.
///
/// A pure mapping, kept out of the view for the same reason as `ChangeBadge`: it's a many-case
/// decision that silently drifts. `now` is a parameter rather than a `Date()` read so the whole thing
/// is testable at fixed instants.
struct VCSSyncPresentation: Equatable, Sendable {
  /// Title variants, LONGEST FIRST, for a `ViewThatFits` ladder. Empty ⇒ single-line mode: the segment
  /// renders only `subtitle`, vertically centred, at a larger weight.
  var titleVariants: [String] = []
  var subtitle: String
  /// A shorter subtitle for narrow widths. The staleness caveat abbreviates but must never be the
  /// first thing dropped — the unverified count it qualifies is the thing that should yield.
  var subtitleShort: String
  var symbol: String?
  var badge: Badge?
  var secondaryBadge: Badge?
  var action: VCSRemoteAction?
  var isEnabled: Bool
  var tone: Tone = .normal
  var help: String
  /// Spoken label. The count pills are `accessibilityHidden`, so their information has to arrive here.
  var accessibility: String
  var accessibilityValue: String = ""
  /// The blocking lock file, when there is one. Carried so the segment can offer to copy or reveal it —
  /// the fix is a file operation the user performs, so the least Workroom can do is hand them the path
  /// rather than make them transcribe it out of a tooltip.
  var lockPath: String?

  struct Badge: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case ahead, behind }
    let count: Int
    let direction: Direction
  }

  enum Tone: Equatable, Sendable { case normal, warning, failure }

  var title: String? { titleVariants.first }
  var isSingleLine: Bool { titleVariants.isEmpty }
}

/// Maps a `VCSRemoteState` to what the sync segment shows.
///
/// ```
///   failure?  ──yes──►  [13] retry the previous action          tone: failure
///      │no
///   in flight? ──yes──►  [10/11/12] Fetching…/Pushing…/Pulling…      disabled
///      │no
///   target valid? ──no──►  [1] no workroom  ·  [2] no repository     disabled
///      │yes
///   tools ok? ──no──►  [0] "<tool> is too old"                       disabled
///      │yes
///   has remote? ──no───►  [3] "No remote configured"                 disabled
///      │yes
///   counterpart gone? ──yes──►  [4] "Publish branch"      → push --set-upstream
///      │no
///   ahead>0 && behind>0 ──yes──►  [9] "Pull <remote> with rebase"   badge: M↓ then N↑
///      │no                             (pull, NOT push — git refuses non-ff)
///   behind>0 ──yes──►  [8] "Pull <remote> with rebase"              badge: M↓
///      │no
///   ahead>0  ──yes──►  [7] "Push <remote>"                          badge: N↑
///      │no
///   never fetched ──yes──►  [5] "Never fetched"          → fetch
///      │no
///                        [6] "Fetched <rel>"            → fetch
/// ```
///
/// `<remote>` is always interpolated from `primaryRemote`, never the literal "origin" —
/// `remote.pushDefault` can legitimately make that the wrong name.
enum VCSSyncPresenter {

  /// Build the presentation.
  ///
  /// - Parameters:
  ///   - state: `nil` ⇒ no readable repo for the current target.
  ///   - hasTarget: whether a workroom is selected at all (distinguishes "nothing selected" from
  ///     "selected, but not a repo" — different copy, both disabled).
  ///   - toolsUsable: `false` ⇒ the `git`/`jj` on PATH can't run these commands
  ///     (`VCSToolVersions`). Outranks everything except an in-flight action and a failure, because no
  ///     action can succeed.
  ///   - pullRebase: whether the repo pulls with rebase — wording only.
  static func make(
    state: VCSRemoteState?, hasTarget: Bool, toolsUsable: Bool = true,
    activity: VCSSyncActivity = .idle, failure: VCSRemoteFailure? = nil,
    lastAction: VCSRemoteAction? = nil, pullRebase: Bool = true, pullConflicted: Bool = false,
    now: Date
  ) -> VCSSyncPresentation {
    // [13] A failure outranks everything: it's the only state with something to recover from, and
    // burying it under a count would leave the user with no idea the action didn't happen.
    if let failure, case .idle = activity {
      let message = describe(failure)
      let recovery = retryAction(for: failure, lastAction: lastAction)
      return VCSSyncPresentation(
        // With no recovery to offer, the title must not read as a button. "Retry" over a failure that
        // cannot be retried is the whole defect this branch fixes.
        titleVariants: recovery == nil ? [] : (lastAction?.label).map { [$0] } ?? ["Retry"],
        subtitle: message, subtitleShort: message,
        symbol: "exclamationmark.triangle.fill",
        action: recovery,
        isEnabled: recovery != nil,
        // The tooltip is where a failure gets room to explain itself — one line fits the 36pt bar, the
        // remedy usually doesn't.
        tone: .failure, help: explain(failure, now: now),
        accessibility: "\(lastAction?.label ?? "Action") failed. \(explain(failure, now: now))",
        lockPath: lockPath(of: failure))
    }

    // [10/11/12] In flight — one action at a time, so this can't collide with a second.
    if case .running(let action) = activity {
      let title: String
      let subtitle: String
      switch action {
      case .fetch: (title, subtitle) = ("Fetching…", "from \(state?.primaryRemote ?? "remote")")
      case .push: (title, subtitle) = ("Pushing…", "to \(state?.primaryRemote ?? "remote")")
      case .pull: (title, subtitle) = ("Pulling…", "from \(state?.primaryRemote ?? "remote")")
      case .abortRebase: (title, subtitle) = ("Aborting…", "rebase")
      }
      return VCSSyncPresentation(
        titleVariants: [title], subtitle: subtitle, subtitleShort: subtitle,
        symbol: nil, badge: badge(ahead: state?.tracking?.ahead),
        action: nil, isEnabled: false, help: "\(title) \(subtitle)",
        accessibility: "\(title) \(subtitle)")
    }

    // [14] The pull we ran landed conflicts.
    //
    // BELOW the in-flight tier, deliberately: a running action's progress outranks a previous action's
    // outcome. ABOVE the counts, equally deliberately — a conflicted pull leaves behind at 0, so the
    // count tiers would render "Push origin" and say nothing at all about the tree being conflicted,
    // which is both the more urgent fact and a prerequisite for that push making sense.
    //
    // Reached only by jj in practice: git's rebase stops on a conflict and exits non-zero, so a
    // conflicted git pull is already a `.rebaseInProgress` failure offering Abort. jj's rebase commits
    // the conflict and exits 0, which is why the outcome had to be read from working status at all.
    //
    // No action offered, for `.locked`'s reason: resolving conflicts is work in an editor, and a button
    // that can't do it is a promise broken on click.
    if pullConflicted {
      let remedy =
        "The rebase completed with conflicts. Resolve them in this workroom — the Changes list marks "
        + "each conflicted file."
      return VCSSyncPresentation(
        subtitle: "Pulled with conflicts", subtitleShort: "Conflicts",
        symbol: "exclamationmark.triangle.fill", action: nil, isEnabled: false,
        tone: .warning, help: remedy, accessibility: "Pulled with conflicts. \(remedy)")
    }

    // [1] Nothing selected.
    guard hasTarget else {
      return disabled("No workroom selected", symbol: nil)
    }
    // [2] Selected, but not a readable repo.
    guard let state else {
      return disabled("No repository", symbol: "exclamationmark.triangle", tone: .warning)
    }
    // [0] The tools can't run these commands. Nothing below this line could succeed.
    guard toolsUsable else {
      return disabled(
        "Update git to use this", symbol: "exclamationmark.triangle", tone: .warning,
        help:
          "Fetch, push and pull need a newer git or jj. See the warning for the required version.")
    }
    // [3] No remote at all.
    guard let remote = state.primaryRemote else {
      return disabled("No remote configured", symbol: nil)
    }

    let fetched = fetchedAgo(state.lastFetch, now: now)
    let fetchedShort = fetchedAgo(state.lastFetch, now: now, short: true)
    let tracking = state.tracking

    // [4] No counterpart on the remote yet. This is the DEFAULT state of a fresh workroom —
    // `git worktree add -b` sets no upstream — so it must not read as "Push origin" against something
    // that doesn't exist.
    if let tracking, tracking.gone {
      let branch = state.current.name ?? "this branch"
      let detail = "\(branch) isn’t on \(remote) yet"
      return VCSSyncPresentation(
        titleVariants: ["Publish branch", "Publish"],
        subtitle: detail, subtitleShort: detail, symbol: "arrow.up.circle",
        badge: badge(ahead: tracking.ahead), action: .push, isEnabled: true,
        help: "Push \(branch) to \(remote) and start tracking it.",
        accessibility: "Publish branch. \(detail)")
    }

    let ahead = tracking?.ahead ?? 0
    let behind = tracking?.behind ?? 0
    let pullTitles =
      pullRebase
      ? ["Pull \(remote) with rebase", "Pull with rebase", "Pull"]
      : ["Pull \(remote)", "Pull"]

    // [9] Diverged ⇒ Pull, not Push: git refuses a non-fast-forward push, so offering Push here would
    // send the user straight into a rejection. Badges show both, ↓ first — the one the action addresses.
    if ahead > 0, behind > 0 {
      return VCSSyncPresentation(
        titleVariants: pullTitles, subtitle: fetched, subtitleShort: fetchedShort,
        symbol: "arrow.up.arrow.down",
        badge: .init(count: behind, direction: .behind),
        secondaryBadge: .init(count: ahead, direction: .ahead),
        action: .pull, isEnabled: true,
        help:
          "\(ahead) to push, \(behind) to pull. Pull first — \(remote) will reject a non-fast-forward push.",
        accessibility: "Pull \(remote) with rebase",
        accessibilityValue: "\(behind) behind, \(ahead) ahead")
    }
    // [8] Behind only.
    if behind > 0 {
      return VCSSyncPresentation(
        titleVariants: pullTitles, subtitle: fetched, subtitleShort: fetchedShort,
        symbol: "arrow.down", badge: .init(count: behind, direction: .behind),
        action: .pull, isEnabled: true,
        help: "\(behind) commit\(behind == 1 ? "" : "s") to pull from \(remote). \(fetched).",
        accessibility: "Pull \(remote) with rebase", accessibilityValue: "\(behind) behind")
    }
    // [7] Ahead only.
    if ahead > 0 {
      return VCSSyncPresentation(
        titleVariants: ["Push \(remote)", "Push"], subtitle: fetched, subtitleShort: fetchedShort,
        symbol: "arrow.up", badge: .init(count: ahead, direction: .ahead),
        action: .push, isEnabled: true,
        help: "\(ahead) commit\(ahead == 1 ? "" : "s") to push to \(remote). \(fetched).",
        accessibility: "Push \(remote)", accessibilityValue: "\(ahead) ahead")
    }
    // [5]/[6] In sync — the segment becomes a Fetch button.
    return VCSSyncPresentation(
      subtitle: fetched, subtitleShort: fetchedShort, symbol: nil,
      action: .fetch, isEnabled: true,
      help: "Up to date with \(remote). \(fetched). Click to fetch again.",
      accessibility: "Fetch \(remote). \(fetched)")
  }

  private static func disabled(
    _ subtitle: String, symbol: String?, tone: VCSSyncPresentation.Tone = .normal,
    help: String? = nil
  ) -> VCSSyncPresentation {
    VCSSyncPresentation(
      subtitle: subtitle, subtitleShort: subtitle, symbol: symbol, action: nil, isEnabled: false,
      tone: tone, help: help ?? subtitle, accessibility: subtitle)
  }

  private static func badge(ahead: Int?) -> VCSSyncPresentation.Badge? {
    guard let ahead, ahead > 0 else { return nil }
    return VCSSyncPresentation.Badge(count: ahead, direction: .ahead)
  }

  /// Which action a failure offers. `.rebaseInProgress` deliberately offers **Abort**, never a retry —
  /// a retry fails identically until the rebase is cleared. `.toolMissing` offers nothing, because no
  /// click can fix a missing binary.
  static func retryAction(for failure: VCSRemoteFailure, lastAction: VCSRemoteAction?)
    -> VCSRemoteAction?
  {
    switch failure {
    case .rebaseInProgress: return .abortRebase
    case .rejected: return .pull  // the fix for a rejection is to pull, never to force
    case .toolMissing, .noRemote: return nil
    // A LOCATED lock file offers nothing, for `rebaseInProgress`'s reason: the file is sitting there, so
    // every retry fails identically and the button is a promise that can't be kept. Removing it is the
    // only fix and Workroom won't do that for you (see `VCSRemoteFailure.locked`), so the recovery is
    // explained rather than offered. An unlocatable lock was transient contention — retry away.
    case .locked(let file): return file == nil ? lastAction : nil
    default: return lastAction
    }
  }

  /// Whether the pull **we** ran has conflicts still outstanding — the `[14]` tier's condition.
  ///
  /// Both halves are load-bearing. `lastPullConflicted` says the conflicts came from Workroom's own
  /// pull: a workroom can be conflicted from a merge the user ran in a terminal, and attributing that to
  /// the Pull button would be a lie. The live status says they are still there: the flag is cleared only
  /// by a new action or a workroom switch, so on its own the message would outlive the conflicts and go
  /// on calling a resolved tree broken.
  static func pullConflicted(lastPullConflicted: Bool, statusConflicted: Bool) -> Bool {
    lastPullConflicted && statusConflicted
  }

  /// One-line, actionable copy per failure. The raw stderr is legible for some cases and baffling for
  /// others, so the baffling ones get written copy.
  static func describe(_ failure: VCSRemoteFailure) -> String {
    switch failure {
    case .toolMissing(let tool):
      return "\(tool) isn’t on Workroom’s PATH."
    case .timedOut(let action):
      return "\(action.label) timed out."
    case .authRequired:
      // The #1 expected failure. The runner sets GIT_TERMINAL_PROMPT=0 and ssh BatchMode, so this
      // fails instantly rather than hanging — but the raw stderr is baffling, hence bespoke copy.
      return "Couldn’t authenticate. Load your key into ssh-agent, or set a credential helper."
    case .hostKeyUnverified:
      return "The host’s key isn’t known. Connect once from a terminal to accept it."
    case .noRemote:
      return "No remote configured."
    case .rejected:
      return "Rejected — the remote has commits you don’t. Pull first."
    case .dirtyWorkingTree:
      return "Uncommitted changes are in the way. Commit or stash them first."
    case .rebaseInProgress:
      return "A rebase is in progress. Abort it to continue."
    case .locked(let file):
      // Two different facts, so two different sentences. Saying "busy, try again" over a lock file that
      // is still there sends the user round a loop that cannot terminate.
      guard let file else { return "The repository was busy. Try again." }
      return "A leftover \(file.filename) is blocking git."
    case .other(let message):
      return message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Failed."
    }
  }

  /// The blocking lock file's path, when the failure has one.
  static func lockPath(of failure: VCSRemoteFailure) -> String? {
    guard case .locked(let file) = failure else { return nil }
    return file?.path
  }

  /// The tooltip form of a failure: `describe`'s one-liner plus, where there is one, the remedy.
  ///
  /// Only `.locked` currently says more than its subtitle, because it's the only failure whose fix is a
  /// thing the user must do OUTSIDE Workroom — and the app deliberately won't do it for them, so the
  /// message has to be complete enough to act on: which file, how old, and the caveat that makes the age
  /// worth printing. A minutes-old lock with no git running is abandoned; a seconds-old one probably
  /// isn't, and that judgement is the user's to make.
  static func explain(_ failure: VCSRemoteFailure, now: Date) -> String {
    guard case .locked(let file) = failure, let file else { return describe(failure) }
    let age = fullFormatter.localizedString(for: file.modifiedAt, relativeTo: now)
    return """
      A leftover lock file is blocking git.

      \(file.path)
      Created \(age).

      A git command that was force-stopped leaves this behind. If no git command is running for this \
      repository, deleting the file is safe:

      rm "\(file.path)"
      """
  }

  // MARK: Vocabulary

  /// What this backend calls the thing the working copy is on: jj says **bookmark**, git says **branch**.
  ///
  /// Not cosmetic. A jj bookmark does NOT advance as you commit, which is the defining behaviour of a git
  /// branch — so calling it a branch in a jj repo teaches the wrong model of the tool the user is running.
  ///
  /// A pure function rather than a ternary inside the view because that's the only way it can be tested:
  /// the toolbar's caption is not reachable from a unit test, and driving a real jj project through the
  /// GUI needs both a selected row and an open terminal.
  ///
  /// Anything that isn't `"jj"` — including an empty or unrecognised value — reads as "branch". `vcs` comes
  /// from the CLI config, so git is the safe default for an unknown, and it matches every non-jj repo the
  /// app can currently open.
  static func refNoun(vcs: String?) -> String { vcs == "jj" ? "bookmark" : "branch" }

  /// The branch segment's caption: "Current Branch" / "Current Bookmark".
  static func refCaption(vcs: String?) -> String { "Current \(refNoun(vcs: vcs).capitalized)" }

  // MARK: Relative time

  private static let fullFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()

  private static let shortFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  /// "Fetched 9 minutes ago" / "Fetched 9 min. ago" / "Never fetched" / "".
  ///
  /// Both forms say "Fetched", never "Last fetched": "ago" already places it in the past, so "Last" only
  /// spent width. `short` differs by the formatter's unit style alone.
  ///
  /// Under a minute reads "just now" rather than "in 0 seconds", which is what
  /// `RelativeDateTimeFormatter` produces for a sub-second delta.
  ///
  /// `.unknown` renders NOTHING — never the word "never". They are different facts: `.never` means we
  /// looked and there was no fetch; `.unknown` means we couldn't tell.
  static func fetchedAgo(_ lastFetch: VCSLastFetch, now: Date, short: Bool = false) -> String {
    switch lastFetch {
    case .never: return "Never fetched"
    case .unknown: return ""
    case .at(let date):
      if now.timeIntervalSince(date) < 60 { return "Fetched just now" }
      let formatter = short ? shortFormatter : fullFormatter
      return "Fetched \(formatter.localizedString(for: date, relativeTo: now))"
    }
  }
}
