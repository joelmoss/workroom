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
  var isKept: Bool { name != nil }

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
    for case .group(let group) in entries where TargetID.terminalGroup(group.id) == id {
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
    updateEntries { entries in
      if let anchor, let index = entries.firstIndex(where: { $0.targetID == anchor }) {
        entries.insert(entry, at: index + 1)
      } else {
        entries.append(entry)
      }
    }
    return entry.targetID
  }

  /// Names group `id`. The name is trimmed; an empty one clears it, which makes the group unnamed.
  func renameGroup(_ id: TargetID, to name: String) {
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
  /// drag to reorder. A row moved onto itself, or a row that isn't listed, stays where it is.
  func move(_ id: TargetID, before: TargetID?) {
    guard id != before, let from = entries.firstIndex(where: { $0.targetID == id }) else { return }
    updateEntries { entries in
      let entry = entries.remove(at: from)
      let to = before.flatMap { target in entries.firstIndex { $0.targetID == target } }
      entries.insert(entry, at: to ?? entries.endIndex)
    }
  }

  private func updateGroup(_ id: TargetID, _ change: (inout TerminalGroup) -> Void) {
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
