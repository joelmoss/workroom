import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import WorkroomDomain
import os

/// The sidebar: a collapsible tree with projects at the root and their workrooms nested
/// one level below, each of which can reveal its terminals one level deeper. Selecting a
/// workroom (or a project root) opens its terminal in the detail pane; selecting a project
/// makes it the target for "New Workroom". Projects disclose via a chevron after their name; roots
/// and workrooms carry their terminal-disclosure chevron in a shared leading column (shown only at
/// ≥2 terminals) that lines up with the terminal rows' glyphs.
///
/// The tree reads only its structure: the projects, which are collapsed, which roots are missing
/// (`ProjectStore.missingRoots`, so no pass `stat`s a folder) and the creates without a row yet.
/// Each row is built by its own adapter behind an equality gate (`SidebarRowAdapters`), so a pass
/// of the tree re-runs no row whose inputs are unchanged, and the sidebar is gated on its drag
/// plumbing, so a pass of the view that holds it re-runs no tree.
struct ProjectSidebar: View, Equatable {
  static let signposter = OSSignposter(
    subsystem: "com.developwithstyle.workroom", category: "Sidebar")
  #if DEBUG
    /// Project, root and workroom row bodies, together (`SidebarBenchmarkTests`); terminal rows are
    /// counted only in `SidebarRowPasses`.
    static var rowEvaluations = 0
    static var menuEvaluations = 0
    static var didRenderHover: ((SidebarID, Binding<Bool>) -> Void)?
    /// The Open section's rows' hover, by row: kept apart from `didRenderHover`, whose ids a
    /// project's root and workroom rows share with their Open rows.
    static var didRenderOpenHover: ((OpenSectionItem, Binding<Bool>) -> Void)?
  #endif
  @EnvironmentObject var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Live drag of a root/workroom row into the detail content to form a workroom split (issue
  /// #101). The default makes the gesture an inert no-op for previews / any host that doesn't wire
  /// it.
  var drag: SidebarDragPlumbing = .inert

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.drag == rhs.drag }

  /// Per-level leading indent so the tree reads as a hierarchy: projects sit at `rowInsets.leading`,
  /// their root/workroom children one `levelIndent` deeper (`childRowInsets`), and a target's terminal
  /// rows deeper again — the terminal base matches its root/workroom, then the in-row `caretWidth`
  /// glyph column carries the final step (so the terminal glyph lines up under the root/workroom
  /// label). Vertical insets: 2 above and below the selectable rows, 3 for the smaller terminal
  /// rows. Every row but a project's takes its insets as padding inside itself (`sidebarRowFrame`),
  /// with none from the List, so the whole row is its hit target (#652 critique).
  static let rowInsets = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 0)
  static let childRowInsets = EdgeInsets(
    top: 2, leading: 6 + 6, bottom: 2, trailing: 0)
  static let terminalRowInsets = EdgeInsets(
    top: 3, leading: 6 + 6, bottom: 3, trailing: 0)
  /// The Open view's rows (a workroom tab's, a group's, a standalone terminal's): the view's top
  /// level, at a project row's leading inset, so each row's glyph sits under the switcher's Open
  /// glyph. A workroom tab's tabs step one level in themselves (`SidebarOpenTabRow`).
  static let sectionRowInsets = rowInsets

  var body: some View {
    // One view at a time under the switcher (ADR 0083), each its own List that scrolls itself; the
    // footer stays under both, on the sidebar's background, so neither list scrolls beneath it.
    VStack(spacing: 0) {
      SidebarViewSwitcher(store: store)
        // Air between the switcher's hairline and the first row.
        .padding(.bottom, Spacing.m)
      selectedView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(SidebarEnvironment(store: store))
      footer
    }
    // A project's settings (issue #7) open in Settings ▸ Projects through
    // `store.modals.pendingProjectSettings`, which ⌘R (a global shortcut) sets too (issue #127).
    // The add-project importer and the delete confirmation are re-homed to RootView (issue #23 OV1)
    // so the ⌘O / ⌘⌫ menu commands present reliably even when this sidebar is collapsed in
    // Workrooms View. Local buttons here route through `store.modals` (`requestAddProject` /
    // `pendingDeletion`).
  }

  /// The view the switcher shows, only that one mounted: a hidden List would keep re-running its
  /// rows and keep its rows' drop zones on screen. The two cross-fade briefly, not with Reduce
  /// Motion.
  private var selectedView: some View {
    ZStack {
      switch store.sidebarView {
      case .open:
        SidebarOpenList(store: store, drag: drag).equatable()
          .transition(.opacity)
      case .projects:
        SidebarProjectsList(drag: drag).equatable()
          .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: store.sidebarView)
  }

  // MARK: Chrome

  /// The notification band, under a hairline, on the sidebar's background.
  private var footer: some View { SidebarFooter() }
}

/// The window's environment, handed to the sidebar's views whatever hosts them: the edge-reveal
/// panel and a test's window inject only some of it. The objects are the store's own, so the
/// sidebar subscribes to none of them here.
private struct SidebarEnvironment: ViewModifier {
  let store: AppStore

  func body(content: Content) -> some View {
    content
      .environmentObject(store)
      .paneHost(store)
      .environmentObject(store.modals)
      .environmentObject(store.runCommand)
      .environmentObject(store.runCommands)
      .environmentObject(store.projectStore)
      .environmentObject(store.vcsStatus)
      .environmentObject(store.lifecycle)
      .environmentObject(store.notifications)
      .environmentObject(store.terminals.codingAgentManager)
      .environmentObject(store.remoteState)
  }
}

/// The sidebar's Projects view (ADR 0083): projects at the root, their root + workrooms when
/// expanded, then their terminals; with no projects, a prompt to add one. All rows are flush; the
/// hierarchy is conveyed by each row's icons/buttons (project chevron, root house, workroom caret,
/// terminal glyph), not indentation. A flat structure also keeps List selection and keyboard
/// navigation simple across the levels. Gated on its drag plumbing, as the sidebar is.
struct SidebarProjectsList: View, Equatable {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var projectStore: ProjectStore
  @EnvironmentObject var lifecycle: WorkroomLifecycle
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var drag: SidebarDragPlumbing = .inert

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.drag == rhs.drag }

  private static var rowInsets: EdgeInsets { ProjectSidebar.rowInsets }
  private static var childRowInsets: EdgeInsets { ProjectSidebar.childRowInsets }

  var body: some View {
    if projectStore.projects.isEmpty {
      // The switcher stays over it, so Open is a click away.
      ContentUnavailableView {
        Label("No projects yet", systemImage: "folder.badge.plus")
      } description: {
        Text("Add your first project!")
      } actions: {
        Button("Add Project…") { store.modals.requestAddProject = true }
          .buttonStyle(.borderedProminent)
          .help("Add a folder or clone a repository as a project")
      }
      .frame(maxHeight: .infinity)
    } else {
      tree
    }
  }

  private var tree: some View {
    let interval = ProjectSidebar.signposter.beginInterval("Sidebar tree")
    defer { ProjectSidebar.signposter.endInterval("Sidebar tree", interval) }
    #if DEBUG
      SidebarRowPasses.tree += 1
    #endif
    let actions = SidebarActions.live(store: store)
    return List {
      ForEach(projectStore.projects) { project in
        SidebarHoverRegion(id: .project(project.path)) { hovered in
          SidebarProjectRowAdapter(project: project, hovered: hovered, actions: actions)
            .equatable()
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(
              RowHighlight(
                selected: false, hovered: hovered,
                horizontalPadding: SidebarRowMetrics.listContentInset))
        }
        if isExpanded(project.path) {
          // The root is always the first child, before any workrooms; each selectable row is
          // followed by its terminal subtree (rendered only when expanded with ≥2 terminals).
          let rid = SidebarID.root(project: project.path)
          SidebarHoverRegion(id: rid) { hovered in
            SidebarRootRowAdapter(
              projectPath: project.path, projectName: project.displayName, hovered: hovered,
              drag: drag, actions: actions
            )
            .equatable()
            .paneDropZone(.target(rid), store: store)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(SidebarRowBackground(store: store, id: rid, hovered: hovered))
          }
          SidebarTerminalSubtree(
            target: projectStore.rootTarget(path: project.path, name: project.displayName),
            parent: rid, actions: actions)
          ForEach(project.workrooms) { workroom in
            let wid = SidebarID.workroom(project: project.path, name: workroom.name)
            SidebarHoverRegion(id: wid) { hovered in
              SidebarWorkroomRowAdapter(
                workroom: workroom, projectPath: project.path, hovered: hovered, drag: drag,
                actions: actions
              )
              .equatable()
              .paneDropZone(.target(wid), store: store)
              .listRowInsets(EdgeInsets())
              .listRowSeparator(.hidden)
              .listRowBackground(SidebarRowBackground(store: store, id: wid, hovered: hovered))
            }
            SidebarTerminalSubtree(
              target: workroom.target(inProject: project.path), parent: wid, actions: actions)
          }
          // A create with no workroom row yet (R5): before its name lands, or after a failed remote
          // create dropped its record.
          ForEach(lifecycle.provisionalCreationRows(inProject: project.path)) { row in
            provisionalCreationRow(row, actions: actions)
              .listRowInsets(EdgeInsets())
              .listRowSeparator(.hidden)
              .listRowBackground(SidebarRowBackground(store: store, id: row.id, hovered: false))
          }
        }
      }
    }
    .sidebarListStyle()
    .background(SidebarOverlayScrollers())
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.collapsedProjects)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.expandedTerminalTargets)
  }

  /// A create's provisional row (R5, design D18): "New workroom · <destination>", with its step
  /// circle. Selecting it shows the create's pane in this window. It has no menu: there is nothing
  /// to label, open or delete yet.
  private func provisionalCreationRow(
    _ row: WorkroomLifecycle.ProvisionalCreationRow, actions: SidebarActions
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "cube")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
      Text(row.label).font(.callout).lineLimit(1).truncationMode(.tail)
      Spacer()
      SidebarHoverTrailing {
        if let run = lifecycle.creationRun(for: row.id) { CreateStepCircle(run: run) }
      }
    }
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .sidebarRowFrame(ProjectSidebar.childRowInsets)
    .onTapGesture { actions.select(row.id) }
    .help(row.label)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.creation.\(row.label)")
  }

  // MARK: Expansion

  private func isExpanded(_ path: String) -> Bool { !store.collapsedProjects.contains(path) }
}

extension View {
  /// A sidebar view's `List`. Plain style (not the NavigationSplitView sidebar default): the
  /// `.sidebar` style forces a comfortable ~28pt row-height floor and ignores small `listRowInsets` +
  /// `defaultMinListRowHeight`, so the compact terminal rows couldn't shrink. Plain sizes each row by
  /// its content + insets. Selection/hover are already hand-rolled via `listRowBackground`, so no
  /// native sidebar styling is lost. Its own background is hidden so the `sidebarCard` (applied at
  /// the use site, for both the docked column and the edge-reveal panel) shows through, so pinned
  /// and unpinned share one card style.
  func sidebarListStyle() -> some View {
    listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 1)
  }
}

#if DEBUG
  /// How many times each kind of sidebar row's body has run, read by the sidebar's invalidation
  /// tests: which rows a change re-runs, by kind and by row, and which of the leaves that keep the
  /// fast-changing reads out of the rows re-ran in their place; and, for the changes a row must
  /// show, what it last drew.
  @MainActor enum SidebarRowPasses {
    /// Passes of the tree itself, which builds the rows' adapters; not a row, so not in `total`.
    static var tree = 0
    static var project = 0
    static var root = 0
    static var workroom = 0
    static var terminal = 0
    /// Project, root, workroom, standalone terminal and terminal group rows, by id.
    static var byRow: [SidebarID: Int] = [:]
    static var runButton = 0
    static var background = 0
    static var dragDim = 0
    static var rootLabel = 0
    /// Whether each root and workroom row last drew its folder as missing, by id.
    static var folderMissing: [SidebarID: Bool] = [:]
    /// The name each workroom row last drew, by id.
    static var workroomTitles: [SidebarID: String] = [:]
    static var unreadDot = 0
    /// What each create's step circle last drew, by run: `progress`, `failed` or `done`.
    static var createSteps: [UUID: String] = [:]
    /// The title each terminal row last drew, by tab.
    static var terminalTitles: [TerminalTab.ID: String] = [:]
    /// The fill each terminal row's background last drew, by tab.
    static var terminalFills: [TerminalTab.ID: Color] = [:]
    /// The Open section's workroom and tab rows (#819), by row. Not in `byRow` or `total`: a
    /// project's root and workroom rows share their ids with their Open rows.
    static var openRows: [OpenSectionItem: Int] = [:]

    static var total: Int { project + root + workroom + terminal }

    static func reset() {
      tree = 0
      project = 0
      root = 0
      workroom = 0
      terminal = 0
      byRow = [:]
      runButton = 0
      background = 0
      dragDim = 0
      rootLabel = 0
      folderMissing = [:]
      workroomTitles = [:]
      unreadDot = 0
      createSteps = [:]
      terminalTitles = [:]
      terminalFills = [:]
      openRows = [:]
    }
  }
#endif

/// Hover belongs to a row: changing it must not invalidate the sidebar's List (#534).
struct SidebarHoverRegion<Content: View>: View {
  var id: SidebarID? = nil
  /// An Open section row's, for `ProjectSidebar.didRenderOpenHover`.
  var openItem: OpenSectionItem? = nil
  @ViewBuilder let content: (Bool) -> Content
  @State private var hovered = false

  var body: some View {
    #if DEBUG
      if let id { ProjectSidebar.didRenderHover?(id, $hovered) }
      if let openItem { ProjectSidebar.didRenderOpenHover?(openItem, $hovered) }
    #endif
    return content(hovered).sidebarRowHover($hovered)
  }
}

extension View {
  /// A sidebar row's hover, kept in `hovered`: set on every pointer move over it, not only on
  /// entry, and dropped when the row itself moves. A row that slides in or out under a still
  /// pointer (another row expanding or collapsing) is told the pointer entered and never that it
  /// left, so it lets go as it moves, and takes the hover back on the pointer's next move if it is
  /// under it. A row that stays put, such as the one just clicked to expand, keeps its hover.
  func sidebarRowHover(_ hovered: Binding<Bool>) -> some View {
    onContinuousHover { phase in
      switch phase {
      case .active: if !hovered.wrappedValue { hovered.wrappedValue = true }
      case .ended: if hovered.wrappedValue { hovered.wrappedValue = false }
      }
    }
    .background {
      // Measured from behind the row rather than with `onGeometryChange` on it, which hides the
      // List row's own background (`listRowBackground`) set inside it.
      GeometryReader { proxy in
        Color.clear.onChange(of: proxy.frame(in: .global)) {
          if hovered.wrappedValue { hovered.wrappedValue = false }
        }
      }
    }
  }
}

/// The terminal rows for a target, shown only when it has ≥2 terminals and the user has expanded
/// its disclosure (issue #30). One row per tab, in the same display order as the detail-pane strip.
/// A view of its own so the tab list and the expansion are read here: an agent working in a target
/// re-runs that target's subtree, not the tree. Equatable, which SwiftUI uses on its own for a view
/// holding closures; not behind `.equatable()`, whose wrapper would make even an empty subtree a
/// List row. `==` leaves out `actions`, whose closures act on the ids they are handed, and the
/// theme, which it reads from the environment: a theme switch re-runs it whatever `==` says.
private struct SidebarTerminalSubtree: View, Equatable {
  @EnvironmentObject private var store: AppStore
  @Environment(\.themeTokens) private var tokens
  let target: TerminalTarget
  let parent: SidebarID
  let actions: SidebarActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.target == rhs.target && lhs.parent == rhs.parent
  }

  var body: some View {
    let tabIDs = store.terminals.tabs(for: target).map(\.id)
    if tabIDs.count >= 2, store.isTerminalsExpanded(target.id) {
      ForEach(tabIDs, id: \.self) { tabID in
        SidebarHoverRegion { hovered in
          SidebarTerminalRowAdapter(
            tabID: tabID, target: target, parent: parent, hovered: hovered, actions: actions
          )
          .equatable()
          // A terminal let go on it lands in this workroom just above it; dragged, it is that
          // terminal (#652, `TerminalDragSession`).
          .paneDropZone(.terminalRow(tabID, in: parent), store: store)
          .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
              .onChanged { [store, tabID, parent] _ in
                store.terminalDrag.moved(
                  .terminal(tabID, of: parent), from: .sidebar, to: NSEvent.mouseLocation)
              }
              .onEnded { [store] _ in store.terminalDrag.ended(at: NSEvent.mouseLocation) }
          )
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(
            SidebarTerminalRowBackground(
              store: store, tokens: tokens, tabID: tabID, target: target, parent: parent,
              hovered: hovered))
        }
      }
    }
  }
}

/// The sidebar's footer: the oldest notification, as a card under the lists; nothing while there
/// are none. No band or hairline of its own: the card is its edge.
private struct SidebarFooter: View {
  var body: some View { SidebarNotificationStrip() }
}

/// A sidebar row's icon button in the rows' trailing column (`SidebarRowMetrics.iconColumnWidth`):
/// the switcher's "+" in the Projects view and a terminal group's row's. Hover paints the same rounded well as a terminal disclosure chevron's.
struct SidebarIconButton: View {
  let systemImage: String
  let help: String
  var label: String? = nil
  let id: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      SidebarIconGlyph(systemImage: systemImage, hovering: hovering)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(label ?? help)
    .accessibilityIdentifier(id)
  }
}

/// What every sidebar icon button draws: its glyph centred in the trailing column's square slot,
/// over a rounded hover well while `hovering`. `CreateRowButton`, a menu, draws it too.
struct SidebarIconGlyph: View {
  let systemImage: String
  let hovering: Bool
  var font: Font = .system(size: 11)
  @Environment(\.themeTokens) private var tokens
  @Environment(\.sidebarHoverReveal) private var reveal

  var body: some View {
    // Faded by `reveal` through its colours, not `.opacity`: a menu whose whole label is fully
    // transparent leaves accessibility at rest, and `CreateRowButton`'s "+" must stay in it.
    Image(systemName: systemImage)
      .font(font)
      .foregroundStyle(.secondary.opacity(reveal))
      .frame(
        width: SidebarRowMetrics.iconColumnWidth, height: SidebarRowMetrics.iconColumnWidth
      )
      .background {
        RoundedRectangle(cornerRadius: Radius.xs)
          .fill(tokens.hover.opacity(hovering ? reveal : 0))
          .frame(width: SidebarRowMetrics.hoverWell, height: SidebarRowMetrics.hoverWell)
      }
      .contentShape(Rectangle())
  }
}

/// Notifications invalidate badge views, not the project/workroom row tree (#534).
struct SidebarUnreadDot: View {
  enum Source {
    case project(Project)
    case target(TerminalTarget.ID)
    case tab(TerminalTab.ID)
  }

  @EnvironmentObject private var notifications: NotificationCenterStore
  let source: Source

  var body: some View {
    #if DEBUG
      let _ = { SidebarRowPasses.unreadDot += 1 }()
    #endif
    UnreadDot(count: count)
  }

  private var count: Int {
    switch source {
    case .project(let project):
      var total = notifications.count(target: TargetID.root(project: project.path))
      for workroom in project.workrooms {
        total += notifications.count(
          target: TargetID.workroom(project: project.path, name: workroom.name))
      }
      return total
    case .target(let target): return notifications.count(target: target)
    case .tab(let tab): return notifications.count(tab: tab)
    }
  }
}

/// Only the glyph needs the VCS dictionary. Reading it in the row builder made every sweep rebuild
/// the entire List, including offscreen rows and unrelated notification badges (#534).
struct SidebarStatusGlyph: View {
  @EnvironmentObject private var vcsStatus: VCSStatusService
  @Environment(\.themeTokens) private var tokens
  let id: SidebarID
  let symbol: String

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 10))
      .foregroundStyle(
        VCSStatusPresentation.iconTint(vcsStatus.workroomStatuses[id] ?? .unresolved, tokens))
  }
}

/// A root row's spoken label: its branch (as `SidebarRootLabel` reads it), its VCS status and its
/// program marks.
struct SidebarRootStatusLabel: ViewModifier {
  @EnvironmentObject private var vcsStatus: VCSStatusService
  let id: SidebarID
  let projectID: Project.ID
  /// The project's folder is gone.
  let isMissing: Bool
  let programLabels: [String]

  func body(content: Content) -> some View {
    let root = vcsStatus.rootPresentation(for: projectID).accessibility
    let label =
      ([
        isMissing ? "\(root), folder not found" : root,
        VCSStatusPresentation.accessibilityLabel(vcsStatus.workroomStatuses[id] ?? .unresolved),
      ]
      + programLabels).filter { !$0.isEmpty }.joined(separator: ", ")
    return content.accessibilityLabel(label)
  }
}

struct SidebarAggregateStatus: View {
  @EnvironmentObject private var vcsStatus: VCSStatusService
  let projectPath: String

  var body: some View {
    if let status = vcsStatus.aggregateStatus(forProject: projectPath) {
      VCSAggregateDot(status: status)
    }
  }
}

/// The root row's label tint (issue #43). A detached/none root takes an explicit `.secondary`; a
/// healthy root applies NO foreground color so it keeps the inherited (vibrant) foreground and dims
/// along with the rest of the sidebar when the window is inactive — pinning any color here (including
/// `.foregroundColor(nil)`) opts the text out of that dimming and leaves it bright on blur. A
/// modifier rather than an inline `if` keeps the row's other label modifiers in one chain.
struct RootLabelTint: ViewModifier {
  let dim: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if dim { content.foregroundColor(.secondary) } else { content }
  }
}

/// The small busy mark shown on a root, workroom or terminal row while one of its terminals is
/// running a command (issue #28): the sidebar's one progress idiom, `ActivityDots`, as a create's
/// and a stopping run command's rows show it too. A command that reported OSC 9;4 ERROR shows the
/// failure mark instead, so the row reads as failed at a glance rather than as one more busy mark.
struct RunningSpinner: View {
  var failed = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    if failed {
      // The size of the program status marks beside it (`ProgramStatusGlyph`).
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 11))
        .foregroundStyle(tokens.failure)
        .help("A command reported an error")
        .accessibilityLabel("A command reported an error")
    } else {
      ActivityDots()
        .help("Running a command")
        .accessibilityLabel("Running a command")
    }
  }
}

extension RunningSpinner {
  /// The busy mark `indicator` shows on a row: dots while a command runs, the failure mark once one
  /// reported an error, else nothing. Shared by the Open section's workroom and tab rows (#819).
  @ViewBuilder static func of(_ indicator: PaneIndicator) -> some View {
    switch indicator {
    case .running(let failed): RunningSpinner(failed: failed)
    case .error: RunningSpinner(failed: true)
    case .blocked, .done, .none: EmptyView()
    }
  }
}

/// The sidebar's busy mark: three small dots that light up in turn, left to right, like a typing
/// indicator. Quieter than a system spinner, so a column of busy rows doesn't shout over their
/// names. Its square frame is the small spinner's it replaced, so no row's layout moved. One
/// repeating keyframe clock drives all three dots, so it keeps running when a `List` reuses its
/// row. With Reduce Motion it holds still, as a plain ellipsis.
struct ActivityDots: View {
  /// The dots' colour: the secondary label colour unless a row gives its own (a stopping run).
  var tint: Color? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// One full wave, slow enough to read as calm.
  nonisolated static let period: Double = 1.8
  nonisolated static let dot: CGFloat = 2.5
  nonisolated static let gap: CGFloat = 1.5
  nonisolated static let side: CGFloat = 16
  /// How far behind the previous dot each one lights, as a share of the wave.
  nonisolated static let stagger: Double = 0.125
  nonisolated static let dim: Double = 0.25

  var body: some View {
    Group {
      if reduceMotion {
        dots { _ in 0.6 }
      } else {
        KeyframeAnimator(initialValue: 0.0, repeating: true) { phase in
          dots { Self.opacity(phase: phase, index: $0) }
        } keyframes: { _ in
          LinearKeyframe(1.0, duration: Self.period)
        }
      }
    }
    .frame(width: Self.side, height: Self.side)
    .accessibilityElement()
    .accessibilityAddTraits(.updatesFrequently)
  }

  private func dots(_ opacity: @escaping (Int) -> Double) -> some View {
    HStack(spacing: Self.gap) {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .frame(width: Self.dot, height: Self.dot)
          .opacity(opacity(index))
      }
    }
    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
  }

  /// A dot's opacity at `phase` (0–1 through the wave): it eases up to full over the first 30% of
  /// its own turn, back down over the next 30%, and rests dim for the remainder.
  nonisolated static func opacity(phase: Double, index: Int) -> Double {
    var t = (phase - Double(index) * stagger).truncatingRemainder(dividingBy: 1)
    if t < 0 { t += 1 }
    let rise: Double
    switch t {
    case ..<0.3: rise = t / 0.3
    case ..<0.6: rise = 1 - (t - 0.3) / 0.3
    default: rise = 0
    }
    let eased = rise * rise * (3 - 2 * rise)
    return dim + (1 - dim) * eased
  }
}

/// How far a create has got (#356, #483), on its row: the sidebar's busy mark, with the step it is
/// on as its tooltip and its complete steps out of all of them as its spoken value, the failed mark
/// once it has failed, and nothing once it has succeeded, while its checklist waits for Done.
struct CreateStepCircle: View {
  /// Observed here: a run's steps change without the store (read through Observation) changing.
  @ObservedObject var run: CreationRun
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let step = WorkroomLifecycle.CreateStep(run)
    #if DEBUG
      let _ = {
        SidebarRowPasses.createSteps[run.id] =
          run.outcome == .succeeded ? "done" : step.failed ? "failed" : "progress"
      }()
    #endif
    if run.outcome == .succeeded {
      EmptyView()
    } else if step.failed {
      Image(systemName: "xmark.octagon.fill")
        .font(.system(size: 11))
        .foregroundStyle(tokens.failure)
        .help("Couldn't create the workroom: \(step.label) failed")
        .accessibilityLabel("Couldn't create the workroom: \(step.label) failed")
    } else {
      ActivityDots()
        .help(step.label)
        .accessibilityLabel(step.label)
        .accessibilityValue(step.fraction.formatted(.percent.precision(.fractionLength(0))))
    }
  }
}

/// The "new workroom" button on a project row: a menu of the places a workroom can go (#309),
/// revealed while the row is hovered (`SidebarHoverTrailing`), as its settings button is. Its own
/// hover paints a subtle neutral background to read as an actionable control.
struct CreateRowButton<Places: View>: View {
  let help: String
  @ViewBuilder let places: () -> Places
  @State private var hovering = false

  private var glyph: some View { SidebarIconGlyph(systemImage: "plus", hovering: hovering) }

  var body: some View {
    // A menu that looks exactly like a button: drawn by SwiftUI as a plain button, so the glyph
    // keeps its size, weight and colour, with no arrow.
    Menu(content: places) { glyph.accessibilityLabel(help) }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .onHover { hovering = $0 }
      .help(help)
      .accessibilityLabel(help)
  }
}

/// Per-row run/stop control for a root or workroom whose project has a run command (issue #7),
/// present only while its command is running. It makes that decision itself: the run states are
/// one dictionary for every target, so the row that read them re-ran on every target's run
/// starting or stopping, and now only this does.
struct RowRunButton: View {
  let target: TerminalTarget
  let projectPath: String
  /// The control's accessibility identifier, when its row gives it one.
  var identifier: String? = nil
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var runCommand: RunCommandController

  var body: some View {
    #if DEBUG
      let _ = { SidebarRowPasses.runButton += 1 }()
    #endif
    if store.canRunCommand(for: target, inProject: projectPath),
      runCommand.isRunCommandRunning(for: target.id)
    {
      if let identifier {
        RowRunToggle(target: target).accessibilityIdentifier(identifier)
      } else {
        RowRunToggle(target: target)
      }
    }
  }
}

/// `RowRunButton`'s control. Reads the run state off `RunCommandController` (green = running) and
/// toggles start/stop on click — without selecting the row. Running hovers red (the stop action);
/// stopped hovers green (the start action). A view of its own, so its hover starts unset each time
/// the control appears.
private struct RowRunToggle: View {
  let target: TerminalTarget
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var runCommand: RunCommandController
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let running = runCommand.isRunCommandRunning(for: target.id)
    let stopping = runCommand.runStates[target.id]?.isStopping == true
    // The action's color: red to stop (like delete), green to start. Drives the hover icon tint AND
    // the rounded hover background, matching the row's other buttons (new-workroom / delete).
    let tint = running ? tokens.failure : tokens.success
    Button {
      store.toggleRunCommand(for: target)
    } label: {
      Group {
        if stopping {
          ActivityDots(tint: tokens.warning)
            .frame(width: 12, height: 12)
        } else {
          Image(systemName: running ? "stop.circle.fill" : "play.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(
              running
                ? (hovering ? tokens.failure : tokens.success)
                : (hovering ? tokens.success : Color.secondary)
            )
        }
      }
      .padding(4)
      .background(
        RoundedRectangle(cornerRadius: Radius.xs)
          .fill(tint.opacity(hovering ? 0.18 : 0))
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(stopping ? "Stopping run command…" : (running ? "Stop run command" : "Start run command"))
    .accessibilityLabel(
      stopping ? "Stopping run command" : (running ? "Stop run command" : "Start run command"))
  }
}

/// The gear button on a project row, revealed on hover to the left of the new-workroom button
/// (`SidebarHoverTrailing`), opening Project Settings (issue #7). Its own hover paints a subtle
/// neutral background like the new-workroom one.
struct SettingsRowButton: View {
  let help: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      // A slot as wide as the "+" beside it, with the same hover well.
      SidebarIconGlyph(systemImage: "gearshape", hovering: hovering)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

/// The trash button revealed when a workroom row is hovered (`SidebarHoverTrailing`). Its own
/// hover paints a soft pastel-red background to flag the destructive action.
struct DeleteRowButton: View {
  let name: String
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens
  @Environment(\.sidebarHoverReveal) private var reveal

  var body: some View {
    Button(action: action) {
      Image(systemName: "trash")
        .font(.system(size: 11))
        .foregroundStyle(hovering ? tokens.failure : .secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(tokens.failure.opacity(hovering ? 0.18 : 0))
        )
        .opacity(reveal)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    // An ellipsis, as it asks before it deletes (`RootView`'s confirmation). The tooltip matches the
    // menus' item; VoiceOver keeps the name, as it reads the button away from its row.
    .help("Delete Workroom…")
    .accessibilityLabel("Delete \(name)…")
  }
}

/// A sidebar row's expand/collapse chevron: one right-pointing chevron that turns to point down as
/// its row expands, and fades in while `visible` (its row hovered), both with the sidebar's hover
/// ease (`SidebarAnimated`).
struct SidebarDisclosureChevron: View {
  let expanded: Bool
  var visible = true
  var weight: Font.Weight = .regular

  var body: some View {
    SidebarAnimated(target: expanded) { turn in
      SidebarAnimated(target: visible) { shown in
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: weight))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(90 * turn))
          .opacity(shown)
      }
    }
  }
}

/// The terminal-subtree disclosure chevron on a root/workroom row (issue #30). Hover paints a subtle
/// rounded background — the same idiom as the row's other inline buttons (new-workroom, delete). The
/// chevron itself stays at the shared caret-column width, leading-aligned, so it keeps lining up with
/// the terminal rows' glyphs; the hover fill is a non-layout background that can't shift it.
struct TerminalDisclosureButton: View {
  let expanded: Bool
  let width: CGFloat
  /// Its tooltip and VoiceOver name; a workroom row's say "Show terminals" / "Hide terminals".
  var help: String? = nil
  var label: String? = nil
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button(action: action) {
      // Centred in the caret slot, so it turns about the slot's centre and the hover fill (also
      // centred on the slot) sits symmetrically around it. The terminal-row glyph centres in the
      // same slot, so the two share one vertical axis.
      SidebarDisclosureChevron(expanded: expanded)
        .frame(width: width, height: 18, alignment: .center)
        .background {
          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(tokens.hover.opacity(hovering ? 1 : 0))
            .frame(width: 18, height: 18)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help ?? defaultTitle)
    .accessibilityLabel(label ?? defaultTitle)
  }

  private var defaultTitle: String { expanded ? "Hide terminals" : "Show terminals" }
}

/// The ✕ revealed when a terminal row is hovered (issue #30). Mirrors `DeleteRowButton`'s
/// reveal-on-hover layout, but neutral rather than red — closing a terminal is gated by the same
/// confirmation as ⌘W (`requestCloseTerminalTab`), not the harder workroom deletion.
struct CloseTerminalRowButton: View {
  let title: String
  let visible: Bool
  /// Its tooltip; "Close <title>" when nil.
  var help: String? = nil
  var id: String? = nil
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      // In the rows' trailing column, as every sidebar "+" is (`SidebarIconGlyph`).
      SidebarIconGlyph(
        systemImage: "xmark", hovering: hovering, font: .system(size: 10, weight: .medium))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help ?? "Close \(title)")
    .accessibilityLabel("Close \(title)")
    .accessibilityIdentifier(id ?? "")
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }
}
