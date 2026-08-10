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
  /// True on the read-failure tier, where the cell re-runs the READ rather than performing an action.
  /// Distinguished by a flag rather than by an `action`, because re-reading is not a `VCSRemoteAction` —
  /// nothing is written, nothing is gated, and no confirmation applies.
  var retriesRead: Bool = false

  struct Badge: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case ahead, behind }
    let count: Int
    let direction: Direction
  }

  enum Tone: Equatable, Sendable { case normal, warning, failure }

  var title: String? { titleVariants.first }
  var isSingleLine: Bool { titleVariants.isEmpty }
}

/// Everything the failure dialog renders, resolved from one failure.
///
/// The toolbar segment is **one truncating line** — it has to be, it's a 114pt cell — so it can only ever
/// be a notice that something failed. Anything longer than "Describe the change bef…" was unreadable, and
/// the tooltip that held the rest is a hover away and can't be copied, clicked or kept open while you fix
/// the problem. This is where the whole message lives instead.
struct VCSFailureDialog: Equatable, Sendable {
  /// Names the action, so the dialog says what failed without the bar for context.
  var title: String
  /// Names the workroom, for a failure that arrived after the selection moved on. Nil — the common case
  /// — when the failure belongs to what's on screen and the title alone is unambiguous.
  var subtitle: String?
  /// The full explanation: what happened, then how to fix it. Multi-paragraph, never truncated.
  var message: String
  /// The tool's own output, when there is any. Kept apart from `message` because it's evidence, not
  /// instruction — and for `.other` it is the ONLY complete account, since the segment's copy is that
  /// output's first line.
  var details: String?
  /// The action to offer as the dialog's default button, from `retryAction` — so the dialog can't offer a
  /// retry the toolbar has already decided is doomed.
  var recovery: VCSRemoteAction?
  var lockPath: String?
}

/// Maps a `VCSRemoteState` to what the sync segment shows.
///
/// ```
///   failure?  ──yes──►  [13] retry the previous action          tone: failure
///      │no
///   read failed? ──yes──►  [13c] re-read running? "Trying again…"      disabled, spinner
///                          [13b] recoverable by an ACTION? offer it
///                                else retryable? "Try Again" + the cause  tone: failure
///                                else            the cause alone          disabled
///      │no
///   in flight? ──yes──►  [10/11/12] Fetching…/Pushing…/Pulling…      disabled
///      │no
///   pullConflicted? ──yes──►  [14] "Pulled with conflicts"    disabled, tone: warning
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
  ///   - pullConflicted: our own pull left conflicts that are still unresolved. Compute it with
  ///     `pullConflicted(lastPullConflicted:statusConflicted:)` — both halves are load-bearing.
  ///   - busyElsewhere: an action is running for a DIFFERENT workroom. `RemoteStateModel.inFlight` is a
  ///     model-wide lock, so `perform` drops the click — but `activity` here is per-target, so without
  ///     this the segment rendered an enabled button, hover well and all, whose click did nothing at all.
  ///     Worse through the confirmation path: the dialog appeared, the user confirmed, and the action was
  ///     silently discarded. A 300s pull in one workroom made every other workroom's button a no-op.
  static func make(
    state: VCSRemoteState?, hasTarget: Bool, toolsUsable: Bool = true,
    activity: VCSSyncActivity = .idle, failure: VCSRemoteFailure? = nil,
    readFailure: VCSRemoteFailure? = nil, reading: Bool = false,
    lastAction: VCSRemoteAction? = nil, pullRebase: Bool = true, pullConflicted: Bool = false,
    busyElsewhere: Bool = false, now: Date
  ) -> VCSSyncPresentation {
    var resolved = resolve(
      state: state, hasTarget: hasTarget, toolsUsable: toolsUsable, activity: activity,
      failure: failure, readFailure: readFailure, reading: reading, lastAction: lastAction,
      pullRebase: pullRebase, pullConflicted: pullConflicted, now: now)
    // Applied AFTER the ladder rather than threaded through every enabled tier: it changes only whether
    // the thing can be clicked, never what it says. The copy still reports the real state, so the user
    // isn't told a lie — the button simply isn't live while the engine is busy for someone else.
    if busyElsewhere, resolved.action != nil {
      resolved.action = nil
      resolved.isEnabled = false
    }
    return resolved
  }

  private static func resolve(
    state: VCSRemoteState?, hasTarget: Bool, toolsUsable: Bool,
    activity: VCSSyncActivity, failure: VCSRemoteFailure?, readFailure: VCSRemoteFailure?,
    reading: Bool, lastAction: VCSRemoteAction?, pullRebase: Bool, pullConflicted: Bool,
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
        //
        // The title names the RECOVERY, not the action that failed. It used to read `lastAction?.label`
        // while `action:` below was `recovery` — so a rejected push rendered a button labelled "Push"
        // that performed a Pull. The two must be the same verb or the button lies about what it does.
        titleVariants: recovery.map { [$0.label] } ?? [],
        subtitle: message, subtitleShort: message,
        symbol: "exclamationmark.triangle.fill",
        action: recovery,
        isEnabled: recovery != nil,
        // The tooltip is where a failure gets room to explain itself — one line fits the bar, the
        // remedy usually doesn't.
        tone: .failure, help: explain(failure, now: now),
        accessibility: "\(lastAction?.label ?? "Action") failed. \(explain(failure, now: now))",
        lockPath: lockPath(of: failure))
    }

    // [13b] The READ failed. Below an action failure (that one is about something the user did) but above
    // everything else, for the same reason: without this tier a read blocked by `packed-refs.lock` nil'd
    // the snapshot and fell all the way to [2] "No repository" — a wrong diagnosis, offering neither the
    // cause nor a way to try again, for a repo that is perfectly fine.
    if let readFailure, case .idle = activity {
      let message = describe(readFailure)
      // [13c] The re-read the user asked for is running. Same shape as the action in-flight tiers, and for
      // the same reason: a click that changes nothing on screen reads as a dead control, and on a
      // persistent failure the retry would otherwise repaint the identical words.
      if reading {
        return VCSSyncPresentation(
          titleVariants: ["Trying again…"],
          subtitle: message, subtitleShort: message,
          // Nil so the segment renders its `ProgressView` in the glyph slot rather than the warning
          // triangle — the layout is identical, only the spinner says "working".
          symbol: nil,
          action: nil, isEnabled: false,
          tone: .failure, help: "Reading the repository again…",
          accessibility: "Trying again. \(message)")
      }
      // A read failure can have a concrete ACTION recovery (a rebase left behind, a rejection), and that
      // outranks re-reading: the read will fail identically until the action is taken. `lastAction` is nil
      // because nothing was attempted, so this asks purely "what does this failure need?".
      let recovery = retryAction(for: readFailure, lastAction: nil)
      // Otherwise: is re-running the READ worth offering at all? Same rule `retryAction` applies to
      // actions — a leftover lock file, a missing tool and an unconfigured remote all fail identically on
      // the next read, and a button that can't keep its promise is the defect tier [13] exists to prevent.
      let retryable = recovery == nil && readRetryIsWorthwhile(readFailure)
      return VCSSyncPresentation(
        // Deliberately not `lastAction`-labelled: nothing was attempted. When re-reading is the only thing
        // that can help, the title names that; when nothing can, the tier is a message, not a button.
        titleVariants: recovery.map { [$0.label] } ?? (retryable ? ["Try Again"] : []),
        subtitle: message, subtitleShort: message,
        symbol: "exclamationmark.triangle.fill",
        action: recovery,
        isEnabled: recovery != nil || retryable,
        tone: .failure,
        // Names the affordance as well as the cause: `explain` alone repeats the subtitle for every
        // failure but a located lock, so hovering would add nothing.
        help: retryable
          ? "\(explain(readFailure, now: now))\n\nClick to read the repository again."
          : explain(readFailure, now: now),
        // Leads with what the control DOES. VoiceOver gets no visual text, so a label that only recites
        // the cause never says this is a retry — and for a located lock `explain` is several paragraphs.
        accessibility: retryable
          ? "Try again. Reading the repository failed. \(message)"
          : "Reading the repository failed. \(message)",
        lockPath: lockPath(of: readFailure),
        retriesRead: retryable)
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
        "Update git or jj to use this", symbol: "exclamationmark.triangle", tone: .warning,
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
  /// **Exhaustive on purpose — no `default:`.** It used to end `default: return lastAction`, so every
  /// failure added later silently inherited "offer a retry", which is the exact defect the `[13]` tier
  /// exists to prevent. Two of the failures below were added precisely because they are permanent, and a
  /// `default:` would have handed them a doomed button without a compile error.
  static func retryAction(for failure: VCSRemoteFailure, lastAction: VCSRemoteAction?)
    -> VCSRemoteAction?
  {
    switch failure {
    case .rebaseInProgress: return .abortRebase
    case .rejected: return .pull  // the fix for a rejection is to pull, never to force
    case .toolMissing, .noRemote: return nil
    // Permanent until the user does something outside Workroom: describe the commit, or move off a base
    // whose history is protected. Retrying either runs the identical command and fails identically.
    case .needsDescription, .immutableHistory: return nil
    // The workroom's folder is gone. Retrying spawns the identical command against the identical
    // missing path — there is no "later" where this changes, unlike ordinary contention.
    case .launchFailed: return nil
    case .timedOut, .authRequired, .hostKeyUnverified, .dirtyWorkingTree, .other:
      return lastAction
    // A LOCATED lock file offers nothing, for `rebaseInProgress`'s reason: the file is sitting there, so
    // every retry fails identically and the button is a promise that can't be kept. Removing it is the
    // only fix and Workroom won't do that for you (see `VCSRemoteFailure.locked`), so the recovery is
    // explained rather than offered. An unlocatable lock was transient contention — retry away.
    case .locked(let file): return file == nil ? lastAction : nil
    }
  }

  /// Whether re-running the READ could plausibly succeed — the read-side counterpart of `retryAction`,
  /// and gated for the same reason: an offer that fails identically every time is worse than no offer.
  ///
  /// Only consulted when the failure has no ACTION recovery. Exhaustive with no `default:`, so a new
  /// `VCSRemoteFailure` case has to be classified here rather than inheriting a doomed retry.
  static func readRetryIsWorthwhile(_ failure: VCSRemoteFailure) -> Bool {
    switch failure {
    // Transient or environmental: a slow network, an agent that can be loaded, a tree that can be
    // cleaned, an unclassified error whose cause may well be gone by the next read.
    case .timedOut, .authRequired, .hostKeyUnverified, .dirtyWorkingTree, .other: return true
    // A LOCATED lock is sitting on disk — nothing changes until the user removes it. An unlocatable one
    // had already cleared, which is ordinary contention.
    case .locked(let file): return file == nil
    // Permanent until the user acts outside Workroom: install the tool, add a remote, describe the
    // commit, move off protected history.
    case .toolMissing, .noRemote, .needsDescription, .immutableHistory: return false
    // The workroom's folder is gone — re-reading the same missing path can't succeed.
    case .launchFailed: return false
    // Both carry an ACTION recovery, so this is only reached if that path is ever changed — and neither
    // is fixed by re-reading.
    case .rejected, .rebaseInProgress: return false
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
    case .launchFailed:
      return "This workroom’s folder is no longer there."
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
    case .needsDescription:
      // The most reachable failure on the push path: this is every workroom between the first edit and
      // the first commit message. The remedy is one command, so name it.
      return "Describe the change before pushing it (jj describe)."
    case .immutableHistory:
      return "Pull would rewrite shared history here, so it can’t run."
    case .other(let message):
      return message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Failed."
    }
  }

  /// The dialog form of a failure: the one-liner, the remedy, the tool's own output, and the recovery.
  ///
  /// `action` is what was attempted (`RemoteStateModel.lastAction`), which is what lets the title name it.
  /// `isRead: true` says nothing was attempted — the failure came from READING the repo — so the title
  /// must not invent an action. Without it a read failure's dialog opened saying "The last action failed"
  /// over a repo where no action had run, contradicting the tier that raised it.
  static func failureDialog(
    _ failure: VCSRemoteFailure, action: VCSRemoteAction?, workroom: String? = nil,
    isRead: Bool = false, now: Date
  ) -> VCSFailureDialog {
    // A located lock's `explain` is already the complete account — path, age, remedy and the caveat that
    // makes the remedy safe advice — so it is used whole rather than re-assembled and half-repeated.
    let message: String
    if case .locked(let file) = failure, file != nil {
      message = explain(failure, now: now)
    } else {
      message = [describe(failure), remedy(for: failure)].compactMap { $0 }.joined(
        separator: "\n\n")
    }
    return VCSFailureDialog(
      title: isRead
        ? "Couldn’t read the repository" : "\(action?.label ?? "The last action") failed",
      subtitle: workroom.map { "in \($0)" },
      message: message,
      details: rawOutput(of: failure),
      recovery: retryAction(for: failure, lastAction: action),
      lockPath: lockPath(of: failure))
  }

  /// How to fix it, in the dialog's own voice. Nil where `describe` already IS the remedy, or where the
  /// tool's output says it better than we can.
  ///
  /// Deliberately not merged into `describe`: that one is the toolbar's single line and has to stay one.
  static func remedy(for failure: VCSRemoteFailure) -> String? {
    switch failure {
    case .toolMissing(let tool):
      return """
        Install \(tool), or add it to your PATH. Workroom takes its PATH from your login shell at \
        launch, so a terminal that can find \(tool) is not proof that the app can — relaunch Workroom \
        after changing your shell profile.
        """
    case .timedOut(let action):
      return """
        \(action.label) was stopped at its time limit. Check the network or VPN and try again — a first \
        fetch of a large repository can legitimately need longer than the limit allows.
        """
    case .authRequired:
      return """
        For an SSH remote, load your key into the agent: ssh-add ~/.ssh/id_ed25519
        For an HTTPS remote, configure a credential helper.

        Workroom runs git and jj non-interactively, so they can never prompt you for a passphrase — \
        they fail immediately instead of hanging.
        """
    case .hostKeyUnverified:
      return """
        Run the same command once from a terminal and accept the fingerprint. That records the host in \
        ~/.ssh/known_hosts, and Workroom can connect from then on.
        """
    case .noRemote:
      return """
        Add one from a terminal, then fetch:

        git remote add origin <url>
        jj git remote add origin <url>
        """
    case .rejected:
      return """
        Pull to bring the remote's commits in, then push again. Workroom never force-pushes — that \
        would discard whatever is on the remote that you don't have.
        """
    case .dirtyWorkingTree:
      return "Commit or stash the files named below, then try again."
    case .rebaseInProgress:
      return "Abort the rebase to put the repository back in a clean state, then pull again."
    case .immutableHistory:
      return """
        Pull rebases the whole branch containing @ onto trunk(), and a commit in it is protected by \
        immutable_heads(). Rebase onto this workroom's own base from a terminal instead.
        """
    case .needsDescription:
      return """
        Give the change a message first, then push again:

        jj describe -m "…"
        """
    case .launchFailed:
      return """
        The workroom may have been deleted, or its folder moved or removed outside Workroom. \
        Refresh the sidebar, or recreate the workroom if it's genuinely gone.
        """
    // `.locked` is answered by `explain` in full; `.other` is raw tool output we have no advice for.
    case .locked, .other:
      return nil
    }
  }

  /// The tool's own output, for the dialog's Details section. Nil for the failures Workroom raises
  /// itself, which have no output to show.
  static func rawOutput(of failure: VCSRemoteFailure) -> String? {
    let raw: String?
    switch failure {
    case .authRequired(let m), .hostKeyUnverified(let m), .rejected(let m),
      .dirtyWorkingTree(let m),
      .immutableHistory(let m), .needsDescription(let m), .other(let m):
      raw = m
    case .toolMissing, .timedOut, .noRemote, .rebaseInProgress, .locked, .launchFailed:
      raw = nil
    }
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
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

  // MARK: Commit failures

  /// The dialog form of a commit failure, reusing `VCSFailureDialog` so the commit sheet and the
  /// toolbar's failure sheet say things the same way.
  ///
  /// `recovery` is always nil: every `VCSRemoteAction` is a *remote* verb, and none of them fixes a
  /// commit. The commit sheet offers its own recovery (edit and press Commit again, or hand off to
  /// the terminal), which is the same reasoning `retryAction` applies to `.locked` — never offer a
  /// button that would fail identically.
  static func commitFailureDialog(_ failure: VCSCommitFailure, mode: VCSCommitMode)
    -> VCSFailureDialog
  {
    VCSFailureDialog(
      title: "\(commitVerb(mode)) failed",
      message: [describeCommit(failure), commitRemedy(for: failure)].compactMap { $0 }
        .joined(separator: "\n\n"),
      details: commitRawOutput(of: failure),
      recovery: nil,
      lockPath: {
        guard case .locked(let file) = failure else { return nil }
        return file?.path
      }())
  }

  static func commitVerb(_ mode: VCSCommitMode) -> String {
    switch mode {
    case .commit: return "Commit"
    case .amendMessage: return "Amend"
    case .describe: return "Set message"
    }
  }

  /// One actionable line per failure. Same contract as `describe`: the baffling ones get written
  /// copy, the self-explanatory ones carry the tool's own words.
  static func describeCommit(_ failure: VCSCommitFailure) -> String {
    switch failure {
    case .toolMissing(let tool): return "\(tool) isn’t on Workroom’s PATH."
    case .launchFailed: return "This workroom’s folder is no longer there."
    case .timedOut: return "The commit was stopped at its time limit."
    case .nothingToCommit: return "Nothing to commit."
    case .identityMissing: return "git doesn’t know who you are yet."
    case .signingFailed: return "Signing the commit failed."
    case .hookRejected: return "A commit hook rejected this commit."
    case .unmergedFiles: return "Some files still have unresolved conflicts."
    case .sequencerInProgress(let what): return "A \(what) is in progress in this workroom."
    case .locked(let file):
      guard let file else { return "The repository was busy. Try again." }
      return "A leftover \(file.filename) is blocking git."
    case .unsupportedMode: return "That action isn’t available for this repository."
    case .other(let message):
      return message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Commit failed."
    }
  }

  /// How to fix it. Nil where the tool's own output already says it better.
  static func commitRemedy(for failure: VCSCommitFailure) -> String? {
    switch failure {
    case .toolMissing(let tool):
      return """
        Install \(tool), or add it to your PATH. Workroom takes its PATH from your login shell at \
        launch, so a terminal that can find \(tool) is not proof that the app can — relaunch \
        Workroom after changing your shell profile.
        """
    case .timedOut:
      return """
        A pre-commit hook that runs a linter or a test suite can legitimately take this long. Run \
        the commit in the terminal to watch it, or shorten the hook.
        """
    case .nothingToCommit:
      return "Select at least one file with changes, then commit again."
    case .identityMissing:
      return """
        Set your name and email, then commit again:

        git config --global user.name "Your Name"
        git config --global user.email "you@example.com"
        """
    case .signingFailed:
      return """
        Workroom runs git without a terminal, so gpg can never prompt you for a passphrase — it \
        fails immediately instead of hanging. Unlock your key in the agent first, or run this \
        commit in the terminal.
        """
    case .hookRejected:
      return """
        The hook’s own output is below. Fix what it reports and commit again, or run the commit in \
        the terminal to work through it interactively.
        """
    case .unmergedFiles:
      return "Resolve the conflicts first — the Changes list marks each conflicted file."
    case .sequencerInProgress(let what):
      return """
        Finish or abort the \(what) in the terminal first. Committing part of a \(what) from here \
        would leave the repository half-way through it.
        """
    case .locked(let file):
      guard let file else { return nil }
      return """
        A git command that was force-stopped leaves this behind:

        \(file.path)

        If no git command is running for this repository, deleting the file is safe.
        """
    case .launchFailed:
      return """
        The workroom may have been deleted, or its folder moved or removed outside Workroom. \
        Refresh the sidebar, or recreate the workroom if it's genuinely gone.
        """
    case .unsupportedMode, .other:
      return nil
    }
  }

  /// The tool's own output, for the Details section. Nil for failures Workroom raises itself.
  static func commitRawOutput(of failure: VCSCommitFailure) -> String? {
    let raw: String?
    switch failure {
    case .identityMissing(let m), .signingFailed(let m), .hookRejected(let m),
      .unmergedFiles(let m), .other(let m):
      raw = m
    case .toolMissing, .launchFailed, .timedOut, .nothingToCommit, .sequencerInProgress, .locked,
      .unsupportedMode:
      raw = nil
    }
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
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
