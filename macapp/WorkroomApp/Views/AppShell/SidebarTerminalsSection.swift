import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// The Terminals section at the top of the sidebar (ADR 0077): a heading that folds as a project
/// does, with New Standalone Terminal and New Terminal Group… beside it, and one row per terminal
/// with no project and per terminal group, a group's terminals under it while it is unfolded. The
/// rows are the app's `TerminalsSection`, so every window lists the same ones; a group's terminals
/// are this window's. Rows reorder by dragging, and a standalone terminal's row dragged onto
/// another's makes a group of the two.
struct SidebarTerminalsSection: View {
  let store: AppStore
  let actions: SidebarActions
  let headingInsets: EdgeInsets
  let rowInsets: EdgeInsets
  let terminalRowInsets: EdgeInsets
  @Environment(\.themeTokens) private var tokens
  /// A standalone terminal's row being dragged, in this window's sidebar.
  @State private var rowDrag = SidebarRowDrag()

  private var section: TerminalsSection { store.terminalsSection }
  private var sectionActions: SidebarSectionActions {
    .live(store: store, select: actions.select, rowDrag: rowDrag)
  }

  /// One List row of the section: an entry's own row, or one of a group's terminals under it.
  enum Item: Hashable {
    case entry(TargetID)
    case terminal(TerminalTab.ID)
  }

  var body: some View {
    SidebarTerminalsHeading(
      section: section, newTerminal: { store.newStandaloneTerminal() },
      newGroup: {
        TerminalGroupNamePrompt.present { [store] name in _ = store.newTerminalGroup(named: name) }
      }
    )
    .listRowInsets(headingInsets)
    .listRowSeparator(.hidden)
    // A terminal's tab let go on the band becomes a standalone terminal (#660). On the row's
    // background, not its content, so the fold button keeps its clicks.
    .listRowBackground(SidebarSectionHeadingBand().paneDropZone(.standalone, store: store))
    if !section.isFolded {
      let rows = items
      ForEach(rows, id: \.item) { row in
        view(for: row)
      }
      // Reorders. A row let go on another's middle groups instead (`SidebarRowDrag`), and the List
      // makes no move of that drop; should one come anyway, it doesn't also reorder the row.
      .onMove { offsets, destination in
        let items = rows.map(\.item)
        if let offset = offsets.first, offsets.count == 1, case .entry(let id) = items[offset],
          let sid = id.sidebarID, rowDrag.grouped(sid)
        {
          return
        }
        Self.move(items, offsets, to: destination, in: section)
      }
    }
  }

  private struct Row {
    let item: Item
    let entry: TerminalsSection.Entry
    let target: TerminalTarget?
    /// Who holds a terminal's row when it isn't this window: the Quick Terminal's panel.
    var holder: QuickTerminalHost? = nil
  }

  /// The section's rows top to bottom, each unfolded group followed by this window's terminals in
  /// it; the Quick Terminal's by its panel's, which is their only holder (story 10).
  private var items: [Row] {
    section.rows.flatMap { entry -> [Row] in
      let own = Row(item: .entry(entry.targetID), entry: entry, target: nil)
      guard case .group(let group) = entry, !group.isFolded else { return [own] }
      if group.isBuiltIn {
        guard let panel = section.observedQuickTerminalHolder as? QuickTerminalHost else {
          return [own]
        }
        let target = panel.target
        return [own]
          + panel.terminals.tabs(for: target).map {
            Row(item: .terminal($0.id), entry: entry, target: target, holder: panel)
          }
      }
      guard let target = store.target(for: entry.sidebarID) else { return [own] }
      return [own]
        + store.terminals.tabs(for: target).map {
          Row(item: .terminal($0.id), entry: entry, target: target)
        }
    }
  }

  /// Whether the Quick Terminal's panel has terminals to list under its row, folded or not.
  private var quickTerminalHasTerminals: Bool {
    guard let panel = section.observedQuickTerminalHolder as? QuickTerminalHost else {
      return false
    }
    return !panel.terminals.tabs(for: panel.target).isEmpty
  }

  @ViewBuilder private func view(for row: Row) -> some View {
    let sid = row.entry.sidebarID
    switch (row.item, row.entry) {
    case (.terminal(let tabID), _):
      if let target = row.target {
        SidebarTerminalGroupChild(
          store: store, tokens: tokens, tabID: tabID, target: target, parent: sid,
          holder: row.holder, actions: actions, insets: terminalRowInsets
        )
        .moveDisabled(true)
      }
    case (.entry, .standalone):
      SidebarStandaloneRowAdapter(sid: sid, actions: sectionActions)
        .equatable()
        .paneDropZone(.target(sid), store: store)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(SidebarRowBackground(store: store, id: sid, hovered: false))
    case (.entry, .group(let group)):
      SidebarHoverRegion(id: sid) { hovered in
        SidebarTerminalGroupRowAdapter(
          sid: sid, group: group, canFold: !group.isBuiltIn || quickTerminalHasTerminals,
          hovered: hovered, actions: sectionActions
        )
        .equatable()
        .paneDropZone(.target(sid), store: store)
        .moveDisabled(group.isBuiltIn)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(SidebarRowBackground(store: store, id: sid, hovered: hovered))
      }
    }
  }

  /// A drag of the rows at `offsets` (always entries' own rows: a group's terminals don't move) to
  /// List position `destination`: each lands above the first entry row at or after it, so a drop
  /// among a group's terminals lands after that group.
  static func move(
    _ items: [Item], _ offsets: IndexSet, to destination: Int, in section: TerminalsSection
  ) {
    let before = items[min(destination, items.count)...].lazy.compactMap { item -> TargetID? in
      if case .entry(let id) = item { return id }
      return nil
    }.first
    for offset in offsets {
      guard case .entry(let id) = items[offset], id != before else { continue }
      section.move(id, before: before)
    }
  }
}

/// "Terminals", its fold chevron, and its New Standalone Terminal and New Terminal Group… buttons.
private struct SidebarTerminalsHeading: View {
  let section: TerminalsSection
  let newTerminal: () -> Void
  let newGroup: () -> Void

  var body: some View {
    @Bindable var section = section
    SidebarSectionHeading(title: "Terminals", isFolded: $section.isFolded, id: "sidebar.terminals")
    {
      SidebarIconButton(
        systemImage: TerminalGroup.glyph, help: "New Terminal Group…",
        label: "New Terminal Group", id: "sidebar.terminals.newGroup", action: newGroup)
      SidebarIconButton(
        systemImage: "plus",
        help: "New Standalone Terminal"
          + Shortcuts.shared.table.hint(for: .newStandaloneTerminal),
        label: "New Standalone Terminal", id: "sidebar.terminals.new", action: newTerminal)
    }
  }
}

/// A sidebar section's heading, the Terminals' and the Projects': the inspector's section header
/// look (`SectionHeaderLabel`, `SectionHeaderMetrics`), a leading fold chevron and the bold title,
/// which fold the section, then its buttons, the last a "+" in the trailing column every sidebar "+"
/// shares. Its List row paints the band (`SidebarSectionHeadingBand`) with no insets
/// (`ProjectSidebar.headingInsets`), so it spans the sidebar as the inspector's spans its pane.
struct SidebarSectionHeading<Trailing: View>: View {
  let title: String
  @Binding var isFolded: Bool
  let id: String
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 0) {
      Button {
        isFolded.toggle()
      } label: {
        SectionHeaderLabel(
          title: title, collapsed: isFolded,
          leadingPadding: SectionHeaderMetrics.sidebarLeadingPadding)
      }
      .buttonStyle(.plain)
      .help(isFolded ? "Show the \(title) section" : "Hide the \(title) section")
      .accessibilityHint(
        isFolded ? "Expand \(title.lowercased())" : "Collapse \(title.lowercased())"
      )
      .accessibilityIdentifier(id)

      HStack(spacing: Spacing.s) { trailing() }
        .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    }
    .frame(height: SectionHeaderMetrics.height)
  }
}

/// A heading's List row background: the section header band, edge to edge.
struct SidebarSectionHeadingBand: View {
  var body: some View { Color.clear.sectionHeaderBand() }
}

/// What the Terminals section's rows do, as `SidebarActions` is for a project's rows. Built from the
/// window's store on each pass of the section; every closure takes the ids it acts on and captures
/// only the store, so a row whose gate skipped still acts on what it shows.
struct SidebarSectionActions {
  var select: @MainActor (SidebarID) -> Void
  /// Focus the terminal in a row's target that has waited longest, in whichever window holds it.
  var showWaiting: @MainActor (TargetID) -> Void
  /// A standalone terminal's row is being dragged (`SidebarRowDrag`).
  var rowDragMoved: @MainActor (SidebarID) -> Void
  /// Fold or unfold a group's row.
  var setFolded: @MainActor (TargetID, Bool) -> Void
  var rename: @MainActor (SidebarID, String) -> Void
  /// Name a standalone terminal; an empty name gives its default back.
  var renameStandalone: @MainActor (SidebarID, String) -> Void
  /// The name the user gave a standalone terminal, if any: what its row's field starts with.
  var standaloneName: @MainActor (SidebarID) -> String?
  /// How Rename… on a row's title-bar tab reaches the row (`SidebarInlineRename`).
  var inlineRename: SidebarInlineRename
  /// New Terminal in a group: in this window with the group selected, or in the Quick Terminal's
  /// panel for its group.
  var newTerminal: @MainActor (SidebarID) -> Void
  var setStartingFolder: @MainActor (SidebarID, String?) -> Void
  /// Whether deleting a group asks first: only when it has terminals.
  var deleteAsks: @MainActor (SidebarID) -> Bool
  var delete: @MainActor (SidebarID) -> Void

  @MainActor static func live(
    store: AppStore, select: @escaping @MainActor (SidebarID) -> Void, rowDrag: SidebarRowDrag
  ) -> SidebarSectionActions {
    SidebarSectionActions(
      select: select,
      showWaiting: { [store] id in store.showWaiting(inSectionTarget: id) },
      rowDragMoved: { [store, rowDrag] sid in rowDrag.moved(sid, in: store) },
      setFolded: { [store] id, folded in store.terminalsSection.setFolded(id, folded) },
      rename: { [store] sid, name in store.renameTerminalGroup(sid, to: name) },
      renameStandalone: { [store] sid, name in store.renameStandaloneTerminal(sid, to: name) },
      standaloneName: { [store] sid in store.standaloneTerminal(sid)?.tab.terminal?.userTitle },
      inlineRename: store.sidebarRename,
      newTerminal: { [store] sid in
        if sid.targetID == .quickTerminal { return store.revealQuickTerminal(newTerminal: true) }
        select(sid)
        guard let target = store.target(for: sid) else { return }
        store.newTerminal(in: target)
      },
      setStartingFolder: { [store] sid, folder in
        store.setTerminalGroupStartingFolder(sid, to: folder)
      },
      deleteAsks: { [store] sid in store.terminalGroupDeleteAsks(sid) },
      delete: { [store] sid in Task { await store.deleteTerminalGroup(sid) } })
  }
}

/// Builds a standalone terminal's row (`SidebarRowAdapters.swift` has the projects' adapters).
struct SidebarStandaloneRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  let sid: SidebarID
  let actions: SidebarSectionActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.sid == rhs.sid }

  var body: some View {
    SidebarStandaloneRow(model: model, actions: actions).equatable()
  }

  private var model: SidebarStandaloneRowModel {
    SidebarStandaloneRowModel(
      sid: sid, title: title,
      activity: sid.targetID.map(store.sectionActivity(of:)) ?? SidebarTargetActivity())
  }

  /// Its terminal's title, in parts so the row can fade a default title's folder.
  private var title: TerminalTitle {
    sid.targetID.flatMap { store.terminalsSection.terminalTitles(of: $0).first }
      ?? TerminalTitle(name: store.target(for: sid)?.title ?? TerminalsSection.untitled)
  }
}

struct SidebarStandaloneRowModel: Equatable {
  let sid: SidebarID
  let title: TerminalTitle
  /// What its terminal reports, in whichever window holds it, as a workroom's row shows it (#358):
  /// waiting, then a stopped error, then running.
  let activity: SidebarTargetActivity
}

/// A standalone terminal's row: a terminal glyph and its terminal's name. Selecting it shows the
/// terminal in this window.
struct SidebarStandaloneRow: View, Equatable {
  let model: SidebarStandaloneRowModel
  let actions: SidebarSectionActions

  @State private var renaming = false
  @State private var draft = ""

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

  var body: some View {
    #if DEBUG
      let _ = {
        SidebarRowPasses.section += 1
        SidebarRowPasses.byRow[model.sid, default: 0] += 1
      }()
    #endif
    let sid = model.sid
    HStack(spacing: Spacing.s) {
      Image(systemName: TerminalGroup.standaloneGlyph)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
      if renaming {
        SidebarInlineNameField(
          placeholder: model.title.text, draft: $draft,
          help: "The terminal's name. Leave it empty to show the title the program sets",
          id: "sidebar.standalone.rename.\(sid.targetID?.encoded ?? "")",
          commit: {
            renaming = false
            actions.renameStandalone(sid, draft)
          },
          cancel: { renaming = false })
      } else {
        TerminalTitleLabel(title: model.title)
          .font(.callout).foregroundStyle(.primary, .secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
      SidebarSectionActivityMarks(sid: sid, activity: model.activity, actions: actions)
    }
    .frame(height: SidebarRowMetrics.rowHeight)
    .contentShape(Rectangle())
    .onTapGesture { actions.select(sid) }
    // Dragged onto another standalone terminal's row, the two become a group (#659). Beside the
    // List's own drag, which reorders; `minimumDistance` keeps a click a click. Only its start is
    // used: the List's drag takes the mouse, and `SidebarRowDrag` follows it to the end.
    .simultaneousGesture(
      DragGesture(minimumDistance: 6, coordinateSpace: .global)
        .onChanged { _ in actions.rowDragMoved(sid) }
    )
    .contextMenu { SidebarStandaloneRowMenu(sid: sid, rename: beginRename) }
    // Rename… on its title-bar tab edits the name here, while the row is drawn.
    .sidebarInlineRename(sid, in: actions.inlineRename, begin: beginRename)
    .help(model.title.text)
    // Its parts combine into one button, but not while its name field is up, so that stays
    // reachable on its own.
    .accessibilityElement(children: renaming ? .contain : .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.standalone.\(sid.targetID?.encoded ?? "")")
  }

  /// Shows the name field, starting from the name the user gave it (empty for none), so keeping
  /// it unchanged never pins the default name over the program's own title.
  private func beginRename() {
    draft = actions.standaloneName(model.sid) ?? ""
    renaming = true
  }
}

/// A Terminals-section row's marks, as a workroom's row shows them (#358): its unread dot, then
/// one of waiting (which focuses the terminal that has waited longest), a stopped error or running.
struct SidebarSectionActivityMarks: View {
  let sid: SidebarID
  let activity: SidebarTargetActivity
  let actions: SidebarSectionActions

  var body: some View {
    if let id = sid.targetID {
      SidebarUnreadDot(source: .target(id))
      if activity.waiting > 0 {
        NeedsYouButton(count: activity.waiting, stale: activity.waitingStale) {
          actions.showWaiting(id)
        }
      } else if activity.failed || activity.running {
        RunningSpinner(failed: activity.failed)
      }
    }
  }
}

/// A standalone terminal's row menu (#660): Rename… (in the row), Move to…, Pop Out and Close,
/// acting on the window that holds its terminal, which may not be the one drawing the row. A
/// menu's content is built when it opens, so it reads the store itself, as the projects' row menus
/// do.
private struct SidebarStandaloneRowMenu: View {
  @EnvironmentObject private var store: AppStore
  let sid: SidebarID
  let rename: () -> Void

  var body: some View {
    if let (holder, target, tab) = store.standaloneTerminal(sid) {
      sidebarRenameMenuItem(action: rename)
      terminalMoveMenu(
        host: holder, tabID: tab.id, target: target,
        help: "Move this terminal into a group or a workroom")
      Button {
        holder.togglePaneWindow(tab.id, targetID: target.id)
      } label: {
        Label("Pop Out", systemImage: "macwindow.badge.plus")
      }
      .disabled(holder.terminals.detachedTabIDs.contains(tab.id))
      .help("Show this terminal in a window of its own")
      Divider()
      Button(role: .destructive) {
        holder.requestCloseTerminalTab(tab.id, for: target)
      } label: {
        Label("Close", systemImage: "xmark")
      }
      .help("Close this terminal")
    }
  }
}
