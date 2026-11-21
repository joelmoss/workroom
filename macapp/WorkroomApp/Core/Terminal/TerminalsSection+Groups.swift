import Foundation
import WorkroomDomain

/// A terminal group's entry in the Terminals section (ADR 0077): what the user set on it. Its
/// terminals are each window's own tabs in `TargetID.terminalGroup(id)`, as a workroom's are.
struct TerminalGroup: Hashable, Sendable {
  let id: UUID
  /// The name the user gave it. Nil is an unnamed group, labelled by its terminals' names; a name
  /// is what keeps a group once its terminals have gone (`isKept`).
  var name: String?
  /// The folder its new terminals start in; nil follows "New terminals open in".
  var startingFolder: String?
  /// Whether its row is folded, hiding its terminals' rows. Kept in the section's file.
  var isFolded = false

  /// A group's symbol on its row and title-bar tab: terminals stacked together.
  static let glyph = "square.on.square"

  /// What a group is called when it has no name and no terminals to be labelled by.
  static let untitled = "Terminal Group"

  /// Whether the group stays when it has no terminals: a named one does (glossary: Terminal group).
  /// The Quick Terminal's is named, so it always stays.
  var isKept: Bool { name != nil }

  /// The Quick Terminal's group, built in (ADR 0077): a fixed id and name, and nothing else set.
  static let quickTerminal = TerminalGroup(
    id: TargetID.quickTerminalGroupID, name: "Quick Terminal")

  /// Whether this is the Quick Terminal's group, which can't be deleted, moved or renamed.
  var isBuiltIn: Bool { id == TargetID.quickTerminalGroupID }

  /// Its row's and title-bar tab's label: its name, else its terminals' names joined with " + ",
  /// else `untitled`.
  func title(terminalNames: [String]) -> String {
    if let name { return name }
    return terminalNames.isEmpty ? Self.untitled : terminalNames.joined(separator: " + ")
  }

  /// Where its new terminals start: its starting folder while that is still a folder, else "New
  /// terminals open in". A folder that has gone never leaves the group's terminals without a home
  /// (a restore reattaches only to a target whose path exists).
  @MainActor var workingDirectory: String {
    if let startingFolder {
      var isDirectory: ObjCBool = false
      let path = (startingFolder as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return path
      }
    }
    return TerminalsSection.newTerminalDirectory()
  }
}

/// The section's terminal groups: making, naming, folding, giving a starting folder and moving rows.
/// Every edit is keyed by the group's target and takes plain values, so a prompt, an inline field
/// or a test all reach the same rule.
extension TerminalsSection {
  /// The group `id` names while it is listed, else nil.
  func group(_ id: TargetID) -> TerminalGroup? {
    for case .group(let group) in rows where TargetID.terminalGroup(group.id) == id {
      return group
    }
    return nil
  }

  /// Lists a new group, just below `anchor` when that is a row of this section, else at the end,
  /// and returns its target. A name that trims to nothing makes an unnamed group. `id` is fixed only
  /// by the UI-test fixture.
  @discardableResult
  func addGroup(named name: String?, after anchor: TargetID? = nil, id: UUID = UUID()) -> TargetID {
    let entry = Entry.group(TerminalGroup(id: id, name: TerminalPanes.cleanedName(name)))
    let index = index(after: anchor)
    updateEntries { entries in
      if let index {
        entries.insert(entry, at: index)
      } else {
        entries.append(entry)
      }
    }
    return entry.targetID
  }

  /// Names group `id`. The name is trimmed; an empty one clears it, which makes the group unnamed.
  /// The Quick Terminal's group keeps its name.
  func renameGroup(_ id: TargetID, to name: String) {
    guard id != .quickTerminal else { return }
    updateGroup(id) { $0.name = TerminalPanes.cleanedName(name) }
  }

  /// Sets the folder group `id`'s new terminals start in; nil (or empty) follows "New terminals
  /// open in" again.
  func setStartingFolder(_ id: TargetID, to folder: String?) {
    updateGroup(id) { $0.startingFolder = TerminalPanes.cleanedName(folder) }
  }

  /// Folds or unfolds group `id`'s row.
  func setFolded(_ id: TargetID, _ folded: Bool) {
    updateGroup(id) { $0.isFolded = folded }
  }

  /// Moves row `id` to just above row `before`, or to the end when `before` is nil: the sidebar's
  /// drag to reorder. A row moved onto itself, or a row that isn't listed, stays where it is. The
  /// Quick Terminal's group never moves, and a row moved above it lands just below it.
  func move(_ id: TargetID, before: TargetID?) {
    guard id != before, let from = entries.firstIndex(where: { $0.targetID == id }) else { return }
    updateEntries { entries in
      let entry = entries.remove(at: from)
      let to = before.flatMap { target in
        target == .quickTerminal ? 0 : entries.firstIndex { $0.targetID == target }
      }
      entries.insert(entry, at: to ?? entries.endIndex)
    }
  }

  private func updateGroup(_ id: TargetID, _ change: (inout TerminalGroup) -> Void) {
    if id == .quickTerminal { return updateQuickTerminal(change) }
    updateEntries { entries in
      guard
        let index = entries.firstIndex(where: { $0.targetID == id }),
        case .group(var group) = entries[index]
      else { return }
      change(&group)
      entries[index] = .group(group)
    }
  }
}

/// Unnamed groups (#659): they come together when a standalone terminal is split or dropped on
/// another, and dissolve back into a standalone terminal once they are down to one terminal across
/// every holder. Each change moves terminals between targets in place, keeping their shells, in
/// every holder that has them, and runs in turn with the others (`enqueueRegroup`).
extension TerminalsSection {
  /// Runs `work` once every regroup queued before it has finished, and returns its task.
  @discardableResult
  func enqueueRegroup<Result>(_ work: @escaping @MainActor () async -> Result) -> Task<
    Result, Never
  > {
    let previous = regroupTail
    let task = Task { @MainActor in
      await previous?.value
      return await work()
    }
    regroupTail = Task { @MainActor in _ = await task.value }
    return task
  }

  /// Waits until no regroup is queued: tests, and anything that reads the section after one.
  func regroupsSettled() async {
    while let tail = regroupTail {
      await tail.value
      if regroupTail == tail { return }
    }
  }

  /// Moves every holder's terminals in each move's source to its destination, keeping their
  /// shells, around `edit`, the section's own change that lists the destinations. Sessions are
  /// retagged first; when one can't be, or `edit` declines (the section changed meanwhile), every
  /// retag is undone and nothing moves. Returns whether the move happened.
  func rehome(_ moves: [(from: TargetID, to: TargetID)], edit: () -> Bool) async -> Bool {
    let sources = moves.compactMap { move in
      move.from.sidebarID.flatMap(target(for:)).map { (move: move, target: $0) }
    }
    guard sources.count == moves.count else { return false }
    var retagged: [(holder: any TerminalsSectionHolder, from: TargetID)] = []
    func undo() async {
      for done in retagged {
        _ = await done.holder.retagTerminals(forTargetID: done.from, as: done.from)
      }
    }
    for (move, _) in sources {
      for holder in allHolders where holder.holdsTerminals(forTargetID: move.from) {
        guard await holder.retagTerminals(forTargetID: move.from, as: move.to) else {
          await undo()
          return false
        }
        retagged.append((holder, move.from))
      }
    }
    guard edit() else {
      await undo()
      return false
    }
    for (move, source) in sources {
      for holder in allHolders where holder.holdsTerminals(forTargetID: move.from) {
        holder.rehomeTerminals(from: source, to: move.to)
      }
    }
    return true
  }

  /// Turns standalone terminal `id` into an unnamed group in its place, its terminal the group's
  /// first, and returns the group; nil when it couldn't (`id` isn't a listed standalone terminal,
  /// or its session couldn't be retagged), leaving it as it was.
  func convertToGroup(_ id: TargetID) async -> TargetID? {
    guard case .standalone = id, contains(id) else { return nil }
    let group = TerminalGroup(id: UUID())
    let groupID = TargetID.terminalGroup(group.id)
    let moved = await rehome([(id, groupID)]) {
      guard contains(id) else { return false }
      replace(id, with: .group(group))
      return true
    }
    return moved ? groupID : nil
  }

  /// Makes an unnamed group of standalone terminals `destination` and `dropped`, in
  /// `destination`'s place, `dropped`'s terminal joining after `destination`'s, and returns it.
  func groupStandalone(_ dropped: TargetID, onto destination: TargetID) async -> TargetID? {
    guard case .standalone = dropped, case .standalone = destination, dropped != destination,
      contains(dropped), contains(destination)
    else { return nil }
    let group = TerminalGroup(id: UUID())
    let groupID = TargetID.terminalGroup(group.id)
    let moved = await rehome([(destination, groupID), (dropped, groupID)]) {
      guard contains(destination), contains(dropped) else { return false }
      replace(destination, with: .group(group))
      remove(dropped)
      return true
    }
    return moved ? groupID : nil
  }

  /// Queues the unnamed group rule for group `id`: with no terminal left in any holder it goes, and
  /// with one, that terminal becomes a standalone terminal in its place. A named group, or one with
  /// two terminals or more, stays as it is. Counted when its turn comes, not when asked, so a
  /// terminal on its way between holders is counted where it lands.
  func settleUnnamedGroup(_ id: TargetID) {
    enqueueRegroup { [weak self] in await self?.settleNow(id) }
  }

  private func settleNow(_ id: TargetID) async {
    guard let group = group(id), !group.isKept else { return }
    switch terminalNames(of: id).count {
    case 0:
      remove(id)
    case 1:
      let standalone = UUID()
      _ = await rehome([(id, .standalone(standalone))]) {
        guard self.group(id)?.isKept == false, terminalNames(of: id).count == 1 else {
          return false
        }
        replace(id, with: .standalone(standalone))
        return true
      }
    default:
      break
    }
  }
}
