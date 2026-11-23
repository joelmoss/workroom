import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// A terminal group's row in the Terminals section (ADR 0077), laid out as a project's: its name
/// (edited inline by Rename…) with its fold chevron after it, its terminals' marks, and New
/// Terminal in Group, shown on hover with the marks sliding left for it. Selecting it shows the group in this
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
      if renaming {
        SidebarInlineNameField(
          placeholder: "Terminal group name", draft: $draft,
          help: "The group's name. Leave it empty to label the group by its terminals' names",
          id: "sidebar.group.rename.\(key)", commit: commitRename, cancel: { renaming = false })
      } else {
        // A project row's name: medium weight, secondary.
        Text(title).font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      // The fold chevron after the name, as a project row's, shown while the row is hovered,
      // whenever the group has terminals to fold (not the Quick Terminal before its first
      // terminal). Laid out always, so nothing moves as it fades in.
      if model.canFold, !renaming {
        Button(action: toggleFold) {
          SidebarDisclosureChevron(
            expanded: !group.isFolded, visible: model.hovered, weight: .semibold
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.isFolded ? "Show this group's terminals" : "Hide this group's terminals")
        .accessibilityLabel(group.isFolded ? "Expand \(title)" : "Collapse \(title)")
        .accessibilityIdentifier("sidebar.group.fold.\(key)")
      }
      Spacer(minLength: 0)

      // Its terminals' marks (waiting beats a stopped error beats running), sliding left on hover
      // for its "+", as a project row's do for its settings and "+".
      SidebarHoverTrailing(hovered: model.hovered && !renaming) {
        // Its terminals listed under it show their own marks (`listedHere`); it shows what the
        // rest report, in other windows or the Quick Terminal's panel.
        SidebarSectionActivityMarks(sid: sid, activity: model.activity, actions: actions)
      } buttons: {
        SidebarIconButton(
          systemImage: "plus", help: newTerminalTitle, id: "sidebar.group.new.\(key)",
          action: newTerminal)
      }
    }
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
    // A click anywhere on the row folds or unfolds it, as on a project's row; its title-bar tab
    // and its terminals' rows show it.
    .onTapGesture { model.canFold ? toggleFold() : actions.select(sid) }
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
  /// Whether it folds (its chevron): always for a group
  /// of the user's; for the Quick Terminal's, once its panel has terminals to list under it.
  var canFold = true
  /// Whether the pointer is over the row.
  var hovered = false

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
  /// Whose terminals are listed under its row here, left out of its marks
  /// (`AppStore.sectionActivity(of:excluding:)`), or nil while none are.
  var listedHere: TerminalPanes? = nil
  var hovered = false
  let actions: SidebarSectionActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sid == rhs.sid && lhs.group == rhs.group && lhs.canFold == rhs.canFold
      && lhs.listedHere === rhs.listedHere && lhs.hovered == rhs.hovered
  }

  var body: some View {
    SidebarTerminalGroupRow(model: model, actions: actions).equatable()
  }

  private var model: SidebarTerminalGroupRowModel {
    SidebarTerminalGroupRowModel(
      sid: sid, group: group, title: store.target(for: sid)?.title ?? TerminalGroup.untitled,
      activity: sid.targetID.map { store.sectionActivity(of: $0, excluding: listedHere) }
        ?? SidebarTargetActivity(),
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
/// sliding the panel in on it. It looks as a standalone terminal's row does, indented under the
/// group (`SidebarTerminalRowStyle.section`). Dragged onto another group's row, or one of its
/// terminals' rows, it moves into that group; let go between the section's rows, it becomes a
/// standalone terminal there (#652). It is also part of its group's drop zone, so a terminal let go
/// on it joins the group, whose own row shows the highlight.
struct SidebarTerminalGroupChild: View {
  let store: AppStore
  let tokens: ThemeTokens
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  let parent: SidebarID
  var holder: QuickTerminalHost? = nil
  let actions: SidebarActions
  let rowDrag: SidebarRowDrag

  @State private var hovered = false

  var body: some View {
    SidebarTerminalRowAdapter(
      tabID: tabID, target: target, parent: parent, hovered: hovered, actions: actions,
      holder: holder, style: .section
    )
    .equatable()
    // A terminal let go on it lands in its group just above it (#652).
    .paneDropZone(.terminalRow(tabID, in: parent), store: store)
    // Beside the List's own drag, which takes it out to standalone (`SidebarTerminalsList`); only
    // its start is used, and `SidebarRowDrag` follows the pointer to the end, as a standalone
    // terminal's row's drag does.
    .simultaneousGesture(
      DragGesture(minimumDistance: SidebarRowDrag.startDistance, coordinateSpace: .global)
        .onChanged { [store, rowDrag, tabID, parent] _ in
          rowDrag.moved(.terminal(tabID, of: parent), in: store)
        }
    )
    .sidebarRowHover($hovered)
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listRowBackground(
      SidebarTerminalRowBackground(
        store: store, tokens: tokens, tabID: tabID, target: target, parent: parent,
        hovered: hovered, style: .section))
  }
}
