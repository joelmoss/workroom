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
  #endif
  @EnvironmentObject var store: AppStore

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
  /// The Terminals section's rows (a group's, a standalone terminal's, a group's terminal's): the
  /// section's top level, so at a project row's leading inset, which puts each row's glyph under its
  /// heading's chevron and its title under the heading's title (`SectionHeaderMetrics`). A group's
  /// terminals step one level in themselves (`SidebarTerminalRow`).
  static let sectionRowInsets = rowInsets
  /// What a plain `List` adds above and below its rows, for sizing the Terminals pane to them.
  static let listPadding: CGFloat = 12
  /// The Terminals pane's floor: its heading and one row, the Quick Terminal's, which it always has.
  static let terminalsPaneMinHeight: CGFloat =
    SectionHeaderMetrics.height + SidebarRowMetrics.rowHeight + sectionRowInsets.top
    + sectionRowInsets.bottom + listPadding + SidebarRowMetrics.headingGap
  /// The Projects pane's floor: its heading and a few rows.
  static let projectsPaneMinHeight: CGFloat = 120
  /// The most of the sidebar the Terminals pane takes when sized to its rows.
  static let terminalsPaneCap: CGFloat = 0.4

  /// How the sidebar's split sizes its panes: the Terminals pane floored at one row and held
  /// through a window resize, so the Projects pane takes the slack; folding a pane and unfolding it
  /// returns both to where they were.
  static let splitSizing = InspectorSplitContainerController.Sizing(
    minHeights: [terminalsPaneMinHeight, projectsPaneMinHeight],
    holdingPriorities: [.defaultLow + 10, .defaultLow],
    restoresLayoutOnExpand: true,
    preferredCap: terminalsPaneCap)

  var body: some View {
    VStack(spacing: 0) {
      if !store.sidebarHasContent {
        ContentUnavailableView {
          Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
          Text("Add your first project!")
        } actions: {
          Button("Add Project…") { store.modals.requestAddProject = true }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
      } else {
        split
      }
      // Under the panes, on the sidebar's background, so neither list scrolls beneath it.
      footer
    }
    // A project's settings (issue #7) open in Settings ▸ Projects through
    // `store.modals.pendingProjectSettings`, which ⌘R (a global shortcut) sets too (issue #127).
    // The add-project importer and the delete confirmation are re-homed to RootView (issue #23 OV1)
    // so the ⌘O / ⌘⌫ menu commands present reliably even when this sidebar is collapsed in
    // Workrooms View. Local buttons here route through `store.modals` (`requestAddProject` /
    // `pendingDeletion`).
  }

  /// The Terminals and Projects sections as the inspector's panes (#652): each a sticky heading over
  /// its own scrolling list, the divider between them resizing both. Collapsing a pane folds its
  /// section (`AppStore.sidebarPanesCollapsed`). While the user hasn't dragged the divider, the
  /// Terminals pane is sized to its rows, up to `terminalsPaneCap`, and Projects takes the rest.
  private var split: some View {
    let weights = store.sidebarPaneWeights
    return InspectorSplitView(
      headers: [
        hosted(SidebarTerminalsHeader(store: store)),
        hosted(SidebarProjectsHeading(store: store)),
      ],
      bodies: [
        hosted(
          SidebarTerminalsList(
            store: store
          ).equatable()),
        hosted(SidebarProjectsList(drag: drag).equatable()),
      ],
      collapsed: store.sidebarPanesCollapsed,
      // Each pane's List scrolls itself.
      fills: [true, true],
      sectionKey: "sidebar",
      workroomKey: "sidebar",
      weights: weights,
      onWeightsChanged: { [store] in store.updateSidebarPaneWeights($0) },
      preferredHeights: weights.isEmpty
        ? [
          SectionHeaderMetrics.height
            + SidebarTerminalsList.contentHeight(of: store.terminalsSection, in: store),
          nil,
        ] : nil,
      sizing: Self.splitSizing,
      // A legacy scroller would narrow the rows but not the headings, and their "+" columns
      // would part.
      forcesOverlayScrollers: true
    )
  }

  /// A pane's view with the window's environment: a pane is hosted in AppKit, so it inherits none of
  /// it. The objects are the store's own, so this view subscribes to none of them.
  private func hosted(_ view: some View) -> AnyView {
    AnyView(
      view
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
        .environmentObject(store.remoteState))
  }

  // MARK: Chrome

  /// The notification band, under a hairline, on the sidebar's background.
  private var footer: some View { SidebarFooter() }
}

/// The Projects section's list, the sidebar's bottom pane under its sticky heading: projects at the
/// root, their root + workrooms when expanded, then their terminals. All rows are flush; the
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
    let interval = ProjectSidebar.signposter.beginInterval("Sidebar tree")
    defer { ProjectSidebar.signposter.endInterval("Sidebar tree", interval) }
    #if DEBUG
      SidebarRowPasses.tree += 1
    #endif
    let actions = SidebarActions.live(store: store)
    return List {
      SidebarHeadingGap()
      ForEach(store.projectsFolded ? [] : projectStore.projects) { project in
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
      if let run = lifecycle.creationRun(for: row.id) { CreateStepCircle(run: run) }
    }
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

/// The first row of a sidebar pane's `List`: a little air between the pane's sticky heading and
/// its first row (a List ignores `contentMargins`).
struct SidebarHeadingGap: View {
  var body: some View {
    Color.clear
      .frame(height: SidebarRowMetrics.headingGap)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .moveDisabled(true)
      .accessibilityHidden(true)
  }
}

extension View {
  /// A sidebar pane's `List`. Plain style (not the NavigationSplitView sidebar default): the
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
    /// The Terminals section's standalone terminal and terminal group rows (#652).
    static var section = 0
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

    static var total: Int { project + root + workroom + terminal + section }

    static func reset() {
      tree = 0
      project = 0
      root = 0
      workroom = 0
      terminal = 0
      section = 0
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
    }
  }
#endif

/// Hover belongs to a row: changing it must not invalidate the sidebar's List (#534).
struct SidebarHoverRegion<Content: View>: View {
  var id: SidebarID? = nil
  @ViewBuilder let content: (Bool) -> Content
  @State private var hovered = false

  var body: some View {
    #if DEBUG
      if let id { ProjectSidebar.didRenderHover?(id, $hovered) }
    #endif
    return content(hovered).onHover { hovered = $0 }
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

/// The sidebar's footer: the oldest notification, under the hairline the sidebar draws between its
/// sections; nothing while there are none.
private struct SidebarFooter: View {
  @EnvironmentObject private var notifications: NotificationCenterStore
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    VStack(spacing: 0) {
      if !notifications.items.isEmpty { tokens.border.frame(height: 1) }
      SidebarNotificationStrip()
    }
    // A band of the sidebar card: under glass the card's own tint shows through it (#730).
    .background { ChromeBackground(role: .cardBand) }
  }
}

/// "Projects", its fold chevron, which hides every project's rows, and Add Project. Its "+" routes
/// through the store's request flag, so the sheet (re-homed to RootView, issue #23 OV1) presents as
/// File ▸ New Project…'s does.
private struct SidebarProjectsHeading: View {
  let store: AppStore

  var body: some View {
    SidebarSectionHeading(
      title: "Projects",
      isFolded: Binding(
        get: { store.isCollapsed(.projects) }, set: { store.setCollapsed(.projects, $0) }),
      id: "sidebar.projects"
    ) {
      SidebarIconButton(
        systemImage: "plus", help: "Add Project…", label: "Add Project", id: "AddProject"
      ) {
        store.modals.requestAddProject = true
      }
    }
    .background(SidebarSectionHeadingBand())
  }
}

/// A sidebar row's icon button in the rows' trailing column (`SidebarRowMetrics.iconColumnWidth`):
/// the "+" on the Terminals and Projects headings and a terminal group's row, and the Terminals
/// heading's New Terminal Group…. Hover paints the same rounded well as a terminal disclosure chevron's.
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

  var body: some View {
    Image(systemName: systemImage)
      .font(font)
      .foregroundStyle(.secondary)
      .frame(
        width: SidebarRowMetrics.iconColumnWidth, height: SidebarRowMetrics.iconColumnWidth
      )
      .background {
        RoundedRectangle(cornerRadius: 5)
          .fill(tokens.hover.opacity(hovering ? 1 : 0))
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

/// The small indeterminate spinner shown on a root/workroom row while one of its terminals is
/// running a command (issue #28). Matches the project row's create/delete spinner so the sidebar
/// has one progress idiom. A command that reported OSC 9;4 ERROR shows the failure mark instead, so
/// the row reads as failed at a glance rather than as one more busy spinner.
struct RunningSpinner: View {
  var failed = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    if failed {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(tokens.failure)
        .help("A command reported an error")
        .accessibilityLabel("A command reported an error")
    } else {
      ProgressView()
        .controlSize(.small)
        .help("Running a command")
        .accessibilityLabel("Running a command")
    }
  }
}

/// How far a create has got (#356, #483), on its row: complete steps out of all of them, with the
/// step it is on as its tooltip, the failed mark once it has failed, and nothing once it has
/// succeeded, while its checklist waits for Done.
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
        .foregroundStyle(tokens.failure)
        .help("Couldn't create the workroom: \(step.label) failed")
        .accessibilityLabel("Couldn't create the workroom: \(step.label) failed")
    } else {
      ProgressView(value: step.fraction)
        .progressViewStyle(.circular)
        .controlSize(.small)
        .help(step.label)
        .accessibilityLabel(step.label)
    }
  }
}

/// The always-visible "new workroom" button on a project row: a menu of the places a workroom can
/// go (#309). Its own hover paints a subtle neutral background to read as an actionable control.
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
          ProgressView().controlSize(.mini)
            .tint(tokens.warning)
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
        RoundedRectangle(cornerRadius: 5)
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

/// The gear button on a project row, revealed on hover to the left of the new-workroom button,
/// opening Project Settings (issue #7). Laid out always (so the row size is stable) and only made
/// visible via `visible`; its own hover paints a subtle neutral background like the new-workroom one.
struct SettingsRowButton: View {
  let help: String
  let visible: Bool
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button(action: action) {
      Image(systemName: "gearshape")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }
}

/// The trash button revealed when a workroom row is hovered. It is always laid out (so
/// the row's size doesn't change on hover) and only made visible via `visible`. Its own
/// hover paints a soft pastel-red background to flag the destructive action.
struct DeleteRowButton: View {
  let name: String
  let visible: Bool
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button(action: action) {
      Image(systemName: "trash")
        .font(.system(size: 11))
        .foregroundStyle(hovering ? tokens.failure : .secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(tokens.failure.opacity(hovering ? 0.18 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    // An ellipsis, as it asks before it deletes (`RootView`'s confirmation). The tooltip matches the
    // menus' item; VoiceOver keeps the name, as it reads the button away from its row.
    .help("Delete Workroom…")
    .accessibilityLabel("Delete \(name)…")
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
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
      // Center the chevron in the caret slot. Centring pins its *center* to the slot center regardless
      // of which chevron is shown — so the glyph doesn't jump on toggle and the hover fill (also
      // centered on the slot) sits symmetrically around it. The terminal-row glyph centers in the same
      // slot, so the two share one vertical axis.
      Image(systemName: expanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: width, height: 18, alignment: .center)
        .background {
          RoundedRectangle(cornerRadius: 5)
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
