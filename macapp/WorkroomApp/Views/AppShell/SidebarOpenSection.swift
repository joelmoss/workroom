import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// One List row of the Open section (#819): a workroom tab's own row, or one of its tabs under it.
enum OpenSectionItem: Hashable {
  case workroom(SidebarID)
  case tab(TerminalTab.ID, in: SidebarID)
}

/// Where a dragged Open row lands. Every row is one height, so the drag's vertical travel counts
/// rows; a reorder is the pointer's row, not a gap the List opens (the List's own drag would take
/// the mouse from the split and tear-off drags).
enum OpenSectionReorder {
  /// The row `translation` points travel from `offset` reaches, among `count` rows.
  static func row(from offset: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
    guard count > 0, pitch > 0 else { return offset }
    let moved = Int((translation / pitch).rounded())
    return min(max(offset + moved, 0), count - 1)
  }

  /// The index among the workroom tabs that workroom row `offset`, dragged to List row `row`, takes:
  /// past every other workroom row above the pointer's row, and, dragged down, the one under it too.
  /// Nil when it stays.
  static func workroomIndex(_ items: [OpenSectionItem], from offset: Int, to row: Int) -> Int? {
    guard items.indices.contains(offset), case .workroom = items[offset] else { return nil }
    let others = items.indices.filter { index in
      guard index != offset, case .workroom = items[index] else { return false }
      return row > offset ? index <= row : index < row
    }
    let current = items[..<offset].filter { if case .workroom = $0 { true } else { false } }.count
    return others.count == current ? nil : others.count
  }
}

/// The Open section's sticky heading: "Open", its fold chevron, which collapses the pane, and one
/// "+" whose menu opens anything: Open Workroom…, New Terminal and New Terminal Group…. A terminal's
/// tab let go on the band becomes a standalone terminal (#660); the drop zone is on the band, not
/// the heading's content, so the fold button keeps its clicks.
struct SidebarOpenHeader: View {
  let store: AppStore

  var body: some View {
    SidebarSectionHeading(
      title: "Open",
      isFolded: Binding(get: { store.isCollapsed(.open) }, set: { store.setCollapsed(.open, $0) }),
      id: "sidebar.open"
    ) {
      SidebarOpenAddMenu(store: store)
    }
    .background(SidebarSectionHeadingBand().paneDropZone(.standalone, store: store))
  }
}

/// The Open heading's "+": every way to open something, each item with its shortcut.
struct SidebarOpenAddMenu: View {
  let store: AppStore

  var body: some View {
    CreateRowButton(help: "Open a workroom, a terminal or a terminal group") {
      Button {
        store.raiseWorkroomPicker(.open)
      } label: {
        Label("Open Workroom…", systemImage: "chevron.down.square")
      }
      .shortcut(.openWorkroom)
      .help("Pick a workroom, root or terminal group to open")
      .accessibilityIdentifier("sidebar.open.add.openWorkroom")
      Button {
        store.newStandaloneTerminal()
      } label: {
        Label("New Terminal", systemImage: TerminalGroup.standaloneGlyph)
      }
      .shortcut(.newStandaloneTerminal)
      .help("Open a terminal with no project")
      .accessibilityIdentifier("sidebar.open.add.newTerminal")
      Button {
        TerminalGroupNamePrompt.present { [store] name in _ = store.newTerminalGroup(named: name) }
      } label: {
        Label("New Terminal Group…", systemImage: TerminalGroup.newGlyph)
      }
      .help("Make a named group of terminals")
      .accessibilityIdentifier("sidebar.open.add.newGroup")
    }
    .accessibilityIdentifier("sidebar.open.add")
  }
}

/// The Open section's list, the sidebar's top pane under its sticky heading (#819, ADR 0082): this
/// window's workroom tabs in title-bar order (`AppStore.openSectionRows`), each unfolding to its
/// tabs in strip order. It keeps nothing of its own but the drag in flight: every row reads the
/// model and calls the store, so the section, the title bar and the strip never disagree. Its own
/// `List`, so it scrolls on its own and keeps the selected row in view.
struct SidebarOpenList: View, Equatable {
  let store: AppStore
  var drag: SidebarDragPlumbing = .inert
  /// Not Observation-tracked: held so unread, ✦, run and dirty marks re-render the rows.
  @EnvironmentObject private var notifications: NotificationCenterStore
  @EnvironmentObject private var codingAgents: TerminalCodingAgentManager
  @EnvironmentObject private var runCommand: RunCommandController
  @EnvironmentObject private var vcsStatus: VCSStatusService
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The row being dragged and the List row it would land on.
  @State private var reorder: (item: OpenSectionItem, row: Int)?

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.store === rhs.store && lhs.drag == rhs.drag
  }

  /// Every row's height, its insets included: what a drag's travel is counted in.
  static var rowPitch: CGFloat {
    SidebarRowMetrics.rowHeight + ProjectSidebar.sectionRowInsets.top
      + ProjectSidebar.sectionRowInsets.bottom
  }

  /// The List's rows, top to bottom: each workroom tab's, then its tabs' while it is unfolded.
  static func items(of rows: [OpenSectionRow]) -> [OpenSectionItem] {
    rows.flatMap { row -> [OpenSectionItem] in
      [.workroom(row.sid)] + (row.isFolded ? [] : row.tabs.map { .tab($0.tab.id, in: row.sid) })
    }
  }

  /// The height the list's rows take, for the pane to size itself to them while no layout is
  /// saved; one row for the empty state.
  static func contentHeight(of rows: [OpenSectionRow]) -> CGFloat {
    CGFloat(max(1, items(of: rows).count)) * rowPitch + ProjectSidebar.listPadding
      + SidebarRowMetrics.headingGap
  }

  var body: some View {
    let rows = store.openSectionRows()
    let items = Self.items(of: rows)
    return ScrollViewReader { proxy in
      List {
        SidebarHeadingGap()
        if !store.isCollapsed(.open) {
          if rows.isEmpty {
            emptyState
          }
          ForEach(rows) { row in
            workroomRow(row, items: items)
            if !row.isFolded {
              ForEach(row.tabs) { tab in tabRow(tab, in: row, items: items) }
            }
          }
        }
      }
      .sidebarListStyle()
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: items)
      .onChange(of: Self.scrollTarget(of: rows)) { _, target in
        guard let target else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(target) }
      }
    }
  }

  /// The row the selection is on: the focused tab's, or its workroom's while folded.
  static func scrollTarget(of rows: [OpenSectionRow]) -> OpenSectionItem? {
    guard let row = rows.first(where: \.isSelected) else { return nil }
    if !row.isFolded, let tab = row.tabs.first(where: \.isFocused) {
      return .tab(tab.tab.id, in: row.sid)
    }
    return .workroom(row.sid)
  }

  private var emptyState: some View {
    Text("Nothing open")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, SidebarRowMetrics.caretWidth + Spacing.s)
      .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
      .help("Open a workroom with ⌘O, or use the + above")
      .accessibilityIdentifier("sidebar.open.empty")
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }

  /// The insertion mark on the row a drag would land on, at the edge the dragged row comes in by.
  private func insertionEdge(of item: OpenSectionItem, in items: [OpenSectionItem]) -> Alignment? {
    guard let reorder, reorder.item != item, let from = items.firstIndex(of: reorder.item),
      items.indices.contains(reorder.row), items[reorder.row] == item
    else { return nil }
    return reorder.row > from ? .bottom : .top
  }

  private func workroomRow(_ row: OpenSectionRow, items: [OpenSectionItem]) -> some View {
    let item = OpenSectionItem.workroom(row.sid)
    let offset = items.firstIndex(of: item) ?? 0
    return SidebarHoverRegion(openItem: item) { hovered in
      SidebarOpenWorkroomRow(row: row, hovered: hovered, store: store).equatable()
        .modifier(SidebarDragDim(id: row.sid, drag: drag.drag))
        .overlay(alignment: insertionEdge(of: item, in: items) ?? .top) {
          if insertionEdge(of: item, in: items) != nil { DropInsertionMark(vertical: false) }
        }
        .paneDropZone(.target(row.sid), store: store)
        .simultaneousGesture(workroomDrag(row, offset: offset, items: items))
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
          SidebarOpenRowBackground(
            hovered: hovered,
            emphasis: row.isSelected
              ? (row.isFolded || row.tabs.isEmpty ? .selected : .selectedParent)
              : row.isVisibleInSplit ? .visible : .none))
    }
    .id(item)
  }

  private func tabRow(
    _ tab: OpenSectionTabRow, in row: OpenSectionRow, items: [OpenSectionItem]
  ) -> some View {
    let item = OpenSectionItem.tab(tab.tab.id, in: row.sid)
    return SidebarHoverRegion(openItem: item) { hovered in
      SidebarOpenTabRow(row: tab, hovered: hovered, store: store)
        .overlay(alignment: insertionEdge(of: item, in: items) ?? .top) {
          if insertionEdge(of: item, in: items) != nil { DropInsertionMark(vertical: false) }
        }
        // A terminal let go on it lands in its workroom just above it (#652).
        .paneDropZone(.terminalRow(tab.tab.id, in: row.sid), store: store)
        .simultaneousGesture(tabDrag(tab, in: row, items: items))
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
          SidebarOpenRowBackground(
            hovered: hovered,
            emphasis: tab.isFocused ? .selected : tab.isVisibleInSplit ? .visible : .none))
    }
    .id(item)
  }

  // MARK: Drags

  /// A workroom row's drag, as its title-bar chip's: onto a tab, row or title bar that takes its
  /// terminals (a standalone terminal's or group's, `TerminalDragSession`), into the content for a
  /// workroom split (`SidebarDragPlumbing`), else a reorder of the workroom tabs.
  private func workroomDrag(
    _ row: OpenSectionRow, offset: Int, items: [OpenSectionItem]
  ) -> some Gesture {
    let split = drag.splitGesture(row.sid, actions: .live(store: store))
    return DragGesture(minimumDistance: 6, coordinateSpace: .global)
      .onChanged { [store] value in
        let overTerminalDrop = store.terminalDrag.moved(
          .entry(row.sid), from: .sidebar, to: NSEvent.mouseLocation)
        let inContent = drag.drag.wrappedValue != nil
        reorder =
          overTerminalDrop || inContent
          ? nil
          : (
            .workroom(row.sid),
            OpenSectionReorder.row(
              from: offset, translation: value.translation.height, pitch: Self.rowPitch,
              count: items.count)
          )
      }
      .onEnded { [store] value in
        let landing = reorder?.row
        reorder = nil
        if store.terminalDrag.ended(at: NSEvent.mouseLocation) { return }
        guard drag.drag.wrappedValue == nil, let landing,
          let index = OpenSectionReorder.workroomIndex(items, from: offset, to: landing)
        else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
          store.moveWorkroomTab(row.sid, toIndex: index)
        }
      }
      .simultaneously(with: split)
  }

  /// A tab row's drag, as its strip chip's: onto a sidebar row, a title-bar tab, a pane tab or the
  /// Open heading (`AppStore.paneDragMoved`); out of the window it tears off; else a reorder among
  /// its workroom's tabs.
  private func tabDrag(
    _ tab: OpenSectionTabRow, in row: OpenSectionRow, items: [OpenSectionItem]
  ) -> some Gesture {
    let item = OpenSectionItem.tab(tab.tab.id, in: row.sid)
    let index = row.tabs.firstIndex { $0.id == tab.id } ?? 0
    return DragGesture(minimumDistance: 6, coordinateSpace: .global)
      .onChanged { [store] value in
        let panes = store.terminals
        if Self.isOutsideWindow(NSEvent.mouseLocation) {
          reorder = nil
          if store.paneDragMoved(tab.tab.id, of: tab.target, to: NSEvent.mouseLocation) {
            panes.hideDragOutside()
          } else {
            panes.showDragOutside(tab.tab)
          }
          return
        }
        panes.hideDragOutside()
        if store.paneDragMoved(tab.tab.id, of: tab.target, to: NSEvent.mouseLocation) {
          reorder = nil
          return
        }
        // Kept among its own workroom's tabs; another workroom's row takes it as a drop above.
        let moved = Int((value.translation.height / Self.rowPitch).rounded())
        let to = min(max(index + moved, 0), row.tabs.count - 1)
        let base = items.firstIndex(of: item).map { $0 - index } ?? 0
        reorder = (item, base + to)
      }
      .onEnded { [store] value in
        let panes = store.terminals
        panes.hideDragOutside()
        reorder = nil
        if store.paneDragEnded(tab.tab.id, of: tab.target, at: NSEvent.mouseLocation) { return }
        if Self.isOutsideWindow(NSEvent.mouseLocation) {
          panes.dropOutside(tab.tab.id, for: tab.target)
          return
        }
        let moved = Int((value.translation.height / Self.rowPitch).rounded())
        let to = min(max(index + moved, 0), row.tabs.count - 1)
        guard to != index else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
          store.moveOpenTab(tab.tab.id, toIndex: to, in: row.sid)
        }
      }
  }

  /// Whether a screen point has left the key window, where a drag started.
  private static func isOutsideWindow(_ screenPoint: CGPoint) -> Bool {
    guard let frame = NSApp.keyWindow?.frame else { return false }
    return !frame.contains(screenPoint)
  }
}

/// An Open row's fill: the selection for the selected workroom (when its focused tab isn't shown
/// under it) and the focused tab, a lighter one for the selected workroom over its tabs, and a
/// faint accent for what is on screen in another pane of a split.
struct SidebarOpenRowBackground: View {
  enum Emphasis { case none, visible, selectedParent, selected }
  let hovered: Bool
  let emphasis: Emphasis
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    switch emphasis {
    case .selected: SidebarSelectedRowFill()
    case .selectedParent:
      RoundedRectangle(cornerRadius: Radius.s)
        .fill(tokens.hover)
        .padding(.horizontal, SidebarRowMetrics.listContentInset)
        .padding(.vertical, 1)
    case .visible:
      RoundedRectangle(cornerRadius: Radius.s)
        .fill(tokens.accent.opacity(hovered ? 0.14 : 0.08))
        .padding(.horizontal, SidebarRowMetrics.listContentInset)
        .padding(.vertical, 1)
    case .none:
      RowHighlight(
        selected: false, hovered: hovered, horizontalPadding: SidebarRowMetrics.listContentInset)
    }
  }
}

/// A workroom tab's row in the Open section: what its title-bar chip shows (glyph tinted by VCS
/// state, unavailable warning, waiting glyph, unread-accented title, run mark, busy spinner), a
/// disclosure chevron in the glyph's slot on hover, and a hover ✕ that asks as the chip's does.
/// Its menu is the chip's, a standalone terminal's with Move to… and Pop Out too
/// (`WorkroomMenuModel.Style.openRow`). A standalone terminal's or group's name edits in place,
/// from Rename… on its menu or its title-bar chip (`SidebarInlineRename`).
struct SidebarOpenWorkroomRow: View {
  let row: OpenSectionRow
  let hovered: Bool
  let store: AppStore
  @Environment(\.themeTokens) private var tokens
  @State private var renaming = false
  @State private var draft = ""

  private var presentation: WorkroomTabPresentation { row.presentation }
  private var marks: WorkroomTabMarks { row.marks }
  private var id: String { row.target.id.encoded }

  var body: some View {
    #if DEBUG
      SidebarRowPasses.openRows[.workroom(row.sid), default: 0] += 1
    #endif
    return HStack(spacing: Spacing.s) {
      leadingSlot
      if let reason = row.target.terminalUnavailability {
        WarningGlyph().font(.system(size: 10)).help(reason.title)
          .accessibilityLabel(reason.title)
      }
      if renaming { nameField } else { title }
      Spacer(minLength: 0)
      SidebarHoverTrailing(hovered: hovered && !renaming && presentation.closeName != nil) {
        statusMark
        runMark
      } buttons: {
        Color.clear.frame(width: SidebarRowMetrics.iconColumnWidth, height: 1)
      }
    }
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
    .onTapGesture { store.selectWorkroomTab(row.sid) }
    .contextMenu {
      WorkroomMenuAdapter(
        sid: row.sid, target: row.target, closeName: presentation.closeName, style: .openRow)
    }
    .sidebarInlineRename(row.sid, in: store.sidebarRename, begin: beginRename)
    .help("\(presentation.fullTitle)\n\(row.target.path)")
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAction { store.selectWorkroomTab(row.sid) }
    .accessibilityActions {
      if presentation.closeName != nil { Button("Close") { requestClose() } }
      if row.canFold {
        Button(row.isFolded ? "Show tabs" : "Hide tabs") { store.toggleOpenRowFold(row.sid) }
      }
    }
    .accessibilityIdentifier("sidebar.open.workroom.\(id)")
    .overlay(alignment: .trailing) {
      if let closeName = presentation.closeName {
        CloseTerminalRowButton(
          title: closeName, visible: hovered && !renaming, help: "Close \(closeName)",
          id: "sidebar.open.close.\(id)"
        ) { requestClose() }
        .padding(.trailing, SidebarRowMetrics.iconColumnInset)
      }
    }
  }

  /// Its glyph, swapped for the disclosure chevron on hover when it has tabs to fold, as a project
  /// tree row's is.
  private var leadingSlot: some View {
    let showsChevron = row.canFold && hovered
    return SidebarAnimated(target: showsChevron) { chevron in
      ZStack {
        Image(systemName: presentation.glyph)
          .font(.system(size: 10))
          .foregroundStyle(VCSStatusPresentation.iconTint(marks.vcs, tokens))
          .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
          .help(row.target.hostTooltip)
          .accessibilityHidden(true)
          .opacity(1 - chevron)
        if row.canFold {
          TerminalDisclosureButton(
            expanded: !row.isFolded, width: SidebarRowMetrics.caretWidth,
            help: row.isFolded ? "Show its tabs" : "Hide its tabs",
            label: row.isFolded ? "Show tabs" : "Hide tabs"
          ) { store.toggleOpenRowFold(row.sid) }
          .opacity(chevron)
          .allowsHitTesting(showsChevron)
          .accessibilityIdentifier("sidebar.open.fold.\(id)")
        }
      }
    }
  }

  @ViewBuilder private var title: some View {
    let unread = marks.hasUnread
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      if let standalone = presentation.standaloneTitle {
        TerminalTitleLabel(title: standalone, folderFont: .subheadline)
          .foregroundStyle(
            unread ? tokens.accent : Color.primary,
            unread ? tokens.accent.opacity(0.7) : tokens.fgMuted
          )
          .truncationMode(.middle)
      } else {
        Text(presentation.primaryLabel)
          .foregroundStyle(unread ? tokens.accent : Color.primary)
      }
      if let workroom = presentation.workroomName {
        Text("/").foregroundStyle(.tertiary)
        Text(workroom).foregroundStyle(.secondary)
      }
    }
    .font(.callout)
    .lineLimit(1)
    .truncationMode(.tail)
  }

  /// The name field Rename… shows in the title's place: a group's name, or a standalone
  /// terminal's, where an empty one gives the default back.
  @ViewBuilder private var nameField: some View {
    let group = row.sid.isStandaloneTerminal == false
    SidebarInlineNameField(
      placeholder: group ? "Terminal group name" : presentation.fullTitle, draft: $draft,
      help: group
        ? "The group's name. Leave it empty to label the group by its terminals' names"
        : "The terminal's name. Leave it empty to show the title the program sets",
      id: "sidebar.open.rename.\(id)",
      commit: {
        renaming = false
        if group {
          store.renameTerminalGroup(row.sid, to: draft)
        } else {
          store.renameStandaloneTerminal(row.sid, to: draft)
        }
      },
      cancel: { renaming = false })
  }

  /// Shows the name field, starting from the name the user gave it (empty for none), so keeping
  /// it unchanged never pins a default name. Not for a workroom, nor the built-in Quick Terminal.
  private func beginRename() {
    switch row.sid {
    case .standalone:
      draft = store.standaloneTerminal(row.sid)?.tab.terminal?.userTitle ?? ""
    case .terminalGroup:
      guard let group = store.terminalGroup(row.sid), !group.isBuiltIn else { return }
      draft = group.name ?? ""
    case .project, .root, .workroom, .creation:
      return
    }
    renaming = true
  }

  /// Waiting first (which focuses the terminal that has waited longest), else a busy spinner, red
  /// once something reported an error.
  @ViewBuilder private var statusMark: some View {
    if marks.isWaiting {
      NeedsYouButton(count: marks.waitingCount, stale: marks.waitingStale) {
        if let id = row.sid.targetID { store.showWaiting(inSectionTarget: id) }
      }
    } else {
      switch marks.busy {
      case .running(let failed):
        RunningSpinner(failed: failed)
          .help(failed ? "A command reported an error" : "A command is running")
      case .error:
        RunningSpinner(failed: true).help("A command reported an error")
      default: EmptyView()
      }
    }
  }

  @ViewBuilder private var runMark: some View {
    if let run = marks.run {
      let running = run == .running
      Image(systemName: running ? "play.circle.fill" : "xmark.octagon.fill")
        .font(.system(size: 10))
        .foregroundStyle(running ? tokens.success : tokens.failure)
        .help(running ? "Run command running" : "Run command failed")
        .accessibilityLabel(running ? "run running" : "run failed")
    }
  }

  private func requestClose() {
    guard let closeName = presentation.closeName else { return }
    store.modals.pendingWorkroomClose = PendingWorkroomClose(target: row.target, name: closeName)
  }

  private var accessibilityLabel: String {
    var parts = [
      presentation.workroomName.map { "\(presentation.primaryLabel), workroom \($0)" }
        ?? presentation.fullTitle
    ]
    let vcs = VCSStatusPresentation.accessibilityLabel(marks.vcs)
    if !vcs.isEmpty { parts.append(vcs) }
    if let reason = row.target.terminalUnavailability { parts.append(reason.title.lowercased()) }
    if marks.run == .running { parts.append("running") }
    if marks.run == .failed { parts.append("run failed") }
    if marks.isWaiting {
      parts.append(
        ProgramStatusPresentation.waitingLabel(
          count: marks.waitingCount, stale: marks.waitingStale))
    }
    if case .running = marks.busy { parts.append("busy") }
    if marks.reportedError { parts.append("a command reported an error") }
    if marks.hasUnread { parts.append("unread activity") }
    if !row.tabs.isEmpty {
      parts.append(row.isFolded ? "\(row.tabs.count) tabs, folded" : "\(row.tabs.count) tabs")
    }
    return parts.joined(separator: ", ")
  }
}

/// One tab's row under its workroom in the Open section: what its strip chip shows (tool logo or
/// glyph, ✦ badge, title in italics while a preview, unread dot, waiting or finished glyph, busy
/// spinner or run state), a hover ✕ that closes it as the chip's does, and the chip's menu. A
/// second click on a preview's row keeps it, as on the chip.
struct SidebarOpenTabRow: View {
  let row: OpenSectionTabRow
  let hovered: Bool
  let store: AppStore
  @Environment(\.themeTokens) private var tokens
  @State private var lastClick: Date?

  private var tab: TerminalTab { row.tab }
  private var indicator: PaneIndicator { tab.indicator }

  var body: some View {
    #if DEBUG
      SidebarRowPasses.openRows[.tab(tab.id, in: row.sid), default: 0] += 1
    #endif
    return HStack(spacing: Spacing.s) {
      SidebarTabIcon(glyph: tab.content.glyph ?? "terminal", tool: tab.recognizedTool)
        .frame(width: SidebarRowMetrics.caretWidth, alignment: .center)
      TabTitleReader(content: tab.content) { title in
        TerminalTitleLabel(
          title: tab.content.titleParts.omittingFolder(row.target.path), folderFont: .caption
        )
        .font(.subheadline)
        .italic(tab.isPreview)
        .foregroundStyle(
          row.hasUnread ? tokens.accent : Color.primary,
          row.hasUnread ? tokens.accent.opacity(0.7) : Color.secondary
        )
        .lineLimit(1)
        .truncationMode(.middle)
      }
      if row.hasDiagnosis {
        Text("✦")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(tokens.accent)
          .help("A coding agent has a diagnosis for this tab")
          .accessibilityLabel("diagnosis available")
      }
      Spacer(minLength: 0)
      SidebarHoverTrailing(hovered: hovered) {
        SidebarUnreadDot(source: .tab(tab.id))
        statusMark
      } buttons: {
        TabTitleReader(content: tab.content) { title in
          CloseTerminalRowButton(
            title: title, visible: true, id: "sidebar.open.closeTab.\(tab.id)"
          ) { store.requestCloseTerminalTab(tab.id, for: row.target) }
        }
      }
    }
    // One step in from its workroom's row, as a tree row's terminals are.
    .padding(.leading, Spacing.m)
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
    .onTapGesture { click() }
    .tabChipContextMenu(tab: tab, target: row.target, host: store, panes: store.terminals)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(row.isFocused ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { store.selectOpenTab(tab.id, in: row.sid) }
    .withTabTitle(tab.content) { view, title in
      view
        .accessibilityLabel(accessibilityLabel(title))
        .accessibilityIdentifier("sidebar.open.tab.\(tab.id)")
        .help(title)
    }
  }

  /// Selects it on the first click; a quick second one keeps a preview, as on the strip.
  private func click() {
    let now = Date()
    store.selectOpenTab(tab.id, in: row.sid)
    if let lastClick, now.timeIntervalSince(lastClick) < 0.35 {
      store.promoteOpenTab(tab.id, in: row.sid)
      self.lastClick = nil
    } else {
      lastClick = now
    }
  }

  @ViewBuilder private var statusMark: some View {
    if let runState = row.runState {
      runStateMark(runState)
    } else if indicator == .blocked || indicator == .done {
      let blocked = indicator == .blocked
      ProgramStatusGlyph(
        mark: blocked ? .blocked : .done, stale: tab.programStatus?.stale == true
      )
      .help(blocked ? "Waiting for you" : ProgramStatusPresentation.turnFinished)
      .accessibilityHidden(true)
    } else if case .running(let failed) = indicator {
      RunningSpinner(failed: failed)
        .help(failed ? "A command reported an error" : "A command is running")
    } else if indicator == .error {
      RunningSpinner(failed: true).help("A command reported an error")
    }
  }

  @ViewBuilder private func runStateMark(_ state: TabRunState) -> some View {
    switch state {
    case .running:
      Image(systemName: "play.circle.fill").font(.system(size: 10))
        .foregroundStyle(tokens.success).help("Run command running")
    case .stopping:
      Image(systemName: "stop.circle").font(.system(size: 10))
        .foregroundStyle(.secondary).help("Run command stopping")
    case .failed:
      Image(systemName: "xmark.octagon.fill").font(.system(size: 10))
        .foregroundStyle(tokens.failure).help("Run command failed")
    case .stopped:
      Image(systemName: "stop.circle").font(.system(size: 10))
        .foregroundStyle(.tertiary).help("Run command stopped")
    }
  }

  private func accessibilityLabel(_ title: String) -> String {
    var parts = [title]
    if tab.isPreview { parts.append("preview") }
    if row.hasDiagnosis { parts.append("diagnosis available") }
    if let runState = row.runState { parts.append("run \(runState)") }
    parts += ProgramStatusPresentation.accessibilityParts(
      indicator: indicator, rollup: tab.programStatus)
    if row.hasUnread { parts.append("unread activity") }
    if row.isVisibleInSplit { parts.append("on screen in a split") }
    return parts.joined(separator: ", ")
  }
}

/// A workroom row redraws only when what it draws changes: the list rebuilds every row from
/// `openSectionRows()` whenever any of them changes, as one agent starting or stopping does.
extension SidebarOpenWorkroomRow: Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    MainActor.assumeIsolated {
      lhs.store === rhs.store && lhs.hovered == rhs.hovered && lhs.row.sid == rhs.row.sid
        && lhs.row.target == rhs.row.target && lhs.row.presentation == rhs.row.presentation
        && lhs.row.marks == rhs.row.marks && lhs.row.isSelected == rhs.row.isSelected
        && lhs.row.isVisibleInSplit == rhs.row.isVisibleInSplit
        && lhs.row.isFolded == rhs.row.isFolded && lhs.row.tabs.count == rhs.row.tabs.count
    }
  }
}
