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

  private var section: TerminalsSection { store.terminalsSection }

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
      .onMove { offsets, destination in
        let items = rows.map(\.item)
        // Let go over the middle of another standalone terminal's row: they group instead (#659).
        if let offset = offsets.first, offsets.count == 1, case .entry(let id) = items[offset],
          let sid = id.sidebarID, store.rowDragEnded(sid, at: NSEvent.mouseLocation)
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
  }

  /// The section's rows top to bottom, each unfolded group followed by this window's terminals in it.
  private var items: [Row] {
    section.rows.flatMap { entry -> [Row] in
      let own = Row(item: .entry(entry.targetID), entry: entry, target: nil)
      guard case .group(let group) = entry, !group.isFolded,
        let target = store.target(for: entry.sidebarID)
      else { return [own] }
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
          actions: actions, insets: terminalRowInsets
        )
        .moveDisabled(true)
      }
    case (.entry, .standalone):
      SidebarStandaloneRow(store: store, sid: sid, actions: actions)
        .paneDropZone(.target(sid), store: store)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(SidebarRowBackground(store: store, id: sid, hovered: false))
    case (.entry, .group(let group)):
      SidebarTerminalGroupRow(store: store, sid: sid, group: group, select: actions.select)
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

/// A standalone terminal's row: a terminal glyph and its terminal's name. Selecting it shows the
/// terminal in this window.
private struct SidebarStandaloneRow: View {
  let store: AppStore
  let sid: SidebarID
  let actions: SidebarActions

  private var title: String { store.target(for: sid)?.title ?? TerminalsSection.untitled }
  /// What its terminal reports, as a workroom's row shows it (#358): waiting, then a stopped
  /// error, then running.
  private var activity: SidebarTargetActivity {
    sid.targetID.map(store.sidebarActivity(of:)) ?? SidebarTargetActivity()
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "terminal")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
      Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
      if let id = sid.targetID {
        SidebarUnreadDot(source: .target(id))
        if activity.waiting > 0 {
          NeedsYouButton(count: activity.waiting, stale: activity.waitingStale) {
            actions.showWaiting([id])
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
    // List's own drag, which reorders; `minimumDistance` keeps a click a click.
    .simultaneousGesture(
      DragGesture(minimumDistance: 6, coordinateSpace: .global)
        .onChanged { _ in store.rowDragMoved(sid) }
        .onEnded { _ in store.rowDragEnded(sid, at: NSEvent.mouseLocation) }
    )
    .contextMenu { SidebarStandaloneRowMenu(store: store, sid: sid) }
    .help(title)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.standalone.\(sid.targetID?.encoded ?? "")")
  }
}

/// A standalone terminal's row menu (#660): Rename…, Move to…, Pop Out and Close, acting on the
/// window that holds its terminal, which may not be the one drawing the row.
private struct SidebarStandaloneRowMenu: View {
  let store: AppStore
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
