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
    // A terminal's tab let go here becomes a standalone terminal (#660).
    .paneDropZone(.standalone, store: store)
    .listRowInsets(headingInsets)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
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
      SidebarTerminalGroupRowAdapter(sid: sid, group: group, actions: sectionActions)
        .equatable()
        .paneDropZone(.target(sid), store: store)
        .moveDisabled(group.isBuiltIn)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(SidebarRowBackground(store: store, id: sid, hovered: false))
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
    HStack(spacing: Spacing.s) {
      Button {
        section.isFolded.toggle()
      } label: {
        HStack(spacing: Spacing.s) {
          Text("Terminals").font(.callout).fontWeight(.medium)
            .foregroundStyle(.secondary)
          Image(systemName: section.isFolded ? "chevron.right" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(section.isFolded ? "Show terminals with no project" : "Hide terminals with no project")
      .accessibilityHint(section.isFolded ? "Expand terminals" : "Collapse terminals")
      .accessibilityIdentifier("sidebar.terminals")

      Button(action: newTerminal) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowMetrics.caretWidth, height: SidebarRowMetrics.rowHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(
        "New Standalone Terminal" + Shortcuts.shared.table.hint(for: .newStandaloneTerminal)
      )
      .accessibilityLabel("New Standalone Terminal")
      .accessibilityIdentifier("sidebar.terminals.new")

      Button(action: newGroup) {
        Image(systemName: TerminalGroup.glyph)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowMetrics.caretWidth, height: SidebarRowMetrics.rowHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("New Terminal Group…")
      .accessibilityLabel("New Terminal Group")
      .accessibilityIdentifier("sidebar.terminals.newGroup")
    }
    .padding(.trailing, Spacing.s)
    .frame(height: SidebarRowMetrics.rowHeight)
  }
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
      sid: sid, title: store.target(for: sid)?.title ?? TerminalsSection.untitled,
      activity: sid.targetID.map(store.sectionActivity(of:)) ?? SidebarTargetActivity())
  }
}

struct SidebarStandaloneRowModel: Equatable {
  let sid: SidebarID
  let title: String
  /// What its terminal reports, in whichever window holds it, as a workroom's row shows it (#358):
  /// waiting, then a stopped error, then running.
  let activity: SidebarTargetActivity
}

/// A standalone terminal's row: a terminal glyph and its terminal's name. Selecting it shows the
/// terminal in this window.
struct SidebarStandaloneRow: View, Equatable {
  let model: SidebarStandaloneRowModel
  let actions: SidebarSectionActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

  var body: some View {
    #if DEBUG
      let _ = {
        SidebarRowPasses.section += 1
        SidebarRowPasses.byRow[model.sid, default: 0] += 1
      }()
    #endif
    let sid = model.sid
    let activity = model.activity
    HStack(spacing: Spacing.s) {
      Image(systemName: TerminalGroup.standaloneGlyph)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
      Text(model.title).font(.callout).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
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
    .contextMenu { SidebarStandaloneRowMenu(sid: sid) }
    .help(model.title)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.standalone.\(sid.targetID?.encoded ?? "")")
  }
}

/// A standalone terminal's row menu (#660): Rename…, Move to…, Pop Out and Close, acting on the
/// window that holds its terminal, which may not be the one drawing the row. A menu's content is
/// built when it opens, so it reads the store itself, as the projects' row menus do.
private struct SidebarStandaloneRowMenu: View {
  @EnvironmentObject private var store: AppStore
  let sid: SidebarID

  var body: some View {
    if let (holder, target, tab) = store.standaloneTerminal(sid) {
      Button {
        TabRenamePrompt.present(currentName: tab.title) {
          holder.terminals.setUserTitle($0, forTab: tab.id, in: target)
        }
      } label: {
        Label("Rename…", systemImage: "pencil")
      }
      .help("Give this terminal a name")
      Menu {
        PaneMoveChoicesList(groups: holder.paneMoveChoices(tab.id, of: target))
      } label: {
        Label {
          Text("Move to…")
        } icon: {
          Image(nsImage: .moveTerminal)
        }
      }
      .help("Move this terminal into a group or a workroom")
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
