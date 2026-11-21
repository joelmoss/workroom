import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// A terminal group's row in the Terminals section (ADR 0077): a fold chevron, the group glyph, its
/// name (edited inline by Rename…) and New Terminal in Group. Selecting it shows the group in this
/// window as a workroom shows; its menu renames it, sets its starting folder and deletes it. The
/// Quick Terminal's group is listed first: its row slides the panel in, and it has no fold, rename
/// or delete, since its terminals are its panel's and it is built in.
struct SidebarTerminalGroupRow: View, Equatable {
  let model: SidebarTerminalGroupRowModel
  let actions: SidebarSectionActions

  @State private var renaming = false
  @State private var draft = ""
  /// Whether the field has had the keys yet: only losing them after that commits the name.
  @State private var fieldHadFocus = false
  @FocusState private var fieldFocused: Bool

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
      if group.isBuiltIn {
        Color.clear.frame(width: SidebarRowMetrics.caretWidth, height: 18)
      } else {
        Button {
          guard let id = sid.targetID else { return }
          actions.setFolded(id, !group.isFolded)
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
      }

      Image(systemName: group.isBuiltIn ? QuickTerminalController.glyph : TerminalGroup.glyph)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)

      if renaming {
        TextField("Terminal group name", text: $draft)
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

      // Its terminals' marks, as a workroom's row shows them (#358): waiting beats a stopped error
      // beats running.
      if let id = sid.targetID {
        SidebarUnreadDot(source: .target(id))
        if model.activity.waiting > 0 {
          NeedsYouButton(count: model.activity.waiting, stale: model.activity.waitingStale) {
            actions.showWaiting(id)
          }
        } else if model.activity.failed || model.activity.running {
          RunningSpinner(failed: model.activity.failed)
        }
      }

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
    .onTapGesture { actions.select(sid) }
    .help(rowHelp)
    .contextMenu { menu }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.group.\(key)")
  }

  private var rowHelp: String {
    let base = group.isBuiltIn ? "Show the Quick Terminal" : title
    return group.startingFolder.map { "\(base) — starts in \($0)" } ?? base
  }

  @ViewBuilder private var menu: some View {
    Button("New Terminal in Terminal Group", action: newTerminal)
    if !group.isBuiltIn {
      Button("Rename…") {
        draft = group.name ?? ""
        fieldHadFocus = false
        renaming = true
      }
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

  private func commitRename() {
    renaming = false
    actions.rename(sid, draft)
  }

  /// A terminal in the group, in this window, with the group selected to show it.
  private func newTerminal() { actions.newTerminal(sid) }

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
    actions.setStartingFolder(sid, url.path)
  }

  /// Deletes the group, asking first only when it has terminals, which become standalone.
  private func delete() {
    if actions.deleteAsks(sid) {
      let alert = NSAlert()
      alert.messageText = "Delete “\(title)”?"
      alert.informativeText =
        "Its terminals stay open, each as a terminal of its own in the terminal group's place."
      alert.addButton(withTitle: "Delete “\(title)”")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    actions.delete(sid)
  }
}

struct SidebarTerminalGroupRowModel: Equatable {
  let sid: SidebarID
  let group: TerminalGroup
  /// Its name, or its terminals' names joined while it is unnamed.
  let title: String
  /// What its terminals report, in every window and the Quick Terminal's panel (story 13).
  let activity: SidebarTargetActivity
}

/// Builds a terminal group's row. Of the group it holds the entry the section lists, so a pass of
/// the section that leaves the group as it was re-runs neither this nor the row.
struct SidebarTerminalGroupRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  let sid: SidebarID
  let group: TerminalGroup
  let actions: SidebarSectionActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sid == rhs.sid && lhs.group == rhs.group
  }

  var body: some View {
    SidebarTerminalGroupRow(model: model, actions: actions).equatable()
  }

  private var model: SidebarTerminalGroupRowModel {
    SidebarTerminalGroupRowModel(
      sid: sid, group: group, title: store.target(for: sid)?.title ?? TerminalGroup.untitled,
      activity: sid.targetID.map(store.sectionActivity(of:)) ?? SidebarTargetActivity())
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
      alert.informativeText =
        "A terminal group keeps its terminals together, and stays while it has a name."
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.placeholderString = "Terminal group name"
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
