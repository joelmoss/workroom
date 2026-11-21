import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// The Terminals section's list, the sidebar's top pane under its sticky heading
/// (`SidebarTerminalsHeader`, ADR 0077): one row per terminal with no project and per terminal
/// group, a group's terminals under it while it is unfolded. The rows are the app's
/// `TerminalsSection`, so every window lists the same ones; a group's terminals are this window's.
/// Rows reorder by dragging; a standalone terminal's row dragged onto another's makes a group of
/// the two, and any terminal's row dragged onto a group's joins it (`SidebarRowDrag`). Its own
/// `List`, so it scrolls on its own; hosted in the pane, so it is gated on the store alone (it
/// reads the section itself).
struct SidebarTerminalsList: View, Equatable {
  let store: AppStore
  @Environment(\.themeTokens) private var tokens
  /// A terminal's row being dragged, in this window's sidebar.
  @State private var rowDrag = SidebarRowDrag()

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }

  private var section: TerminalsSection { store.terminalsSection }
  private var actions: SidebarActions { .live(store: store) }
  private var sectionActions: SidebarSectionActions {
    .live(store: store, select: actions.select, rowDrag: rowDrag)
  }

  /// One List row of the section: an entry's own row, or one of `group`'s terminals under it.
  enum Item: Hashable {
    case entry(TargetID)
    case terminal(TerminalTab.ID, group: SidebarID)
  }

  var body: some View {
    List {
      // The rows drag under the title chip, not a snapshot of themselves.
      SidebarHeadingGap().background(SidebarTableDragImageHook())
      if !section.isFolded {
        let rows = Self.rows(of: section, in: store)
        ForEach(rows, id: \.item) { row in
          view(for: row)
        }
        // Reorders, and takes a group's terminal out to standalone or into another group. A row
        // let go on another's middle drops on it instead (`SidebarRowDrag`), and the List makes no
        // move of that drop; should one come anyway, it doesn't also move the row.
        .onMove { offsets, destination in
          listMove(rows.map(\.item), offsets, to: destination)
        }
      }
    }
    .sidebarListStyle()
  }

  /// The height the list's rows take, for the pane to size itself to them while no layout is
  /// saved: each entry's row, and each of an unfolded group's terminals, which are as tall.
  static func contentHeight(of section: TerminalsSection, in store: AppStore) -> CGFloat {
    let rowHeight =
      SidebarRowMetrics.rowHeight + ProjectSidebar.sectionRowInsets.top
      + ProjectSidebar.sectionRowInsets.bottom
    return CGFloat(rows(of: section, in: store).count) * rowHeight + ProjectSidebar.listPadding
      + SidebarRowMetrics.headingGap
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
  private static func rows(of section: TerminalsSection, in store: AppStore) -> [Row] {
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
            Row(
              item: .terminal($0.id, group: entry.sidebarID), entry: entry, target: target,
              holder: panel)
          }
      }
      guard let target = store.target(for: entry.sidebarID) else { return [own] }
      return [own]
        + store.terminals.tabs(for: target).map {
          Row(item: .terminal($0.id, group: entry.sidebarID), entry: entry, target: target)
        }
    }
  }

  /// Whether a group's terminals are listed under its row: unfolded, with terminals.
  private func showsTerminals(of group: TerminalGroup, _ sid: SidebarID) -> Bool {
    guard !group.isFolded else { return false }
    if group.isBuiltIn { return quickTerminalHasTerminals }
    guard let target = store.target(for: sid) else { return false }
    return !store.terminals.tabs(for: target).isEmpty
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
    case (.terminal(let tabID, _), _):
      if let target = row.target {
        SidebarTerminalGroupChild(
          store: store, tokens: tokens, tabID: tabID, target: target, parent: sid,
          holder: row.holder, actions: actions, rowDrag: rowDrag
        )
      }
    case (.entry, .standalone):
      SidebarHoverRegion(id: sid) { hovered in
        SidebarStandaloneRowAdapter(sid: sid, hovered: hovered, actions: sectionActions)
          .equatable()
          .paneDropZone(.target(sid), store: store)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(SidebarRowBackground(store: store, id: sid, hovered: hovered))
      }
    case (.entry, .group(let group)):
      SidebarHoverRegion(id: sid) { hovered in
        SidebarTerminalGroupRowAdapter(
          sid: sid, group: group, canFold: !group.isBuiltIn || quickTerminalHasTerminals,
          hovered: hovered, actions: sectionActions
        )
        .equatable()
        .paneDropZone(.target(sid), store: store)
        // Its terminals, all of them, dragged as one (#652): `SidebarRowDrag` follows the List's
        // drag, as for a standalone terminal's row. The Quick Terminal's row stays put.
        .simultaneousGesture(
          DragGesture(minimumDistance: SidebarRowDrag.startDistance, coordinateSpace: .global)
            .onChanged { [store, rowDrag] _ in rowDrag.moved(.entry(sid), in: store) },
          including: group.isBuiltIn ? .subviews : .all
        )
        .moveDisabled(group.isBuiltIn)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
          SidebarRowBackground(
            store: store, id: sid, hovered: hovered,
            passesSelectionToChild: showsTerminals(of: group, sid)))
      }
    }
  }

  /// A drag of the entries' own rows at `offsets` to List position `destination`: each lands above
  /// the first entry row at or after it, so a group's row let go among another group's terminals
  /// lands after that group. `rowMove` says where a single row lands.
  static func move(
    _ items: [Item], _ offsets: IndexSet, to destination: Int, in section: TerminalsSection
  ) {
    let before = entry(atOrAfter: destination, in: items)
    for offset in offsets {
      guard case .entry(let id) = items[offset], id != before else { continue }
      section.move(id, before: before)
    }
  }

  /// Where the List's drop of one row lands (#652).
  enum RowMove: Equatable {
    /// Let go in its own place: nothing moves.
    case stays
    /// An entry's row between the section's rows: it goes just above `before` (nil: the end).
    case reorders(before: TargetID?)
    /// A terminal's row among `group`'s terminals' rows: it joins the group (or, one of its own,
    /// moves) just above terminal `before`, in its tabs' order.
    case joins(SidebarID, before: TerminalTab.ID)
    /// A group's terminal's row between the section's rows: a standalone terminal just above
    /// `before` (nil: the end).
    case standalone(before: TargetID?)
  }

  /// Where the row at `offset`, dropped at List position `destination`, lands. The row below the
  /// gap says where that is: a group's terminal's row puts it in that group, just above that
  /// terminal; an entry's row, or none, is between the section's rows, below the last terminal of
  /// any group above. A group's row only reorders.
  static func rowMove(_ items: [Item], from offset: Int, to destination: Int) -> RowMove {
    let below = destination < items.count ? items[destination] : nil
    let next = entry(atOrAfter: destination, in: items)
    switch items[offset] {
    case .entry(let id):
      if case .standalone = id, case .terminal(let tab, let group) = below {
        return .joins(group, before: tab)
      }
      return id == next || destination == offset + 1 ? .stays : .reorders(before: next)
    case .terminal(let tabID, let group):
      if case .terminal(let tab, let other) = below {
        let inPlace = other == group && (tab == tabID || destination == offset + 1)
        return inPlace ? .stays : .joins(other, before: tab)
      }
      return .standalone(before: next)
    }
  }

  /// The first entry row at or after List position `destination`.
  private static func entry(atOrAfter destination: Int, in items: [Item]) -> TargetID? {
    items[min(destination, items.count)...].lazy.compactMap { item -> TargetID? in
      if case .entry(let id) = item { return id }
      return nil
    }.first
  }

  /// The List's move of the rows at `offsets` to `destination`, where `rowMove` says. A row that
  /// just dropped on another row's middle (`SidebarRowDrag`) doesn't also move.
  private func listMove(_ items: [Item], _ offsets: IndexSet, to destination: Int) {
    guard let offset = offsets.first, offsets.count == 1 else {
      return Self.move(items, offsets, to: destination, in: section)
    }
    let dragged: TerminalDragSource? =
      switch items[offset] {
      case .entry(let id): id.sidebarID.map(TerminalDragSource.entry)
      case .terminal(let tabID, let group): .terminal(tabID, of: group)
      }
    if let dragged, rowDrag.dropped(dragged) { return }
    switch Self.rowMove(items, from: offset, to: destination) {
    case .stays: break
    case .reorders(let before):
      guard case .entry(let id) = items[offset] else { return }
      section.move(id, before: before)
    case .joins(let group, let before):
      guard let dragged else { return }
      Task { [store] in
        await store.dropTerminals(dragged, on: .tab(before, in: group, after: false))
      }
    case .standalone(let before):
      guard case .terminal(let tabID, let group) = items[offset] else { return }
      Task { [store] in
        await store.dropRowAsStandalone(.terminal(tabID, group: group), before: before)
      }
    }
  }
}

/// The Terminals pane's sticky heading: "Terminals", its fold chevron, which collapses the pane,
/// and its New Standalone Terminal and New Terminal Group… buttons, on the section header band. A
/// terminal's tab let go on the band becomes a standalone terminal (#660); the drop zone is on the
/// band, not the heading's content, so the fold button keeps its clicks.
struct SidebarTerminalsHeader: View {
  let store: AppStore

  var body: some View {
    SidebarSectionHeading(
      title: "Terminals",
      isFolded: Binding(
        get: { store.isCollapsed(.terminals) }, set: { store.setCollapsed(.terminals, $0) }),
      id: "sidebar.terminals"
    ) {
      SidebarIconButton(
        systemImage: TerminalGroup.glyph, help: "New Terminal Group…",
        label: "New Terminal Group", id: "sidebar.terminals.newGroup"
      ) {
        TerminalGroupNamePrompt.present { [store] name in _ = store.newTerminalGroup(named: name) }
      }
      SidebarIconButton(
        systemImage: "plus",
        help: "New Standalone Terminal"
          + Shortcuts.shared.table.hint(for: .newStandaloneTerminal),
        label: "New Standalone Terminal", id: "sidebar.terminals.new"
      ) { store.newStandaloneTerminal() }
    }
    .background(SidebarSectionHeadingBand().paneDropZone(.standalone, store: store))
  }
}

/// A sidebar section's heading, the Terminals' and the Projects': the inspector's section header
/// look (`SectionHeaderLabel`, `SectionHeaderMetrics`), a leading fold chevron and the bold title,
/// which fold the section, then its buttons, the last a "+" in the trailing column every sidebar "+"
/// shares. It is its pane's sticky header, on the band (`SidebarSectionHeadingBand`), spanning the
/// sidebar as the inspector's spans its pane.
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
    .padding(.horizontal, SidebarRowMetrics.listContentInset)
    .frame(height: SectionHeaderMetrics.height)
  }
}

/// A heading's background: the section header band, edge to edge.
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
  /// Close a standalone terminal, in whichever window or panel holds it, as its menu's Close does.
  var closeStandalone: @MainActor (SidebarID) -> Void
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
      rowDragMoved: { [store, rowDrag] sid in rowDrag.moved(.entry(sid), in: store) },
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
      closeStandalone: { [store] sid in
        guard let (holder, target, tab) = store.standaloneTerminal(sid) else { return }
        holder.requestCloseTerminalTab(tab.id, for: target)
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
  var hovered = false
  let actions: SidebarSectionActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sid == rhs.sid && lhs.hovered == rhs.hovered
  }

  var body: some View {
    SidebarStandaloneRow(model: model, hovered: hovered, actions: actions).equatable()
  }

  private var model: SidebarStandaloneRowModel {
    SidebarStandaloneRowModel(
      sid: sid, title: title, tool: store.standaloneTerminal(sid)?.tab.recognizedTool,
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
  /// The program its pane tab shows the logo of (#141), shown in its glyph's place.
  var tool: RecognizedTool? = nil
  /// What its terminal reports, in whichever window holds it, as a workroom's row shows it (#358):
  /// waiting, then a stopped error, then running.
  let activity: SidebarTargetActivity
}

/// A standalone terminal's row: a terminal glyph, its terminal's name and, while hovered, a close
/// button, as a group's terminal's row has. Selecting it shows the terminal in this window.
struct SidebarStandaloneRow: View, Equatable {
  let model: SidebarStandaloneRowModel
  var hovered = false
  let actions: SidebarSectionActions

  @State private var renaming = false
  @State private var draft = ""

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.model == rhs.model && lhs.hovered == rhs.hovered
  }

  var body: some View {
    #if DEBUG
      let _ = {
        SidebarRowPasses.section += 1
        SidebarRowPasses.byRow[model.sid, default: 0] += 1
      }()
    #endif
    let sid = model.sid
    HStack(spacing: Spacing.s) {
      SidebarTabIcon(glyph: TerminalGroup.standaloneGlyph, tool: model.tool)
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
        TerminalTitleLabel(title: model.title, folderFont: .subheadline)
          .font(.callout).foregroundStyle(.primary, .secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if let id = sid.targetID { SidebarUnreadDot(source: .target(id)) }
      // The trailing column: its status at rest, its close button on hover. The button is drawn
      // over it (below), out of the row's combined accessibility element, so it stays a button of
      // its own.
      SidebarSectionStatusMark(sid: sid, activity: model.activity, actions: actions)
        .opacity(hovered && !renaming ? 0 : 1)
        .frame(width: SidebarRowMetrics.iconColumnWidth)
    }
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
    .onTapGesture { actions.select(sid) }
    // Dragged onto another standalone terminal's row, the two become a group (#659); onto a
    // group's row, or one of its terminals' rows, it joins that group (#652). Beside the
    // List's own drag, which reorders. Only its start is used: the List's drag takes the mouse,
    // and `SidebarRowDrag` follows it to the end (`SidebarRowDrag.startDistance`).
    .simultaneousGesture(
      DragGesture(minimumDistance: SidebarRowDrag.startDistance, coordinateSpace: .global)
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
    .overlay(alignment: .trailing) {
      CloseTerminalRowButton(
        title: model.title.text, visible: hovered && !renaming, help: "Close this terminal",
        id: "sidebar.close.\(sid.targetID?.encoded ?? "")"
      ) { actions.closeStandalone(sid) }
      .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    }
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
    if let id = sid.targetID { SidebarUnreadDot(source: .target(id)) }
    SidebarSectionStatusMark(sid: sid, activity: activity, actions: actions)
  }
}

/// A Terminals-section row's status alone, without its unread dot: waiting (which focuses the
/// terminal that has waited longest), a stopped error or running. A standalone terminal's row
/// shows it in its trailing column, where its close button takes its place on hover.
struct SidebarSectionStatusMark: View {
  let sid: SidebarID
  let activity: SidebarTargetActivity
  let actions: SidebarSectionActions

  var body: some View {
    if let id = sid.targetID {
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
