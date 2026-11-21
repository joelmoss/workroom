import Foundation

/// Where a terminal sits, as the typing marker names it (#696).
struct PaneTypingPlace: Equatable {
  let target: TerminalTarget.ID
  /// The workroom the target is, or its project for a root; nil when no window can name it.
  let targetName: String?
  /// Its tab as the user sees it: its place in its target's strip, from 1, as ⌘1–9 count. Nil for
  /// a pane popped out into a window of its own, which is in no strip.
  let tab: Int?
  /// The coding agent running in it, as its tab latched it (`TerminalState`).
  let agent: CodingAgentBackend?

  /// Where `session`'s terminal is open: in any workroom window, or the Quick Terminal. Nil when
  /// none of them has a tab attached to it.
  @MainActor
  static func locate(_ session: UUID) -> PaneTypingPlace? {
    for host in WindowRegistry.shared.notifyingHosts {
      guard let found = host.terminals.typingPlace(ofSession: session) else { continue }
      return PaneTypingPlace(
        target: found.target, targetName: host.targetName(found.target), tab: found.tab,
        agent: found.agent)
    }
    return nil
  }
}

/// What a pane's typing marker shows (#696): who is typing into it, and from which tab.
///
/// **The sender** is named as the app names the program in the sender's tab: its coding agent's
/// name ("Claude", "Codex", `CodingAgentBackend.displayName`, the agent the tab latched from its
/// foreground process or title), else "Terminal" for any other program, which is never named from
/// its title (that is the send command itself). A send from no pane is "Outside Workroom", and one
/// from a terminal no window here has open is "Another terminal".
///
/// **The tab** is the sender's tab as the user sees it: "tab 2" for the second tab of its strip,
/// as ⌘2 selects it, with "in fix-auth" when it is in another workroom than this pane, and "own
/// window" for a pane popped out of its strip.
///
/// **Several senders at once** show as one marker: it names the sender that started typing first
/// and is still typing, so the name holds still while others interleave, with "+N" for the rest.
/// The tooltip names every one.
struct PaneTypingMarker: Equatable {
  enum Icon: Equatable {
    /// The coding agent's own logo, as its tab chip shows it.
    case agent(CodingAgentBackend)
    /// The `terminal` glyph a terminal's tab chip shows.
    case terminal
  }

  let icon: Icon
  /// "Claude".
  let name: String
  /// "tab 2" or "own window"; nil when the sender is in no tab.
  let tab: String?
  /// "fix-auth": the sender's workroom, when it is not this pane's.
  let workroom: String?
  /// How many others are typing into the pane too.
  let others: Int
  /// The tooltip, which VoiceOver reads too: "Claude in tab 2 is typing into this pane."
  let help: String

  /// Where the sender is, as one phrase: "tab 2", "tab 2 in fix-auth", "own window".
  var place: String? {
    guard let tab else { return nil }
    return workroom.map { "\(tab) in \($0)" } ?? tab
  }

  /// What the marker reads, as one line: "Claude · tab 2 +1".
  var text: String {
    var text = name
    if let place { text += " · \(place)" }
    if others > 0 { text += " +\(others)" }
    return text
  }

  /// The marker for a pane attached to `receiver`'s session, with `typists` typing into it; nil
  /// when nobody is. `locate` finds where a session's terminal is open.
  static func make(
    typists: [PaneTypingState.Typist], receiver: PaneTypingPlace?,
    locate: (UUID) -> PaneTypingPlace?
  ) -> PaneTypingMarker? {
    let senders = typists.map { describe($0.sender, receiver: receiver, locate: locate) }
    guard let first = senders.first else { return nil }
    let verb = senders.count == 1 ? "is" : "are"
    let help = "\(list(senders.map(\.phrase)).capitalizedFirst) \(verb) typing into this pane."
    return PaneTypingMarker(
      icon: first.icon, name: first.name, tab: first.tab, workroom: first.workroom,
      others: senders.count - 1, help: help)
  }

  private struct Sender {
    let icon: Icon
    let name: String
    var tab: String? = nil
    var workroom: String? = nil
    /// How the tooltip names it: "Claude in tab 2", "the terminal in tab 3".
    let phrase: String
  }

  private static func describe(
    _ sender: UUID?, receiver: PaneTypingPlace?, locate: (UUID) -> PaneTypingPlace?
  ) -> Sender {
    guard let sender else {
      return Sender(
        icon: .terminal, name: "Outside Workroom", phrase: "a program outside Workroom")
    }
    guard let place = locate(sender) else {
      return Sender(
        icon: .terminal, name: "Another terminal",
        phrase: "a terminal that isn't open in Workroom")
    }
    let tab = place.tab.map { "tab \($0)" } ?? "own window"
    // A popped-out pane's window is its own, whatever its workroom.
    let workroom =
      place.tab != nil && place.target != receiver?.target ? place.targetName : nil
    let inSpot =
      place.tab == nil ? "in its own window" : "in \(workroom.map { "\(tab) in \($0)" } ?? tab)"
    if let agent = place.agent {
      return Sender(
        icon: .agent(agent), name: agent.displayName, tab: tab, workroom: workroom,
        phrase: "\(agent.displayName) \(inSpot)")
    }
    let article = place.tab == nil ? "a" : "the"
    return Sender(
      icon: .terminal, name: "Terminal", tab: tab, workroom: workroom,
      phrase: "\(article) terminal \(inSpot)")
  }

  /// "A", "A and B", "A, B and C".
  private static func list(_ phrases: [String]) -> String {
    guard phrases.count > 1 else { return phrases.first ?? "" }
    return phrases.dropLast().joined(separator: ", ") + " and " + phrases[phrases.count - 1]
  }
}

extension String {
  /// The string with its first character upper-cased and the rest as they are.
  fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
