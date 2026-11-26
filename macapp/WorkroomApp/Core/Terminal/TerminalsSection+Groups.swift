import Foundation
import WorkroomDomain

/// A terminal group's entry in the Terminals section (ADR 0077): what the user set on it. Its
/// terminals are each window's own tabs in `TargetID.terminalGroup(id)`, as a workroom's are.
struct TerminalGroup: Hashable, Sendable {
  let id: UUID
  /// The name the user gave it. Nil is an unnamed group, labelled "Group <number>", which goes
  /// when one terminal is left in it (`TerminalsSection.settleGroup`).
  var name: String?
  /// The folder its new terminals start in; nil follows "New terminals open in".
  var startingFolder: String?
  /// Whether its row is folded, hiding its terminals' rows. Kept in the section's file.
  var isFolded = false
  /// An unnamed group's number, its label's ("Group 2"): the lowest no other unnamed group had
  /// when it was made, and kept, so a label never changes while the group lasts. Nil while named.
  var number: Int?

  /// A group's symbol on its row and title-bar tab: terminals stacked together. Its "new" form,
  /// `newGlyph`, adds a plus badge.
  static let glyph = "rectangle.stack"

  /// The New Terminal Group… symbol, on the Terminals heading and the move menu.
  static let newGlyph = "rectangle.stack.badge.plus"

  /// A standalone terminal's symbol on its row, title-bar tab, picker row and move menu.
  static let standaloneGlyph = "terminal"

  /// What an unnamed group with no number yet is called. An unnamed group is never labelled by
  /// its terminals' titles, which change as their programs run.
  static let untitled = "Terminal Group"

  /// The Quick Terminal's group, built in (ADR 0077): a fixed id and name, and nothing else set.
  static let quickTerminal = TerminalGroup(
    id: TargetID.quickTerminalGroupID, name: "Quick Terminals")

  /// Whether this is the Quick Terminal's group, which can't be deleted, moved or renamed.
  var isBuiltIn: Bool { id == TargetID.quickTerminalGroupID }

  /// Its row's and title-bar tab's label: its name, else "Group <number>", else `untitled`.
  var title: String { name ?? number.map { "Group \($0)" } ?? Self.untitled }

  /// Where its new terminals start: its starting folder while that is still a folder, else "New
  /// terminals open in". A folder that has gone, or sits on a stalled volume, never leaves the
  /// group's terminals without a home (a restore reattaches only to a target whose path exists).
  /// It reads `presence`'s last answer, so the main actor never stats the folder; one not checked
  /// yet is taken as there while its check runs.
  @MainActor func workingDirectory(presence: FolderPresence = .shared) -> String {
    guard let path = startingPath, presence.isFolder(path) else {
      return TerminalsSection.newTerminalDirectory()
    }
    return path
  }

  /// `workingDirectory(presence:)` from a fresh, bounded check, for a caller that can wait for one.
  @MainActor func checkedWorkingDirectory(presence: FolderPresence = .shared) async -> String {
    guard let path = startingPath, await presence.check(path) else {
      return TerminalsSection.newTerminalDirectory()
    }
    return path
  }

  /// Its starting folder with `~` expanded, or nil when it has none.
  var startingPath: String? {
    guard let startingFolder else { return nil }
    let path = (startingFolder as NSString).expandingTildeInPath
    return path.isEmpty ? nil : path
  }
}

/// The section's terminal groups: making, naming, folding, giving a starting folder and moving rows.
/// Every edit is keyed by the group's target and takes plain values, so a prompt, an inline field
/// or a test all reach the same rule.
extension TerminalsSection {
  /// Checks the starting folder of each group among `ids` afresh, at once, off the main actor
  /// (`folderPresence`), so a target built after it starts where that folder's answer says: a
  /// session recovery runs this before it reads the groups' targets.
  func checkStartingFolders(of ids: some Sequence<TargetID>) async {
    let presence = folderPresence
    let checks = Set(ids.compactMap { group($0)?.startingPath }).map { path in
      Task { await presence.check(path) }
    }
    for check in checks { _ = await check.value }
  }

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
    insert(.group(newGroup(id: id, named: name)), after: anchor)
  }

  /// A new group named `name`, or, unnamed, numbered (`nextGroupNumber`).
  func newGroup(id: UUID = UUID(), named name: String?) -> TerminalGroup {
    let name = TerminalPanes.cleanedName(name)
    return TerminalGroup(id: id, name: name, number: name == nil ? nextGroupNumber() : nil)
  }

  /// The lowest number from 1 that no unnamed group has.
  func nextGroupNumber() -> Int {
    let taken = Set(
      entries.compactMap { entry -> Int? in
        guard case .group(let group) = entry, group.name == nil else { return nil }
        return group.number
      })
    return (1...).first { !taken.contains($0) } ?? 1
  }

  /// Names group `id`. The name is trimmed; an empty one clears it, which makes the group unnamed
  /// and numbers it; a name frees its number. The Quick Terminal's group keeps its name.
  func renameGroup(_ id: TargetID, to name: String) {
    guard id != .quickTerminal else { return }
    let number = nextGroupNumber()
    updateGroup(id) {
      $0.name = TerminalPanes.cleanedName(name)
      $0.number = $0.name == nil ? ($0.number ?? number) : nil
    }
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

/// Groups coming and going (#659, ADR 0077): unnamed ones come together when a standalone terminal
/// is split or dropped on another, and dissolve back into a standalone terminal once they are down
/// to one terminal across every holder; every group, named or not, goes with its last terminal. Each change moves terminals between targets in place, keeping their shells, in
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

  /// Turns standalone terminal `id` into a group in its place, named `name` (nil: unnamed, as a
  /// split makes), its terminal the group's first, and returns the group; nil when it couldn't
  /// (`id` isn't a listed standalone terminal, or its session couldn't be retagged), leaving it as
  /// it was.
  func convertToGroup(_ id: TargetID, named name: String? = nil) async -> TargetID? {
    guard case .standalone = id, contains(id) else { return nil }
    let group = newGroup(named: name)
    let groupID = TargetID.terminalGroup(group.id)
    let moved = await rehome([(id, groupID)]) {
      guard contains(id) else { return false }
      replace(id, with: .group(group))
      return true
    }
    return moved ? groupID : nil
  }

  /// Makes a group named `name` of standalone terminals `destination` and `dropped`, in
  /// `destination`'s place, `dropped`'s terminal joining after `destination`'s, and returns it.
  func groupStandalone(
    _ dropped: TargetID, onto destination: TargetID, named name: String
  ) async -> TargetID? {
    guard case .standalone = dropped, case .standalone = destination, dropped != destination,
      contains(dropped), contains(destination)
    else { return nil }
    let group = newGroup(named: name)
    let groupID = TargetID.terminalGroup(group.id)
    let moved = await rehome([(destination, groupID), (dropped, groupID)]) {
      guard contains(destination), contains(dropped) else { return false }
      replace(destination, with: .group(group))
      remove(dropped)
      return true
    }
    return moved ? groupID : nil
  }

  /// Queues the group rules for group `id`: with no terminal left in any holder it goes, named or
  /// not, and an unnamed one with one left makes that terminal standalone in its place. A group
  /// with more stays as it is, and so does the Quick Terminal's, which is built in. Counted when its
  /// turn comes, not when asked, so a terminal on its way between holders is counted where it
  /// lands; and never during a quit, whose teardown empties every holder but must bring each group
  /// back as it was.
  func settleGroup(_ id: TargetID) {
    enqueueRegroup { [weak self] in await self?.settleNow(id) }
  }

  private func settleNow(_ id: TargetID) async {
    guard let group = group(id), !group.isBuiltIn, !WindowRegistry.shared.isTerminating else {
      return
    }
    switch terminalNames(of: id).count {
    case 0:
      remove(id)
    case 1 where group.name == nil:
      let standalone = UUID()
      _ = await rehome([(id, .standalone(standalone))]) {
        guard let current = self.group(id), current.name == nil, terminalNames(of: id).count == 1
        else {
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

extension SidebarID {
  /// The symbol every surface shows for a no-project terminal: `TerminalGroup.standaloneGlyph` or
  /// `TerminalGroup.glyph`. Nil for a project's target, whose symbol depends on the workroom.
  var terminalsGlyph: String? {
    switch self {
    case .standalone: return TerminalGroup.standaloneGlyph
    case .terminalGroup: return TerminalGroup.glyph
    default: return nil
    }
  }
}

/// Merging one group into another: a group's title-bar tab let go on another's (#652).
extension TerminalsSection {
  /// Whether group `from`'s terminals can all move into group `into`: two listed groups, neither
  /// the Quick Terminal's.
  func canMergeGroup(_ from: TargetID, into: TargetID) -> Bool {
    guard from != into, let source = group(from), let destination = group(into) else {
      return false
    }
    return !source.isBuiltIn && !destination.isBuiltIn
  }

  /// Moves every holder's terminals in group `from` to the end of group `into`, in order and
  /// keeping their shells, and deletes `from`, now empty. Whether it did.
  func mergeGroup(_ from: TargetID, into: TargetID) async -> Bool {
    guard canMergeGroup(from, into: into) else { return false }
    return await rehome([(from, into)]) {
      guard canMergeGroup(from, into: into) else { return false }
      remove(from)
      return true
    }
  }
}
