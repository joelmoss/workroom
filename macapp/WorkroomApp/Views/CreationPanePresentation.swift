import Foundation
import WorkroomDomain

/// What the creation pane (#483) says about its run, kept apart from the drawing so it can be
/// tested: the timing column, captions, the header, the failure footer, each row's VoiceOver label,
/// the three announcements, keyboard routing and when an open log follows new output.
enum CreationPanePresentation {
  // MARK: Timing column

  /// A step's duration (design D19): "<1s" for a finished step under a second, whole seconds under a
  /// minute, then "1m 12s". A running step ticks from "0s".
  static func duration(_ seconds: TimeInterval, finished: Bool) -> String {
    if finished, seconds < 1 { return "<1s" }
    let whole = Int(seconds)
    return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
  }

  /// The right-aligned column of a row: its live or final duration, "Skipped", "Waiting for you", or
  /// nothing for a step that hasn't started.
  static func trailing(for step: CreationStep, now: Date) -> String? {
    switch step.state {
    case .pending: return nil
    case .waitingForUser: return "Waiting for you"
    case .skipped: return "Skipped"
    case .running:
      return step.startedAt.map { duration(now.timeIntervalSince($0), finished: false) }
    case .done, .warning, .failed:
      return step.duration.map { duration($0, finished: true) }
    }
  }

  // MARK: Logs

  /// A step's log as its open row shows it: from its first line with something on it (owner).
  static func log(of step: CreationStep) -> ArraySlice<String> {
    step.log.drop { $0.allSatisfy(\.isWhitespace) }
  }

  /// Whether a row opens a log (owner): only a step that has started and has output. A pending, a
  /// skipped or a silent step has nothing to show.
  static func isExpandable(_ step: CreationStep) -> Bool {
    switch step.state {
    case .pending, .skipped: false
    default: !log(of: step).isEmpty
    }
  }

  // MARK: Captions and header

  /// A row's second line (design D11): a skipped step's reason, or a warning's text. Steps skipped
  /// implicitly have none.
  static func caption(for step: CreationStep) -> String? {
    switch step.state {
    case .skipped(let reason?) where !reason.isEmpty: reason
    case .warning(let text) where !text.isEmpty: text
    default: nil
    }
  }

  /// The header's first line (design D5): "Creating workroom…", then "Creating workroom <name>…"
  /// once the name lands. Once the create has ended it stops saying so: the name, or "New
  /// workroom" for one that failed before it had one.
  @MainActor static func title(of run: CreationRun) -> String {
    guard run.isRunning else { return run.name ?? "New workroom" }
    return run.name.map { "Creating workroom \($0)…" } ?? "Creating workroom…"
  }

  /// The header's second line: "<project> · <destination>", also the provisional row's destination.
  @MainActor static func subtitle(of run: CreationRun) -> String {
    "\(run.project.displayName) · \(run.kind.destination)"
  }

  // MARK: Accessibility

  /// A row's VoiceOver label: "<title>, <state>", plus its final duration once it has finished. A
  /// running row's label never carries the ticking time, which would re-read every second.
  static func accessibilityLabel(for step: CreationStep) -> String {
    let state =
      switch step.state {
      case .pending: "not started"
      case .running: "running"
      case .waitingForUser: "waiting for you"
      case .done: "done"
      case .warning: "done with a warning"
      case .failed: "failed"
      case .skipped: "skipped"
      }
    var parts = [step.title, state]
    if let seconds = step.duration { parts.append(spokenDuration(seconds)) }
    return parts.joined(separator: ", ")
  }

  private static func spokenDuration(_ seconds: TimeInterval) -> String {
    guard seconds >= 1 else { return "under a second" }
    let whole = Int(seconds)
    func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
    guard whole >= 60 else { return unit(whole, "second") }
    return unit(whole / 60, "minute") + " " + unit(whole % 60, "second")
  }

  /// D17: the provider's setup sheet needs the user.
  static func setupAnnouncement(for place: RemoteWorkrooms.Place) -> String {
    "\(place.displayName) needs setting up"
  }

  /// D17: a create failed, naming the step that did.
  @MainActor static func failureAnnouncement(for run: CreationRun) -> String {
    let what = "Couldn't create \(run.name ?? "the workroom")"
    guard let step = run.steps.first(where: { $0.state == .failed }) else { return what }
    return "\(what): \(step.title) failed"
  }

  /// D17: a create finished and its workroom is ready.
  static func successAnnouncement(name: String) -> String { "\(name) is ready" }

  // MARK: Failure footer

  /// A failure footer's button.
  enum Action: Equatable {
    case tryAgain, close, openAnyway, deleteWorkroom
    /// Opens the setup script's approval sheet again (#363), where it is read and approved or
    /// skipped.
    case reviewScript
    /// Asks again where a create that found local work starts.
    case chooseStart
    /// Starts a container create again on the default image, without its devcontainer.json.
    case defaultImage
    /// Close, worded for a create that made nothing and is waiting on the user: the whole create
    /// goes, not only the script.
    case cancel

    var title: String {
      switch self {
      case .tryAgain: "Try Again"
      case .close: "Close"
      case .openAnyway: "Open Anyway"
      // An ellipsis: it opens the delete confirmation rather than deleting.
      case .deleteWorkroom: "Delete Workroom…"
      // An ellipsis: it opens a sheet.
      case .reviewScript: "Review Script…"
      case .chooseStart: "Choose…"
      case .defaultImage: "Continue With Default Image"
      case .cancel: "Cancel Creation"
      }
    }
  }

  /// The setup script approval sheet's message (#363): why the create stopped, for which project,
  /// and the ways on. Worded as the teardown's (`AppStore.teardownApprovalMessage`).
  @MainActor static func setupApprovalMessage(for run: CreationRun, script: ScriptTrust) -> String {
    if script.isDevContainer {
      return "Creating a workroom in \(run.project.displayName) uses \(script.displayFile) "
        + "\(script.originLabel), and it is new, or changed since it was approved on this Mac. It "
        + "decides what the container mounts from this Mac and what runs there. Read it, then "
        + "approve it to use it, or create the workroom on the default image."
    }
    return "Creating a workroom in \(run.project.displayName) runs \(script.displayFile) "
      + "\(script.originLabel), and it is new, or changed since it was approved on this Mac. Read "
      + "it, then approve it to run it, or create the workroom without running it."
  }

  /// Continue Without's confirmation for `script`: a setup script is skipped; a devcontainer.json
  /// gives way to the default image.
  static func skipConfirmation(for script: ScriptTrust) -> ErrorAction.Confirmation {
    if script.isDevContainer {
      return ErrorAction.Confirmation(
        title: "Create the workroom on the default image, without its dev container?",
        message:
          "The workroom is created on Workroom's default image, so nothing \(script.displayFile) "
          + "sets up is there. It stays unapproved, so you'll be asked again next time.",
        button: "Continue With Default Image")
    }
    return ErrorAction.Confirmation(
      title: "Create the workroom without running \(script.displayFile)?",
      message: "The workroom is created, but nothing the script would have set up is done. The "
        + "script stays unapproved, so you'll be asked again next time.",
      button: "Continue Without Script")
  }

  /// The failure footer (design D3, D12): the reason on the left, then the secondary and the default
  /// (`primary`) buttons.
  struct Footer: Equatable {
    let reason: String
    let primary: Action
    let secondary: Action
    /// What Escape answers: Close or Cancel, where it is shown (D16).
    var escapeAction: Action? { [.close, .cancel].contains(secondary) ? secondary : nil }
  }

  /// The row a failure's notice goes under: the step that failed, or the one waiting on the user (a
  /// script to approve). Nil when no step is either, and the notice follows the last row.
  static func noticeStep(in steps: [CreationStep]) -> String? {
    (steps.first { $0.state == .failed } ?? steps.first { $0.state == .waitingForUser })?.id
  }

  /// The footer a run's outcome shows, or nil while it runs or once it has ended well.
  static func footer(for outcome: CreationOutcome) -> Footer? {
    switch outcome {
    case .running, .succeeded, .cancelled:
      nil
    case .failedBeforeWorkroom(let message), .remoteFailed(let message, leftBehind: false):
      Footer(
        reason: "Couldn't create the workroom: \(message)", primary: .tryAgain, secondary: .close)
    case .setupScriptFailed(let message):
      // The CLI's message opens with its own "setup script failed: " (`errs.ErrSetup`): say it once.
      Footer(
        reason: "The setup script failed: \(message.trimmingPrefix("setup script failed: "))",
        primary: .openAnyway, secondary: .deleteWorkroom)
    case .hookFailed(let message):
      Footer(reason: message, primary: .openAnyway, secondary: .deleteWorkroom)
    case .remoteFailed(let message, leftBehind: true):
      Footer(
        reason: "Couldn't create the workroom, and its machine is still running: \(message)",
        primary: .deleteWorkroom, secondary: .close)
    case .scriptNotTrusted(let script):
      Footer(
        reason: "\(script.displayFile) \(script.originLabel) needs approving before the workroom "
          + "is made.",
        primary: .reviewScript, secondary: .cancel)
    case .localWorkFound(let work):
      Footer(
        reason: "\(work.summary). Choose whether the new workroom includes it.",
        primary: .chooseStart, secondary: .cancel)
    case .composeRefused(let file):
      Footer(
        reason: "\(file) describes Docker Compose services, and a container workroom runs one "
          + "container. It can be made from the default image instead.",
        primary: .defaultImage, secondary: .cancel)
    }
  }

  /// The choices a create that found local work offers, most first: the commits and the changes,
  /// the commits only, then neither. Only the ones that apply.
  static func startChoices(for work: LocalWork) -> [(start: CreationStart, title: String)] {
    var choices: [(CreationStart, String)] = []
    switch (work.ahead > 0, work.uncommitted) {
    case (true, true):
      choices = [
        (.localWithChanges, "Include My Commits and Changes"), (.local, "Include My Commits Only"),
      ]
    case (false, true): choices = [(.localWithChanges, "Include My Changes")]
    default: choices = [(.local, "Include My Commits")]
    }
    return choices + [(.origin, "Leave It Out")]
  }

  /// The start choice's message under its title (the work's summary).
  static func startChoiceMessage(for work: LocalWork) -> String {
    var lines = [
      "New workrooms start from what you've pushed, so this one won't have it unless you "
        + "include it."
    ]
    if !work.behindNote.isEmpty { lines.append(work.behindNote) }
    if work.uncommitted {
      lines.append("Your changes stay where they are too; the new workroom gets a copy.")
    }
    return lines.joined(separator: " ")
  }

  // MARK: Keyboard

  /// A key a focused row answers (D16).
  enum Key { case up, down, space, right, left }

  struct KeyResult: Equatable {
    let focused: String
    let expanded: String?
  }

  /// Up and Down move between rows, stopping at the ends; Space toggles the focused row's log, Right
  /// expands it and Left collapses it. One log is open at a time (D9), and a row outside
  /// `expandable` (`isExpandable`) has none to open.
  static func handle(
    _ key: Key, focused: String, expanded: String?, rows: [String], expandable: Set<String>
  ) -> KeyResult {
    let index = rows.firstIndex(of: focused) ?? 0
    let opens = expandable.contains(focused)
    switch key {
    case .up: return KeyResult(focused: rows[max(index - 1, 0)], expanded: expanded)
    case .down: return KeyResult(focused: rows[min(index + 1, rows.count - 1)], expanded: expanded)
    case .space:
      return KeyResult(
        focused: focused, expanded: expanded == focused ? nil : opens ? focused : expanded)
    case .right: return KeyResult(focused: focused, expanded: opens ? focused : expanded)
    case .left: return KeyResult(focused: focused, expanded: expanded == focused ? nil : expanded)
    }
  }

  // MARK: Open log layout

  /// How tall the open log is (design D9): as tall as its lines, with no blank space above them,
  /// and no taller than the pane's room left after everything else in the column (`fixed`: the
  /// header, every row and the log's padding), though never squeezed under `minimum` for it. The rows
  /// below follow straight on; only when a long log is at its minimum does the column outgrow the
  /// pane, and scroll.
  static func openLogHeight(
    pane: CGFloat, fixed: CGFloat, logContent: CGFloat, minimum: CGFloat
  ) -> CGFloat {
    // Whole points down, so rounding never leaves the column a fraction taller than the pane.
    let room = max((pane - fixed).rounded(.down), minimum)
    return min(logContent, room)
  }

  // MARK: Following new output

  /// Whether an open log is scrolled to its end, within a couple of points (D10): only then does it
  /// follow new lines. A log shorter than its frame always is.
  static func isAtBottom(offset: CGFloat, visible: CGFloat, content: CGFloat) -> Bool {
    offset + visible >= content - 2
  }
}
