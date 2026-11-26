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

/// The switcher's "+" in the Open view (ADR 0083): every way to open something, each item with its
/// shortcut.
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
    .accessibilityIdentifier("sidebar.add")
  }
}

/// The sidebar's Open view (#819, ADR 0082, ADR 0083): this
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

  /// One List row: a workroom tab's own (`tab` nil), or one of its tabs.
  struct Entry: Identifiable {
    let id: OpenSectionItem
    let row: OpenSectionRow
    let tab: OpenSectionTabRow?
  }

  /// `items(of:)`'s rows with what each draws.
  static func entries(of rows: [OpenSectionRow]) -> [Entry] {
    rows.flatMap { row -> [Entry] in
      [Entry(id: .workroom(row.sid), row: row, tab: nil)]
        + (row.isFolded
          ? [] : row.tabs.map { Entry(id: .tab($0.tab.id, in: row.sid), row: row, tab: $0) })
    }
  }

  var body: some View {
    let rows = store.openSectionRows()
    let items = Self.items(of: rows)
    return ScrollViewReader { proxy in
      List {
        if rows.isEmpty {
          emptyState
        }
        // One element per List row: a ForEach whose element yields a varying number of rows (a
        // workroom's row and its tabs) can't be diffed, so the List reloads whole as one unfolds.
        ForEach(Self.entries(of: rows)) { entry in
          if let tab = entry.tab {
            tabRow(tab, in: entry.row, items: items)
          } else {
            workroomRow(entry.row, items: items)
          }
        }
      }
      .sidebarListStyle()
      .background(SidebarOverlayScrollers())
      .animation(rowAnimation, value: items)
      .onChange(of: Self.scrollTarget(of: rows)) { _, target in
        guard let target else { return }
        withAnimation(rowAnimation) { proxy.scrollTo(target) }
      }
      // Shown again by the switcher, the List starts at its top: bring the selection into view,
      // with no animation, as it appears.
      .onAppear {
        if let target = Self.scrollTarget(of: rows) { proxy.scrollTo(target) }
      }
    }
  }

  /// How the rows move as they reorder, fold or scroll: none with Reduce Motion.
  private var rowAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.2) }

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
      .font(FontRole.body)
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
    let edge = insertionEdge(of: item, in: items)
    return SidebarHoverRegion(openItem: item) { hovered in
      SidebarOpenWorkroomRow(row: row.model, hovered: hovered, store: store).equatable()
        .modifier(SidebarDragDim(id: row.sid, drag: drag.drag))
        .overlay(alignment: edge ?? .top) {
          if edge != nil { DropInsertionMark(vertical: false) }
        }
        .paneDropZone(.target(row.sid), store: store)
        // Not while its name edits in place: a drag in the field selects its text.
        .simultaneousGesture(
          workroomDrag(row, offset: offset, items: items),
          including: store.sidebarRename.editing == row.sid ? .subviews : .all
        )
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
    let edge = insertionEdge(of: item, in: items)
    return SidebarHoverRegion(openItem: item) { hovered in
      SidebarOpenTabRow(row: tab.model, tab: tab.tab, hovered: hovered, store: store).equatable()
        .overlay(alignment: edge ?? .top) {
          if edge != nil { DropInsertionMark(vertical: false) }
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

  /// A row's drag, followed to its release by `OpenRowDrag`: the List's table takes the mouse from
  /// the row's own gesture, so it reports from the press and `OpenRowDrag` decides when it is a
  /// drag (`OpenRowDrag.threshold`).
  private func followedDrag(
    _ item: OpenSectionItem, onMove: @escaping (OpenRowDrag.Report) -> Void,
    onEnd: @escaping (OpenRowDrag.Report) -> Void
  ) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { value in
        OpenRowDrag.shared.changed(
          item, location: value.location, startLocation: value.startLocation, onMove: onMove,
          onEnd: onEnd)
      }
      .onEnded { _ in OpenRowDrag.shared.ended(item) }
  }

  /// A workroom row's drag, as its title-bar chip's: onto a tab, row or title bar that takes its
  /// terminals (a standalone terminal's or group's, `TerminalDragSession`), into the content for a
  /// workroom split (`SidebarDragPlumbing`), out of the window into another or a new one
  /// (`WorkroomWindowDrag`), else a reorder of the workroom tabs.
  private func workroomDrag(
    _ row: OpenSectionRow, offset: Int, items: [OpenSectionItem]
  ) -> some Gesture {
    let actions = SidebarActions.live(store: store)
    // Its ghost follows the pointer anywhere in the window, as the chip's own drag does in the
    // title bar: no List drag image draws it.
    let ghostTitle = store.ghostTitle(of: .entry(row.sid))
    return followedDrag(.workroom(row.sid)) { [store, drag] report in
      let overTerminalDrop = store.terminalDrag.moved(
        .entry(row.sid), from: .sidebar, to: report.screen)
      drag.splitMoved(row.sid, to: report.location, ghostTitle: ghostTitle)
      // Out of the window: into another window, or a new one, as its chip goes (#444).
      if isDragOutsideWindow(report.location) {
        reorder = nil
        if overTerminalDrop { return WorkroomWindowDrag.cancel() }
        return WorkroomWindowDrag.update(
          store: store, sid: row.sid, target: row.target,
          width: store.workroomTabFrames[row.sid]?.width ?? 0)
      }
      WorkroomWindowDrag.cancel()
      let inContent = drag.drag.wrappedValue != nil
      reorder =
        overTerminalDrop || inContent
        ? nil
        : (
          .workroom(row.sid),
          OpenSectionReorder.row(
            from: offset, translation: report.translation.height, pitch: Self.rowPitch,
            count: items.count)
        )
    } onEnd: { [store, drag] report in
      let landing = reorder?.row
      reorder = nil
      // One drop: what takes its terminals, else out of the window, else a split, else a reorder.
      if store.terminalDrag.ended(at: report.screen) {
        drag.splitCancelled()
        DragGhost.shared.hide()
        return WorkroomWindowDrag.cancel()
      }
      if isDragOutsideWindow(report.location) {
        drag.splitCancelled()
        DragGhost.shared.hide()
        return WorkroomWindowDrag.end(store: store, sid: row.sid)
      }
      if drag.splitEnded(row.sid, at: report.location, actions: actions) { return }
      guard let landing,
        let index = OpenSectionReorder.workroomIndex(items, from: offset, to: landing)
      else { return }
      withAnimation(rowAnimation) {
        store.moveWorkroomTab(row.sid, toIndex: index)
      }
    }
  }

  /// A tab row's drag, as its strip chip's: onto a sidebar row, a title-bar tab, a pane tab or the
  /// Open heading (`AppStore.paneDragMoved`); out of the window it tears off; into its workroom's
  /// panes while they are on screen it splits them (`TabContentDrop`); else a reorder among its
  /// workroom's tabs.
  private func tabDrag(
    _ tab: OpenSectionTabRow, in row: OpenSectionRow, items: [OpenSectionItem]
  ) -> some Gesture {
    let item = OpenSectionItem.tab(tab.tab.id, in: row.sid)
    let index = row.tabs.firstIndex { $0.id == tab.id } ?? 0
    let panes = store.terminals
    // Kept among its own workroom's tabs; another workroom's row takes it as a drop above.
    let landing = { (translation: CGFloat) in
      OpenSectionReorder.row(
        from: index, translation: translation, pitch: Self.rowPitch, count: row.tabs.count)
    }
    let clearPreview = { panes.contentDrop(for: tab.target.id).preview = nil }
    return followedDrag(item) { [store] report in
      if isDragOutsideWindow(report.location) {
        reorder = nil
        clearPreview()
        if store.paneDragMoved(tab.tab.id, of: tab.target, to: report.screen) {
          panes.hideDragOutside()
        } else {
          panes.showDragOutside(tab.tab)
        }
        return
      }
      panes.hideDragOutside()
      if store.paneDragMoved(tab.tab.id, of: tab.target, to: report.screen) {
        reorder = nil
        clearPreview()
        return
      }
      if dragTab(tab, overContentAt: report.location) {
        reorder = nil
        return
      }
      let base = items.firstIndex(of: item).map { $0 - index } ?? 0
      reorder = (item, base + landing(report.translation.height))
    } onEnd: { [store] report in
      panes.hideDragOutside()
      reorder = nil
      if store.paneDragEnded(tab.tab.id, of: tab.target, at: report.screen) {
        return clearPreview()
      }
      if isDragOutsideWindow(report.location) {
        clearPreview()
        return panes.dropOutside(tab.tab.id, for: tab.target)
      }
      if store.onScreenTarget(forID: tab.target.id) != nil,
        panes.dropTab(tab.tab.id, of: tab.target, onContentAt: report.location)
      {
        return
      }
      clearPreview()
      let to = landing(report.translation.height)
      guard to != index else { return }
      withAnimation(rowAnimation) {
        store.moveOpenTab(tab.tab.id, toIndex: to, in: row.sid)
      }
    }
  }

  /// Previews a drop of `tab` into its workroom's panes while they are on screen and under the
  /// pointer, as its strip chip does. Returns whether it is over them.
  private func dragTab(_ tab: OpenSectionTabRow, overContentAt global: CGPoint) -> Bool {
    let panes = store.terminals
    guard store.onScreenTarget(forID: tab.target.id) != nil else {
      panes.contentDrop(for: tab.target.id).preview = nil
      return false
    }
    return panes.dragTab(tab.tab.id, of: tab.target, overContentAt: global)
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
struct SidebarOpenWorkroomRow: View, Equatable {
  let row: OpenSectionWorkroomRowModel
  let hovered: Bool
  let store: AppStore
  @Environment(\.themeTokens) private var tokens
  @State private var renaming = false
  @State private var draft = ""

  /// It redraws only when what it draws changes: the list rebuilds every row from
  /// `openSectionRows()` whenever any of them changes, as one agent starting or stopping does.
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.store === rhs.store && lhs.hovered == rhs.hovered && lhs.row == rhs.row
  }

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
    .onChange(of: renaming) { _, now in store.sidebarRename.setEditing(row.sid, now) }
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

  private var title: some View {
    WorkroomTabTitle(
      presentation: presentation, hasUnread: marks.hasUnread, folderFont: .subheadline
    )
    .font(FontRole.body)
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
      RunningSpinner.of(marks.busy)
    }
  }

  @ViewBuilder private var runMark: some View {
    if let run = marks.run { WorkroomRunMark(run: run) }
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
    if row.tabCount > 0 {
      parts.append(row.isFolded ? "\(row.tabCount) tabs, folded" : "\(row.tabCount) tabs")
    }
    return parts.joined(separator: ", ")
  }
}

/// One tab's row under its workroom in the Open section: what its strip chip shows (tool logo or
/// glyph, ✦ badge, title in italics while a preview, unread dot, waiting or finished glyph, busy
/// spinner or run state), a hover ✕ that closes it as the chip's does, and the chip's menu. A
/// second click on a preview's row keeps it, as on the chip.
struct SidebarOpenTabRow: View, Equatable {
  let row: OpenSectionTabRowModel
  /// What its title is read from, and its menu's tab. Outside the model, which compares
  /// `row.title` in its place.
  let tab: TerminalTab
  let hovered: Bool
  let store: AppStore
  @Environment(\.themeTokens) private var tokens
  @State private var lastClick: Date?

  /// It redraws only when what it draws changes, as its workroom's row does.
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.store === rhs.store && lhs.hovered == rhs.hovered && lhs.row == rhs.row
  }

  private var indicator: PaneIndicator { row.indicator }

  var body: some View {
    #if DEBUG
      SidebarRowPasses.openRows[.tab(tab.id, in: row.sid), default: 0] += 1
    #endif
    return HStack(spacing: Spacing.s) {
      SidebarTabIcon(glyph: row.glyph, tool: row.tool)
        .frame(width: SidebarRowMetrics.caretWidth, alignment: .center)
      TabTitleReader(content: tab.content) { title in
        TerminalTitleLabel(
          title: tab.content.titleParts.omittingFolder(row.target.path), folderFont: .caption
        )
        .font(.subheadline)
        .italic(row.isPreview)
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
    .modifier(SidebarOpenTabMenu(tab: tab, target: row.target, store: store))
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
    if let lastClick, now.timeIntervalSince(lastClick) < NSEvent.doubleClickInterval {
      store.promoteOpenTab(tab.id, in: row.sid)
      self.lastClick = nil
    } else {
      lastClick = now
    }
  }

  @ViewBuilder private var statusMark: some View {
    if let runState = row.runState {
      // The row's label says it, as the chip's value does.
      RunStateIcon(state: runState).accessibilityHidden(true)
    } else if indicator == .blocked || indicator == .done {
      let blocked = indicator == .blocked
      ProgramStatusGlyph(
        mark: blocked ? .blocked : .done, stale: row.programStatus?.stale == true
      )
      .help(blocked ? "Waiting for you" : ProgramStatusPresentation.turnFinished)
      .accessibilityHidden(true)
    } else {
      RunningSpinner.of(indicator)
    }
  }

  private func accessibilityLabel(_ title: String) -> String {
    var parts = [title]
    if row.isPreview { parts.append("preview") }
    if row.hasDiagnosis { parts.append("diagnosis available") }
    if let runState = row.runState { parts.append("run \(RunStateIcon.label(runState))") }
    parts += ProgramStatusPresentation.accessibilityParts(
      indicator: indicator, rollup: row.programStatus)
    if row.hasUnread { parts.append("unread activity") }
    if row.isVisibleInSplit { parts.append("on screen in a split") }
    return parts.joined(separator: ", ")
  }
}

/// A tab row's menu, its strip chip's. A modifier of its own, so the menu's reads of the panes are
/// its own and not the gated row's, and it reads the tab as it is now when the gate skipped the row.
private struct SidebarOpenTabMenu: ViewModifier {
  let tab: TerminalTab
  let target: TerminalTarget
  let store: AppStore

  func body(content: Content) -> some View {
    content.tabChipContextMenu(
      tab: store.terminals.tab(tab.id, for: target) ?? tab, target: target, host: store,
      panes: store.terminals)
  }
}
