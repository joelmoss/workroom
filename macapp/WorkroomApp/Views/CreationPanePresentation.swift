import Foundation

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

  /// The header's first line (design D5): "New workroom" until the name lands.
  @MainActor static func title(of run: CreationRun) -> String { run.name ?? "New workroom" }

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

    var title: String {
      switch self {
      case .tryAgain: "Try Again"
      case .close: "Close"
      case .openAnyway: "Open Anyway"
      case .deleteWorkroom: "Delete Workroom"
      }
    }
  }

  /// The failure footer (design D3, D12): the reason on the left, then the secondary and the default
  /// (`primary`) buttons.
  struct Footer: Equatable {
    let reason: String
    let primary: Action
    let secondary: Action
    /// What Escape answers: Close, where it is shown (D16).
    var escapeAction: Action? { secondary == .close ? .close : nil }
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
      Footer(
        reason: "The setup script failed: \(message)", primary: .openAnyway,
        secondary: .deleteWorkroom)
    case .remoteFailed(let message, leftBehind: true):
      Footer(
        reason: "Couldn't create the workroom, and its machine is still running: \(message)",
        primary: .deleteWorkroom, secondary: .close)
    }
  }

  // MARK: Keyboard

  /// A key a focused row answers (D16).
  enum Key { case up, down, space, right, left }

  struct KeyResult: Equatable {
    let focused: String
    let expanded: String?
  }

  /// Up and Down move between rows, stopping at the ends; Space toggles the focused row's log, Right
  /// expands it and Left collapses it. One log is open at a time (D9).
  static func handle(_ key: Key, focused: String, expanded: String?, rows: [String]) -> KeyResult {
    let index = rows.firstIndex(of: focused) ?? 0
    switch key {
    case .up: return KeyResult(focused: rows[max(index - 1, 0)], expanded: expanded)
    case .down: return KeyResult(focused: rows[min(index + 1, rows.count - 1)], expanded: expanded)
    case .space: return KeyResult(focused: focused, expanded: expanded == focused ? nil : focused)
    case .right: return KeyResult(focused: focused, expanded: focused)
    case .left: return KeyResult(focused: focused, expanded: expanded == focused ? nil : expanded)
    }
  }

  // MARK: Following new output

  /// Whether an open log is scrolled to its end, within a couple of points (D10): only then does it
  /// follow new lines. A log shorter than its frame always is.
  static func isAtBottom(offset: CGFloat, visible: CGFloat, content: CGFloat) -> Bool {
    offset + visible >= content - 2
  }
}
