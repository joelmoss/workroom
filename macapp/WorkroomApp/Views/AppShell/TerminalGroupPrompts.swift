import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// A terminal group's prompts, shared by its Open row's menu and its title-bar tab's.
@MainActor
enum TerminalGroupPrompts {
  /// Set Starting Folder…'s open panel, at the group's folder: the folder chosen, or nil.
  static func chooseStartingFolder(for title: String, current group: TerminalGroup) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Set Starting Folder"
    panel.message = "New terminals in \(title) start in this folder."
    if let folder = group.startingFolder {
      panel.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path
  }

  /// Whether to delete the group: true at once when it `asks` nothing (it has no terminals), else
  /// the user's answer.
  static func confirmDelete(_ title: String, asks: Bool) -> Bool {
    guard asks else { return true }
    let alert = NSAlert()
    alert.messageText = "Delete “\(title)”?"
    alert.informativeText =
      "Its terminals stay open, each as a terminal of its own in the terminal group's place."
    alert.addButton(withTitle: "Delete “\(title)”")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Rename… for a group whose row isn't in view: a sheet, prefilled with its own name. An empty
  /// name numbers it ("Group 1"), as the row's field does.
  static func rename(_ group: TerminalGroup, onRename: @escaping @MainActor (String) -> Void) {
    TextFieldPrompt.present(
      title: "Rename Terminal Group",
      message: "Leave the name empty to number the group, as Group 1.",
      value: group.name ?? "", placeholder: "Terminal group name",
      fieldID: "terminalGroup.rename.field",
      fieldHelp: "The name shown on the group's row and title-bar tab",
      confirm: "Rename", onConfirm: onRename)
  }
}

/// The New Terminal Group… prompt: one text field for the group's name, filled in with the next
/// "Group <number>" free (`TerminalsSection.suggestedGroupName`) and selected, so Return takes it
/// and typing replaces it. OK with a name makes the group; an empty name or Cancel makes nothing.
@MainActor
enum TerminalGroupNamePrompt {
  static func present(
    suggested: String = TerminalsSection.shared.suggestedGroupName,
    onName: @escaping @MainActor (String) -> Void
  ) {
    TextFieldPrompt.present(
      title: "New Terminal Group",
      message: "A terminal group keeps its terminals together, and stays while it has a name.",
      value: suggested, placeholder: "Terminal group name", fieldID: "terminalGroup.name.field",
      fieldHelp: "The name shown on the group's row and title-bar tab",
      confirm: "Create", onConfirm: onName)
  }

  /// The prompt, awaited, filled in with `suggested`: the name, trimmed, or nil on Cancel or an
  /// empty name.
  static func name(suggested: String) async -> String? {
    let typed: String? = await withCheckedContinuation { done in
      TextFieldPrompt.present(
        title: "New Terminal Group",
        message: "Name the group these terminals will make.",
        value: suggested, placeholder: "Terminal group name", fieldID: "terminalGroup.name.field",
        fieldHelp: "The name shown on the group's row and title-bar tab",
        confirm: "Create",
        onConfirm: { done.resume(returning: $0) },
        onCancel: { done.resume(returning: nil) })
    }
    guard let name = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }
    return name
  }
}

extension TerminalGroup {
  /// A group's New Terminal item, on its menus: in the group by name ("New Terminal in Quick
  /// Terminal", "New Terminal in Ops"); an unnamed group by its number ("New Terminal in Group 2").
  static func newTerminalTitle(for group: TerminalGroup) -> String {
    "New Terminal in \(group.title)"
  }
}
