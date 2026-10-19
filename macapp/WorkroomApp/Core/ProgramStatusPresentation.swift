import AgentConnection
import AppKit
import DesignSystem
import SwiftUI
import WorkroomVCS

/// What a pane's program status (#358) says: tooltips and VoiceOver, one wording everywhere. Pure,
/// so each string is pinned by `ProgramStatusPresentationTests`.
enum ProgramStatusPresentation {
  /// The accessibility action on every glyph button and on the rows that carry one.
  static let showWaitingAction = "Show the terminal that needs you"
  static let reportedBy = "Reported by the program in this terminal"
  static let reportedByShell = "Reported by the shell in this terminal"
  static let staleLine = "May be out of date: reconnecting…"
  static let stuckLine = "Stuck? Right-click, then Clear status."
  static let mayBeOutOfDate = "may be out of date"
  static let turnFinished = "Turn finished"
  /// A command result's headline (#473), in the shell's words; nil for a program's record.
  static func commandHeadline(_ record: ProgramStatusRecord) -> String? {
    guard let exitCode = record.exitCode else { return nil }
    return exitCode == 0 ? "Command finished" : "Command failed (exit \(exitCode))"
  }

  /// The program's message, kept to one tooltip line.
  static let messageLimit = 120

  static func sentence(_ kind: ProgramStatusKind) -> String {
    switch kind {
    case .permission: "Waiting for your permission"
    case .question: "Waiting for your answer"
    case .auth: "Waiting for you to sign in"
    case .none: "Waiting for your input"
    }
  }

  private static func word(_ kind: ProgramStatusKind) -> String {
    switch kind {
    case .permission: "permission"
    case .question: "question"
    case .auth: "sign-in"
    case .none: "input"
    }
  }

  /// Line 1 for a waiting pane: the kind sentence, or the count and kinds when several wait.
  static func headline(_ blocked: [ProgramStatusRecord]) -> String {
    guard blocked.count > 1 else { return sentence(blocked.first?.kind ?? .none) }
    var kinds: [String] = []
    for record in blocked where !kinds.contains(word(record.kind)) {
      kinds.append(word(record.kind))
    }
    return "\(blocked.count) requests waiting: \(kinds.joined(separator: ", "))"
  }

  /// `message` on one line, cut with an ellipsis at `messageLimit`; nil when empty.
  static func oneLine(_ message: String) -> String? {
    let line = message.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return nil }
    return line.count > messageLimit ? String(line.prefix(messageLimit - 1)) + "…" : line
  }

  /// The status lines a terminal's tooltip ends with, below its title. With nothing reported, one
  /// line says why, from the pane's host: `hostState` nil (not followed) or no session says nothing.
  static func tooltipLines(
    indicator: PaneIndicator, rollup: ProgramStatusRollup?,
    hostState: ProgramStatusMonitor.HostState?, hasSession: Bool, now: Date = Date()
  ) -> [String] {
    guard let rollup, rollup.hasReport else {
      guard hasSession, let hostState else { return [] }
      switch hostState {
      case .connecting: return ["Program status: connecting…"]
      case .live, .stale: return ["Program status: not reported"]
      case .unavailable: return ["Program status: unavailable on this host"]
      }
    }
    var lines: [String]
    var source = reportedBy
    switch indicator {
    case .blocked:
      lines = [headline(rollup.blocked)]
      if let message = rollup.blocked.first.flatMap({ oneLine($0.message) }) {
        lines.append(message)
      }
    case .done:
      lines = [turnFinished]
      if let message = rollup.done.flatMap({ oneLine($0.message) }) { lines.append(message) }
      if let headline = rollup.done.flatMap(commandHeadline) {
        lines[0] = headline
        source = reportedByShell
      }
    case .error where rollup.error != nil:
      lines = ["The program reported an error"]
      if let message = rollup.error.flatMap({ oneLine($0.message) }) { lines.append(message) }
      if let headline = rollup.error.flatMap(commandHeadline) {
        lines[0] = headline
        source = reportedByShell
      }
    default:
      return rollup.stale ? [staleLine] : []
    }
    lines.append(source)
    if rollup.stale { lines.append(staleLine) }
    // A stale mark can't be cleared until its host is back, so the hint waits for it.
    if indicator == .blocked, !rollup.stale, let since = rollup.blockedSince,
      now.timeIntervalSince(since) >= Double(ProgramStatusLimits.stuckHint.components.seconds)
    {
      lines.append(stuckLine)
    }
    return lines
  }

  /// `tooltipLines` for a terminal tab of `target`, its host's link read from `hosts`.
  static func tooltipLines(
    for tab: TerminalTab, of target: TerminalTarget,
    hosts: [HostID: ProgramStatusMonitor.HostState]
  ) -> [String] {
    guard case .terminal(let state) = tab.content else { return [] }
    return tooltipLines(
      indicator: tab.indicator, rollup: state.programStatus,
      hostState: hosts[target.remoteHost.map(HostID.remote) ?? .local],
      hasSession: state.sessionID != nil)
  }

  /// A terminal chip's VoiceOver value (run-command tabs keep their run state, read before this).
  /// Without a report this is the OSC 9;4 path's "Busy" / "Idle" / "Error", unchanged.
  static func accessibilityValue(indicator: PaneIndicator, rollup: ProgramStatusRollup?) -> String {
    switch indicator {
    case .blocked: sentence(rollup?.blocked.first?.kind ?? .none)
    case .done: rollup?.done.flatMap(commandHeadline) ?? turnFinished
    case .error: rollup?.error.flatMap(commandHeadline) ?? "Error"
    case .running(failed: true): "Error"
    case .running: "Busy"
    case .none: "Idle"
    }
  }

  /// What a parent element's VoiceOver label appends for a terminal: the waiting sentence or the
  /// finished turn, then "may be out of date" while the host's link is down.
  static func accessibilityParts(indicator: PaneIndicator, rollup: ProgramStatusRollup?)
    -> [String]
  {
    var parts: [String] = []
    switch indicator {
    case .blocked: parts.append(sentence(rollup?.blocked.first?.kind ?? .none).lowercased())
    case .done: parts.append((rollup?.done.flatMap(commandHeadline) ?? turnFinished).lowercased())
    default: break
    }
    if !parts.isEmpty, rollup?.stale == true { parts.append(mayBeOutOfDate) }
    return parts
  }

  /// A workroom row's glyph tooltip.
  static func waitingTooltip(count: Int) -> String {
    count == 1 ? "1 terminal waiting for you" : "\(count) terminals waiting for you"
  }

  /// A workroom row's glyph, spoken.
  static func waitingLabel(count: Int, stale: Bool) -> String {
    let label = count == 1 ? "1 terminal needs you" : "\(count) terminals need you"
    return stale ? "\(label), \(mayBeOutOfDate)" : label
  }
}

extension ProgramStatusRollup {
  /// Something is reported: a running program, or a record left. A cleared session keeps an empty
  /// rollup until its next event.
  var hasReport: Bool {
    reporting || working || !blocked.isEmpty || error != nil || done != nil
  }
}
