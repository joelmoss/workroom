import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// A terminal group's row in the Terminals section (ADR 0077): a fold chevron, the group glyph, its
/// name (edited inline by Rename…) and New Terminal in Group. Selecting it shows the group in this
/// window as a workroom shows; its menu renames it, sets its starting folder and deletes it.
struct SidebarTerminalGroupRow: View {
  let store: AppStore
  let sid: SidebarID
  let group: TerminalGroup
  let select: @MainActor (SidebarID) -> Void

  @State private var renaming = false
  @State private var draft = ""
  /// Whether the field has had the keys yet: only losing them after that commits the name.
  @State private var fieldHadFocus = false
  @FocusState private var fieldFocused: Bool

  private var title: String { store.target(for: sid)?.title ?? TerminalGroup.untitled }
  private var key: String { sid.targetID?.encoded ?? "" }

  var body: some View {
    HStack(spacing: 6) {
      Button {
        guard let id = sid.targetID else { return }
        store.terminalsSection.setFolded(id, !group.isFolded)
      } label: {
        Image(systemName: group.isFolded ? "chevron.right" : "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowMetrics.caretWidth, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(group.isFolded ? "Show this group's terminals" : "Hide this group's terminals")
      .accessibilityLabel(group.isFolded ? "Expand \(title)" : "Collapse \(title)")
      .accessibilityIdentifier("sidebar.group.fold.\(key)")

      Image(systemName: TerminalGroup.glyph)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)

      if renaming {
        TextField("Group name", text: $draft)
          .textFieldStyle(.plain)
          .font(.callout)
          .focused($fieldFocused)
          .onSubmit(commitRename)
          .onExitCommand { renaming = false }
          .onAppear { DispatchQueue.main.async { fieldFocused = true } }
          .onChange(of: fieldFocused) { _, focused in
            if focused {
              fieldHadFocus = true
            } else if fieldHadFocus, renaming {
              commitRename()
            }
          }
          .help("The group's name. Leave it empty to label the group by its terminals' names")
          .accessibilityIdentifier("sidebar.group.rename.\(key)")
      } else {
        Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 0)

      Button(action: newTerminal) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowMetrics.caretWidth, height: SidebarRowMetrics.rowHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("New Terminal in \(title)")
      .accessibilityLabel("New Terminal in \(title)")
      .accessibilityIdentifier("sidebar.group.new.\(key)")
    }
    .padding(.trailing, Spacing.s)
    .frame(height: SidebarRowMetrics.rowHeight)
    .contentShape(Rectangle())
    .onTapGesture { select(sid) }
    .help(group.startingFolder.map { "\(title) — starts in \($0)" } ?? title)
    .contextMenu { menu }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.group.\(key)")
  }

  @ViewBuilder private var menu: some View {
    Button("New Terminal in Group", action: newTerminal)
    Button("Rename…") {
      draft = group.name ?? ""
      fieldHadFocus = false
      renaming = true
    }
    Divider()
    Button("Set Starting Folder…", action: chooseStartingFolder)
    if group.startingFolder != nil {
      Button("Use “New terminals open in”") {
        store.setTerminalGroupStartingFolder(sid, to: nil)
      }
    }
    Divider()
    Button("Delete “\(title)”…", action: delete)
  }

  private func commitRename() {
    renaming = false
    store.renameTerminalGroup(sid, to: draft)
  }

  /// A terminal in the group, in this window, with the group selected to show it.
  private func newTerminal() {
    select(sid)
    guard let target = store.target(for: sid) else { return }
    store.newTerminal(in: target)
  }

  private func chooseStartingFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Set Starting Folder"
    panel.message = "New terminals in \(title) start in this folder."
    if let folder = group.startingFolder {
      panel.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.setTerminalGroupStartingFolder(sid, to: url.path)
  }

  /// Deletes the group, asking first only when it has terminals, which become standalone.
  private func delete() {
    if store.terminalGroupDeleteAsks(sid) {
      let alert = NSAlert()
      alert.messageText = "Delete “\(title)”?"
      alert.informativeText =
        "Its terminals stay open, each as a terminal of its own in the group's place."
      alert.addButton(withTitle: "Delete Group")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    Task { await store.deleteTerminalGroup(sid) }
  }
}

/// The New Terminal Group… prompt: one text field for the group's name. OK with a name makes the
/// group; an empty name or Cancel makes nothing.
@MainActor
enum TerminalGroupNamePrompt {
  static func present(onName: @escaping @MainActor (String) -> Void) {
    // One tick, so the button's own event has unwound before the sheet drops.
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = "New Terminal Group"
      alert.informativeText = "A group keeps its terminals together, and stays while it has a name."
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.placeholderString = "Group name"
      field.setAccessibilityIdentifier("terminalGroup.name.field")
      field.toolTip = "The name shown on the group's row and title-bar tab"
      alert.accessoryView = field
      alert.addButton(withTitle: "Create")
      alert.addButton(withTitle: "Cancel")
      alert.window.initialFirstResponder = field
      let resolve: (NSApplication.ModalResponse) -> Void = { response in
        if response == .alertFirstButtonReturn { onName(field.stringValue) }
      }
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        alert.beginSheetModal(for: window, completionHandler: resolve)
      } else {
        resolve(alert.runModal())
      }
    }
  }
}

/// One of a group's terminals under its row: this window's, at any count, selecting the group and
/// focusing that terminal on a tap.
struct SidebarTerminalGroupChild: View {
  let store: AppStore
  let tokens: ThemeTokens
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  let parent: SidebarID
  let actions: SidebarActions
  let insets: EdgeInsets

  @State private var hovered = false

  var body: some View {
    SidebarTerminalRowAdapter(
      tabID: tabID, target: target, parent: parent, hovered: hovered, actions: actions
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
