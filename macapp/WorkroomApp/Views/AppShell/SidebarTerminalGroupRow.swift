import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// A terminal group's row in the Terminals section (ADR 0077): the group glyph (the fold chevron
/// while hovered, as a workroom row's), its name (edited inline by Rename…) and New Terminal in Group. Selecting it shows the group in this
/// window as a workroom shows; its menu renames it, sets its starting folder and deletes it. The
/// Quick Terminal's group is listed first: its row slides the panel in, it folds only once its panel
/// has terminals to list, and it has no rename or delete, since it is built in.
struct SidebarTerminalGroupRow: View, Equatable {
  let model: SidebarTerminalGroupRowModel
  let actions: SidebarSectionActions

  @State private var renaming = false
  @State private var draft = ""

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

  private var sid: SidebarID { model.sid }
  private var group: TerminalGroup { model.group }
  private var title: String { model.title }
  private var key: String { sid.targetID?.encoded ?? "" }

  var body: some View {
    #if DEBUG
      let _ = {
        SidebarRowPasses.section += 1
        SidebarRowPasses.byRow[model.sid, default: 0] += 1
      }()
    #endif
    HStack(spacing: Spacing.s) {
      // One leading column, as a workroom row's: the group's glyph, swapped for the fold chevron
      // while the row is hovered and has terminals to fold.
      if model.showsFoldButton {
        TerminalDisclosureButton(
          expanded: !group.isFolded, width: SidebarRowMetrics.caretWidth,
          help: group.isFolded ? "Show this group's terminals" : "Hide this group's terminals",
          label: group.isFolded ? "Expand \(title)" : "Collapse \(title)",
          action: toggleFold
        )
        .accessibilityIdentifier("sidebar.group.fold.\(key)")
      } else {
        Image(systemName: group.isBuiltIn ? QuickTerminalController.glyph : TerminalGroup.glyph)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
      }

      if renaming {
        SidebarInlineNameField(
          placeholder: "Terminal group name", draft: $draft,
          help: "The group's name. Leave it empty to label the group by its terminals' names",
          id: "sidebar.group.rename.\(key)", commit: commitRename, cancel: { renaming = false })
      } else {
        Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)

      // Its terminals' marks: waiting beats a stopped error beats running.
      SidebarSectionActivityMarks(sid: sid, activity: model.activity, actions: actions)

      SidebarIconButton(
        systemImage: "plus", help: newTerminalTitle, id: "sidebar.group.new.\(key)",
        action: newTerminal)
    }
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .frame(height: SidebarRowMetrics.rowHeight)
    .contentShape(Rectangle())
    .onTapGesture { actions.select(sid) }
    .help(rowHelp)
    .contextMenu { menu }
    // Rename… on the group's title-bar tab edits the name here, while the row is drawn.
    .sidebarInlineRename(sid, in: actions.inlineRename, begin: beginRename)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.group.\(key)")
    .sidebarFoldAccessibilityAction(model.foldItem, toggle: toggleFold)
  }

  private var newTerminalTitle: String { SidebarTerminalGroupRowModel.newTerminalTitle(for: group) }

  private var rowHelp: String {
    let base = group.isBuiltIn ? "Show the Quick Terminal" : title
    return group.startingFolder.map { "\(base) — starts in \($0)" } ?? base
  }

  @ViewBuilder private var menu: some View {
    SidebarFoldMenuItem(item: model.foldItem, toggle: toggleFold)
    Button(newTerminalTitle, action: newTerminal)
    if !group.isBuiltIn {
      Button("Rename…", action: beginRename)
    }
    Divider()
    Button("Set Starting Folder…", action: chooseStartingFolder)
    if group.startingFolder != nil {
      Button("Use “New terminals open in”") {
        actions.setStartingFolder(sid, nil)
      }
    }
    if !group.isBuiltIn {
      Divider()
      Button("Delete “\(title)”…", action: delete)
    }
  }

  private func toggleFold() {
    guard let id = sid.targetID else { return }
    actions.setFolded(id, !group.isFolded)
  }

  private func beginRename() {
    guard !group.isBuiltIn else { return }
    draft = group.name ?? ""
    renaming = true
  }

  private func commitRename() {
    renaming = false
    actions.rename(sid, draft)
  }

  /// A terminal in the group, in this window, with the group selected to show it.
  private func newTerminal() { actions.newTerminal(sid) }

  private func chooseStartingFolder() {
    guard let folder = TerminalGroupPrompts.chooseStartingFolder(for: title, current: group)
    else { return }
    actions.setStartingFolder(sid, folder)
  }

  /// Deletes the group, asking first only when it has terminals, which become standalone.
  private func delete() {
    guard TerminalGroupPrompts.confirmDelete(title, asks: actions.deleteAsks(sid)) else { return }
    actions.delete(sid)
  }
}

/// A terminal group's prompts, shared by its sidebar row's menu and its title-bar tab's.
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
  /// name labels it by its terminals' names, as the row's field does.
  static func rename(_ group: TerminalGroup, onRename: @escaping @MainActor (String) -> Void) {
    TextFieldPrompt.present(
      title: "Rename Terminal Group",
      message: "Leave the name empty to label the group by its terminals' names.",
      value: group.name ?? "", placeholder: "Terminal group name",
      fieldID: "terminalGroup.rename.field",
      fieldHelp: "The name shown on the group's row and title-bar tab",
      confirm: "Rename", onConfirm: onRename)
  }
}

struct SidebarTerminalGroupRowModel: Equatable {
  let sid: SidebarID
  let group: TerminalGroup
  /// Its name, or "<first terminal> + N more" while it is unnamed.
  let title: String
  /// What its terminals report, in every window and the Quick Terminal's panel (story 13).
  let activity: SidebarTargetActivity
  /// Whether it folds (its chevron, on hover): always for a group
  /// of the user's; for the Quick Terminal's, once its panel has terminals to list under it.
  var canFold = true
  /// Whether the pointer is over the row, which swaps its glyph for the fold chevron.
  var hovered = false

  /// The fold chevron stands in the glyph's column only while the row is hovered and can fold, as
  /// a workroom row's does.
  var showsFoldButton: Bool { canFold && hovered }

  /// Its menu's and VoiceOver's Expand or Collapse, offered whenever its chevron would be.
  var foldItem: SidebarFoldItem? { canFold ? SidebarFoldItem(expanded: !group.isFolded) : nil }

  /// Its menu's and "+" button's New Terminal: in the group by name ("New Terminal in Quick
  /// Terminal", "New Terminal in Ops"); an unnamed group, whose label is its terminals' names, is
  /// just "Group".
  static func newTerminalTitle(for group: TerminalGroup) -> String {
    "New Terminal in \(group.name ?? "Group")"
  }
}

/// Builds a terminal group's row. Of the group it holds the entry the section lists, so a pass of
/// the section that leaves the group as it was re-runs neither this nor the row.
struct SidebarTerminalGroupRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  let sid: SidebarID
  let group: TerminalGroup
  /// See `SidebarTerminalGroupRowModel.canFold`.
  var canFold = true
  var hovered = false
  let actions: SidebarSectionActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sid == rhs.sid && lhs.group == rhs.group && lhs.canFold == rhs.canFold
      && lhs.hovered == rhs.hovered
  }

  var body: some View {
    SidebarTerminalGroupRow(model: model, actions: actions).equatable()
  }

  private var model: SidebarTerminalGroupRowModel {
    SidebarTerminalGroupRowModel(
      sid: sid, group: group, title: store.target(for: sid)?.title ?? TerminalGroup.untitled,
      activity: sid.targetID.map(store.sectionActivity(of:)) ?? SidebarTargetActivity(),
      canFold: canFold, hovered: hovered)
  }
}

/// The New Terminal Group… prompt: one text field for the group's name. OK with a name makes the
/// group; an empty name or Cancel makes nothing.
@MainActor
enum TerminalGroupNamePrompt {
  static func present(onName: @escaping @MainActor (String) -> Void) {
    TextFieldPrompt.present(
      title: "New Terminal Group",
      message: "A terminal group keeps its terminals together, and stays while it has a name.",
      placeholder: "Terminal group name", fieldID: "terminalGroup.name.field",
      fieldHelp: "The name shown on the group's row and title-bar tab",
      confirm: "Create", onConfirm: onName)
  }
}

/// One of a group's terminals under its row: this window's, at any count, selecting the group and
/// focusing that terminal on a tap; or one of the Quick Terminal's, held by its panel (`holder`),
/// sliding the panel in on it.
struct SidebarTerminalGroupChild: View {
  let store: AppStore
  let tokens: ThemeTokens
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  let parent: SidebarID
  var holder: QuickTerminalHost? = nil
  let actions: SidebarActions
  let insets: EdgeInsets

  @State private var hovered = false

  var body: some View {
    SidebarTerminalRowAdapter(
      tabID: tabID, target: target, parent: parent, hovered: hovered, actions: actions,
      holder: holder
    )
    .equatable()
    .onHover { hovered = $0 }
    .listRowInsets(insets)
    .listRowSeparator(.hidden)
    .listRowBackground(
      SidebarTerminalRowBackground(
        store: store, tokens: tokens, tabID: tabID, target: target, parent: parent,
        hovered: hovered))
  }
}
