import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// One List row of the Open section (#819): a workroom tab's own row, or one of its tabs under it.
enum OpenSectionItem: Hashable {
  case workroom(SidebarID)
  case tab(TerminalTab.ID, in: SidebarID)
}

/// The switcher's "+" in the Open view (ADR 0083): a new terminal or terminal group, each item with
/// its shortcut. Opening a workroom is ⌘O's (File ▸ Open Workroom…).
struct SidebarOpenAddMenu: View {
  let store: AppStore

  var body: some View {
    CreateRowButton(help: "New terminal or terminal group") {
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
/// tabs in strip order. It keeps nothing of its own: every row reads the model and calls the
/// store, so the section, the title bar and the strip never disagree, and a row a drag lifts is
/// `OpenRowLift`'s until it lands. Its own `List`, so it scrolls on its own and keeps the selected
/// row in view.
struct SidebarOpenList: View, Equatable {
  let store: AppStore
  var drag: SidebarDragPlumbing = .inert
  /// Not Observation-tracked: held so unread, ✦, run and dirty marks re-render the rows.
  @EnvironmentObject private var notifications: NotificationCenterStore
  @EnvironmentObject private var codingAgents: TerminalCodingAgentManager
  @EnvironmentObject private var runCommand: RunCommandController
  @EnvironmentObject private var vcsStatus: VCSStatusService
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.store === rhs.store && lhs.drag == rhs.drag
  }

  /// Every row's height, its insets included: what a drag's travel is counted in.
  static var rowPitch: CGFloat {
    SidebarRowMetrics.rowHeight + ProjectSidebar.sectionRowInsets.top
      + ProjectSidebar.sectionRowInsets.bottom
  }

  /// The List's rows, top to bottom: each workroom tab's, then its tabs' while it is unfolded.
  /// `showing`: a tab lifted from outside the list, under its workroom although that is folded
  /// (its placeholder).
  static func items(of rows: [OpenSectionRow], showing: OpenSectionItem? = nil)
    -> [OpenSectionItem]
  {
    entries(of: rows, showing: showing).map(\.id)
  }

  /// One List row: a workroom tab's own (`tab` nil), or one of its tabs.
  struct Entry: Identifiable {
    let id: OpenSectionItem
    let row: OpenSectionRow
    let tab: OpenSectionTabRow?
  }

  /// `items(of:)`'s rows with what each draws.
  static func entries(of rows: [OpenSectionRow], showing: OpenSectionItem? = nil) -> [Entry] {
    rows.flatMap { row -> [Entry] in
      let tabs = row.tabs.filter { tab in
        !row.isFolded || showing == .tab(tab.tab.id, in: row.sid)
      }
      return [Entry(id: .workroom(row.sid), row: row, tab: nil)]
        + tabs.map { Entry(id: .tab($0.tab.id, in: row.sid), row: row, tab: $0) }
    }
  }

  /// `entries` in the order a lifted row's drag shows them (`OpenRowReflow.order`): the lifted
  /// row in its gap, or out of the list while the pointer is, and a lifted workroom's tabs out.
  /// A lifted tab the store has moved into another workroom while its gap holds (`OpenRowLift.land`)
  /// stays in the gap.
  static func shown(_ entries: [Entry], in reflow: OpenRowReflow?) -> [Entry] {
    guard let reflow else { return entries }
    var byID = Dictionary(entries.map { ($0.id, $0) }) { first, _ in first }
    if byID[reflow.dragged] == nil,
      let moved = entries.first(where: { isLifted($0.id, in: reflow) })
    {
      byID[reflow.dragged] = moved
    }
    let order = reflow.order
    let listed = Set(order)
    // A row the model gained since the lift shows where the model has it, after the rest.
    let gained = entries.filter {
      !listed.contains($0.id) && !reflow.hidden.contains($0.id) && !isLifted($0.id, in: reflow)
    }
    return order.compactMap { byID[$0] } + gained
  }

  /// Whether `id` is the row `reflow` lifted: it, or its tab moved into another workroom.
  static func isLifted(_ id: OpenSectionItem, in reflow: OpenRowReflow?) -> Bool {
    guard let reflow else { return false }
    if id == reflow.dragged { return true }
    guard case .tab(let tab, _) = id, case .tab(let lifted, _) = reflow.dragged else {
      return false
    }
    return tab == lifted
  }

  var body: some View {
    let rows = store.openSectionRows()
    let items = Self.items(of: rows)
    // Read here, so the list re-runs only when the gap moves, never as the pointer moves alone.
    let reflow = OpenRowLift.shared.reflow(for: store)
    let entries = Self.shown(Self.entries(of: rows, showing: reflow?.dragged), in: reflow)
    return ScrollViewReader { proxy in
      List {
        if rows.isEmpty {
          emptyState
        }
        // One element per List row: a ForEach whose element yields a varying number of rows (a
        // workroom's row and its tabs) can't be diffed, so the List reloads whole as one unfolds.
        ForEach(entries) { entry in
          let lifted = Self.isLifted(entry.id, in: reflow)
          if let tab = entry.tab {
            tabRow(tab, in: entry.row, items: items, lifted: lifted)
          } else {
            workroomRow(entry.row, items: items, lifted: lifted)
          }
        }
      }
      .sidebarListStyle()
      .background(SidebarOverlayScrollers())
      .animation(rowAnimation, value: entries.map(\.id))
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

  /// With nothing open, a link that opens a new terminal, as the "+" menu's New Terminal does.
  private var emptyState: some View {
    Button {
      store.newStandaloneTerminal()
    } label: {
      HStack(spacing: Spacing.xs) {
        Text("New Terminal")
        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
      }
      .font(FontRole.body)
      .foregroundStyle(tokens.accent)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
    .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
    .help("Open a new terminal (⌥⌘T)")
    .accessibilityIdentifier("sidebar.open.empty")
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  /// A workroom tab's row. `lifted`: a drag has lifted it, and its slot is the gap the ghost
  /// lands in (`OpenRowLift`), so it shows nothing.
  private func workroomRow(_ row: OpenSectionRow, items: [OpenSectionItem], lifted: Bool)
    -> some View
  {
    let item = OpenSectionItem.workroom(row.sid)
    return SidebarHoverRegion(openItem: item) { hovered in
      SidebarOpenWorkroomRow(row: row.model, hovered: hovered, store: store).equatable()
        .opacity(lifted ? 0 : 1)
        .paneDropZone(.target(row.sid), store: store)
        // Not while its name edits in place: a drag in the field selects its text.
        .simultaneousGesture(
          workroomDrag(row, items: items),
          including: store.sidebarRename.editing == row.sid ? .subviews : .all
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
          SidebarOpenRowBackground(
            hovered: hovered,
            // Only what has the keyboard is highlighted: the selected workroom's row while it
            // shows no tab rows, else its focused tab's.
            emphasis: row.isSelected && (row.isFolded || row.tabs.isEmpty) ? .selected : .none
          )
          .opacity(lifted ? 0 : 1))
    }
    .id(item)
  }

  /// One of a workroom's tabs' rows. `lifted`: as a workroom row's.
  private func tabRow(
    _ tab: OpenSectionTabRow, in row: OpenSectionRow, items: [OpenSectionItem], lifted: Bool
  ) -> some View {
    let item = OpenSectionItem.tab(tab.tab.id, in: row.sid)
    return SidebarHoverRegion(openItem: item) { hovered in
      SidebarOpenTabRow(row: tab.model, tab: tab.tab, hovered: hovered, store: store).equatable()
        .opacity(lifted ? 0 : 1)
        // A terminal let go on it lands in its workroom just above it (#652). A drag that lifts
        // a row opens a gap here instead, so it is a zone only for one that doesn't (a refusal,
        // or a drag from a standalone terminal's own pane), which shows the accent, not a line.
        .paneDropZone(
          .terminalRow(tab.tab.id, in: row.sid), store: store, marksInsertion: false
        )
        .simultaneousGesture(tabDrag(tab, in: row, items: items))
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
          SidebarOpenRowBackground(
            hovered: hovered,
            emphasis: tab.isFocused ? .selected : .none
          )
          .opacity(lifted ? 0 : 1))
    }
    .id(item)
  }

  // MARK: Drags

  /// A row's drag, followed to its release by `OpenRowDrag`: the List's table takes the mouse from
  /// the row's own gesture, so it reports from the press and `OpenRowDrag` decides when it is a
  /// drag (`OpenRowDrag.threshold`).
  private func followedDrag(
    _ item: OpenSectionItem, onMove: @escaping (OpenRowDrag.Report) -> Void,
    onEnd: @escaping (OpenRowDrag.Report) -> Void, onCancel: @escaping () -> Void
  ) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { value in
        OpenRowDrag.shared.changed(
          item, location: value.location, startLocation: value.startLocation, onMove: onMove,
          onEnd: onEnd, onCancel: onCancel)
      }
      .onEnded { _ in OpenRowDrag.shared.ended(item) }
  }

  /// Lifts `item`'s row, drop zone `zone`, as its drag starts: the ghost draws `row` as the row
  /// looks selected, and the row's slot becomes the gap (`OpenRowLift`). Once per drag.
  /// `leavesWorkroom`: a tab row can become a standalone terminal, so its gap opens between
  /// workrooms too (`OpenRowReflow.leavesWorkroom`).
  private func lift(
    _ item: OpenSectionItem, zone: PaneDropZone, items: [OpenSectionItem],
    report: OpenRowDrag.Report, row: some View, leavesWorkroom: () -> Bool = { false },
    joinable: () -> Set<SidebarID> = { [] }
  ) {
    let lift = OpenRowLift.shared
    guard lift.reflow(for: store)?.dragged != item || lift.geometry == nil,
      let reflow = OpenRowReflow(
        items: items, dragged: item, leavesWorkroom: leavesWorkroom(), joinable: joinable())
    else { return }
    lift.lift(
      reflow, in: store, zone: zone, report: report, content: Self.ghost(of: row, store: store))
  }

  /// The ghost of `row`, a row of `store`'s list, with the environment its own hosting view needs:
  /// the theme and every object the sidebar's rows read.
  static func ghost(of row: some View, store: AppStore) -> AnyView {
    AnyView(
      OpenRowGhostChrome(content: row)
        .environmentObject(store)
        .environmentObject(store.notifications)
        .environmentObject(store.terminals.codingAgentManager)
        .environmentObject(store.runCommand)
        .environmentObject(store.vcsStatus)
        .environmentObject(store.projectStore)
        .environmentObject(store.lifecycle)
        .environmentObject(store.modals)
        .themeTokensRoot())
  }

  /// A workroom row's drag, as its title-bar chip's: onto a tab, row or title bar that takes its
  /// terminals (a standalone terminal's or group's, `TerminalDragSession`), into the content for a
  /// workroom split (`SidebarDragPlumbing`), out of the window into another or a new one
  /// (`WorkroomWindowDrag`), else a reorder of the workroom tabs, its gap opening under the
  /// pointer as it moves (`OpenRowLift`).
  private func workroomDrag(_ row: OpenSectionRow, items: [OpenSectionItem]) -> some Gesture {
    let actions = SidebarActions.live(store: store)
    let item = OpenSectionItem.workroom(row.sid)
    let lift = OpenRowLift.shared
    return followedDrag(item) { [store, drag] report in
      self.lift(
        item, zone: .target(row.sid), items: items, report: report,
        row: SidebarOpenWorkroomRow(row: row.model, hovered: false, store: store))
      lift.follow(report)
      let overTerminalDrop = store.terminalDrag.moved(
        .entry(row.sid), from: .sidebar, to: report.screen)
      drag.splitMoved(row.sid, to: report.location, drawsGhost: false)
      lift.move(to: report.screen, holds: overTerminalDrop)
      // Out of the window: into another window, or a new one, as its chip goes (#444).
      if isDragOutsideWindow(report.location) {
        if overTerminalDrop { return WorkroomWindowDrag.cancel() }
        return WorkroomWindowDrag.update(
          store: store, sid: row.sid, target: row.target,
          width: store.workroomTabFrames[row.sid]?.width ?? 0)
      }
      WorkroomWindowDrag.cancel()
    } onEnd: { [store, drag] report in
      // One drop: what takes its terminals, else out of the window, else a split, else a reorder.
      if store.terminalDrag.ended(at: report.screen) {
        drag.splitCancelled()
        WorkroomWindowDrag.cancel()
        return lift.drop()
      }
      if isDragOutsideWindow(report.location) {
        drag.splitCancelled()
        lift.drop()
        return WorkroomWindowDrag.end(store: store, sid: row.sid)
      }
      if drag.splitEnded(row.sid, at: report.location, actions: actions) { return lift.drop() }
      // The list already shows the new order: the store takes it, and the ghost settles into it.
      if !lift.landInGap(at: report.screen, in: store) { lift.cancel() }
    } onCancel: { [store, drag] in
      store.terminalDrag.cancel()
      drag.splitCancelled()
      WorkroomWindowDrag.cancel()
      lift.cancel()
    }
  }

  /// A tab row's drag, as its strip chip's: onto a sidebar row, a title-bar tab, a pane tab or the
  /// Open tab (`AppStore.paneDragMoved`); out of the window it tears off; into its workroom's
  /// panes while they are on screen it splits them (`TabContentDrop`); else a reorder among its
  /// workroom's tabs, a join among the tabs of another that takes it, or, when it can become a
  /// standalone terminal, a standalone terminal between
  /// workrooms, its gap opening under the pointer as it moves (`OpenRowLift`, `OpenRowReflow`).
  private func tabDrag(
    _ tab: OpenSectionTabRow, in row: OpenSectionRow, items: [OpenSectionItem]
  ) -> some Gesture {
    let item = OpenSectionItem.tab(tab.tab.id, in: row.sid)
    let panes = store.terminals
    let lift = OpenRowLift.shared
    let clearPreview = { panes.contentDrop(for: tab.target.id).preview = nil }
    return followedDrag(item) { [store] report in
      self.lift(
        item, zone: .terminalRow(tab.tab.id, in: row.sid), items: items, report: report,
        row: SidebarOpenTabRow(row: tab.model, tab: tab.tab, hovered: false, store: store),
        leavesWorkroom: { store.canMoveOpenTabToStandalone(tab.tab.id, in: row.sid) },
        joinable: {
          OpenRowLift.joinable(
            tab.tab.id, of: row.sid, rows: store.openSectionRows(), store: store)
        })
      lift.follow(report)
      if isDragOutsideWindow(report.location) {
        lift.move(to: report.screen, holds: false)
        clearPreview()
        if store.paneDragMoved(tab.tab.id, of: tab.target, to: report.screen) {
          panes.hideDragOutside()
        } else {
          panes.showDragOutside(tab.tab)
        }
        return
      }
      panes.hideDragOutside()
      // Onto a row that takes it, or refuses it: that row shows it, and the gap stays.
      if store.paneDragMoved(tab.tab.id, of: tab.target, to: report.screen) {
        clearPreview()
        return lift.move(to: report.screen, holds: true)
      }
      _ = dragTab(tab, overContentAt: report.location)
      lift.move(to: report.screen, holds: false)
    } onEnd: { [store] report in
      panes.hideDragOutside()
      let refused = store.terminalDrag.refuses(at: report.screen)
      if store.paneDragEnded(tab.tab.id, of: tab.target, at: report.screen) {
        clearPreview()
        return refused ? lift.cancel() : lift.drop()
      }
      if isDragOutsideWindow(report.location) {
        clearPreview()
        lift.drop()
        return panes.dropOutside(tab.tab.id, for: tab.target)
      }
      if store.onScreenTarget(forID: tab.target.id) != nil,
        panes.dropTab(tab.tab.id, of: tab.target, onContentAt: report.location)
      {
        return lift.drop()
      }
      clearPreview()
      // A reorder, a join among another workroom's tabs or a standalone terminal between
      // workrooms, where the gap is.
      if !lift.landInGap(at: report.screen, in: store) { lift.cancel() }
    } onCancel: { [store] in
      _ = store.paneDragMoved(tab.tab.id, of: tab.target, to: nil)
      panes.hideDragOutside()
      clearPreview()
      lift.cancel()
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

/// An Open row's fill: the selection for the one row that has the keyboard (the selected
/// workroom's when it shows no tab rows, else its focused tab's), else the hover.
struct SidebarOpenRowBackground: View {
  enum Emphasis { case none, selected }
  let hovered: Bool
  let emphasis: Emphasis

  var body: some View {
    switch emphasis {
    case .selected: SidebarSelectedRowFill()
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

  /// Every row but a standalone terminal's offers a new terminal in it: a standalone terminal is
  /// one terminal.
  private var offersNewTerminal: Bool {
    if case .standalone = row.sid { return false }
    return row.target.opensTerminals
  }

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
        if offersNewTerminal {
          // A new terminal in the row's group, root or workroom, beside its ✕.
          SidebarIconButton(
            systemImage: "plus", help: "New Terminal in \(presentation.fullTitle)",
            label: "New Terminal in \(presentation.fullTitle)", id: "sidebar.open.newTerminal.\(id)"
          ) { store.newTerminalInOpenRow(row.sid) }
        }
        // Room for the ✕ the overlay draws.
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
        ? "The group's name. Leave it empty to number the group, as Group 1"
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
      // Popped out into its own window (issue #172): the mark leads the title, which goes
      // secondary.
      if row.isPoppedOut { PoppedOutMark() }
      TabTitleReader(content: tab.content) { title in
        TerminalTitleLabel(
          title: tab.content.titleParts.omittingFolder(row.target.path), folderFont: .caption
        )
        .font(.subheadline)
        .italic(row.isPreview)
        .foregroundStyle(
          row.hasUnread ? tokens.accent : (row.isPoppedOut ? Color.secondary : Color.primary),
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
    if row.isPoppedOut { parts.append(PoppedOutMark.label) }
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
