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
/// The tree reads only its structure: the projects, which are collapsed, and the creates without a
/// row yet. Each row is built by its own adapter behind an equality gate (`SidebarRowAdapters`),
/// so a pass of the tree re-runs no row whose inputs are unchanged, and the sidebar is gated on its
/// drag plumbing, so a pass of the view that holds it re-runs no tree.
struct ProjectSidebar: View, Equatable {
  private static let signposter = OSSignposter(
    subsystem: "com.developwithstyle.workroom", category: "Sidebar")
  #if DEBUG
    /// Project, root and workroom row bodies, together (`SidebarBenchmarkTests`); terminal rows are
    /// counted only in `SidebarRowPasses`.
    static var rowEvaluations = 0
    static var menuEvaluations = 0
    static var didRenderHover: ((SidebarID, Binding<Bool>) -> Void)?
  #endif
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var projectStore: ProjectStore
  @EnvironmentObject var lifecycle: WorkroomLifecycle
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens

  /// Live drag of a root/workroom row into the detail content to form a workroom split (issue #101).
  /// The default makes the gesture an inert no-op for previews / any host that doesn't wire it.
  let drag: SidebarDragPlumbing
  /// `drag`'s identity, for the gate (see `SidebarRootRow.dragToken`).
  private let dragToken: UUID

  init(drag: SidebarDragPlumbing = .inert) {
    self.drag = drag
    dragToken = drag.token
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.dragToken == rhs.dragToken }

  /// Per-level leading indent so the tree reads as a hierarchy: projects sit at `rowInsets.leading`,
  /// their root/workroom children one `levelIndent` deeper (`childRowInsets`), and a target's terminal
  /// rows deeper again — the terminal base matches its root/workroom, then the in-row `caretWidth`
  /// glyph column carries the final step (so the terminal glyph lines up under the root/workroom
  /// label). Vertical insets are unchanged: 4 for the selectable rows, a tighter 2 for the smaller
  /// terminal rows. (`6 + 12`: the base sidebar margin plus one 12pt level step.)
  fileprivate static let rowInsets = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 0)
  fileprivate static let childRowInsets = EdgeInsets(
    top: 2, leading: 6 + 6, bottom: 2, trailing: 0)
  fileprivate static let terminalRowInsets = EdgeInsets(
    top: 3, leading: 6 + 6, bottom: 3, trailing: 0)

  var body: some View {
    Group {
      if projectStore.projects.isEmpty {
        ContentUnavailableView {
          Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
          Text("Add your first project!")
        } actions: {
          Button("Add Project…") { store.modals.requestAddProject = true }
            .buttonStyle(.borderedProminent)
        }
      } else {
        tree
      }
    }
    // Reserve the footer's height so the list scrolls above its shared sidebar background.
    .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    // Breathing room above the first project so it doesn't jam against the card's top edge (the card
    // sits flush under the title bar via `SidebarColumn`'s `topMargin: 0`). A solid `safeAreaInset`
    // like the footer — reserves an 8pt strip of the card surface, matching the card's side margin.
    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 8) }
    // A project's settings (issue #7) open in Settings ▸ Projects through
    // `store.modals.pendingProjectSettings`, which ⌘R (a global shortcut) sets too (issue #127).
    // The add-project importer and the delete confirmation are re-homed to RootView (issue #23 OV1)
    // so the ⌘O / ⌘⌫ menu commands present reliably even when this sidebar is collapsed in
    // Workrooms View. Local buttons here route through `store.modals` (`requestAddProject` /
    // `pendingDeletion`).
  }

  /// Flat list of rows (project, then its root + workrooms when expanded, then their terminals). All
  /// rows are flush; the hierarchy is conveyed by each row's icons/buttons (project chevron, root
  /// house, workroom caret, terminal glyph), not indentation. A flat structure also keeps List
  /// selection and keyboard navigation simple across the levels.
  private var tree: some View {
    let interval = Self.signposter.beginInterval("Sidebar tree")
    defer { Self.signposter.endInterval("Sidebar tree", interval) }
    let actions = SidebarActions.live(store: store)
    return List {
      ForEach(projectStore.projects) { project in
        SidebarHoverRegion(id: .project(project.path)) { hovered in
          SidebarProjectRowAdapter(project: project, hovered: hovered, actions: actions)
            .equatable()
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(RowHighlight(selected: false, hovered: hovered))
        }
        if isExpanded(project.path) {
          // The root is always the first child, before any workrooms; each selectable row is
          // followed by its terminal subtree (rendered only when expanded with ≥2 terminals).
          let rid = SidebarID.root(project: project.path)
          SidebarHoverRegion(id: rid) { hovered in
            SidebarRootRowAdapter(project: project, hovered: hovered, drag: drag, actions: actions)
              .equatable()
              .listRowInsets(Self.childRowInsets)
              .listRowSeparator(.hidden)
              .listRowBackground(SidebarRowBackground(store: store, id: rid, hovered: hovered))
          }
          SidebarTerminalSubtree(target: project.rootTarget, parent: rid, actions: actions)
          ForEach(project.workrooms) { workroom in
            let wid = SidebarID.workroom(project: project.path, name: workroom.name)
            SidebarHoverRegion(id: wid) { hovered in
              SidebarWorkroomRowAdapter(
                workroom: workroom, project: project, hovered: hovered, drag: drag,
                actions: actions
              )
              .equatable()
              .listRowInsets(Self.childRowInsets)
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
              .listRowInsets(Self.childRowInsets)
              .listRowSeparator(.hidden)
              .listRowBackground(SidebarRowBackground(store: store, id: row.id, hovered: false))
          }
        }
      }
      // No trailing spacer needed: the footer is a solid `safeAreaInset` (see `body`) that reserves
      // its own height, so the list already scrolls clear of it (issue #118 feedback).
    }
    // Plain style (not the NavigationSplitView sidebar default): the `.sidebar` style forces a
    // comfortable ~28pt row-height floor and ignores small `listRowInsets` + `defaultMinListRowHeight`,
    // so the compact terminal rows couldn't shrink. Plain sizes each row by its content + insets.
    // Selection/hover are already hand-rolled via `listRowBackground`, so no native sidebar styling is
    // lost; `scrollContentBackground(.hidden)` keeps the window's sidebar material showing through.
    .listStyle(.plain)
    // Hide the List's own background so the `sidebarCard` (applied at the use site, for both the
    // docked column and the edge-reveal panel) shows through — its `tokens.bg` replaces
    // NavigationSplitView's native sidebar material, so pinned and unpinned share one card style.
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 1)
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
    .frame(height: SidebarRowMetrics.rowHeight)
    .contentShape(Rectangle())
    .onTapGesture { actions.select(row.id) }
    .help(row.label)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.creation.\(row.label)")
  }

  // MARK: Expansion

  private func isExpanded(_ path: String) -> Bool { !store.collapsedProjects.contains(path) }

  // MARK: Chrome

  /// The notification band and Add Project bar share the sidebar's background. The safe-area
  /// inset reserves their height, keeping list rows from scrolling underneath.
  private var footer: some View {
    VStack(spacing: 0) {
      tokens.border.frame(height: 1)
      SidebarNotificationStrip()
      bottomBar
    }
    .background { SidebarBackground() }
  }

  /// The sidebar's bottom bar: "Add Project" on the right.
  private var bottomBar: some View {
    HStack {
      Spacer()

      SidebarAddProjectButton()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    // The enclosing footer provides the shared sidebar background.
  }
}

#if DEBUG
  /// How many times each kind of sidebar row's body has run, read by the sidebar's invalidation
  /// tests: which rows a change re-runs, by kind and by row, and which of the leaves that keep the
  /// fast-changing reads out of the rows re-ran in their place.
  @MainActor enum SidebarRowPasses {
    static var project = 0
    static var root = 0
    static var workroom = 0
    static var terminal = 0
    /// Project, root and workroom rows, by id.
    static var byRow: [SidebarID: Int] = [:]
    static var runButton = 0
    static var background = 0
    static var dragDim = 0

    static var total: Int { project + root + workroom + terminal }

    static func reset() {
      project = 0
      root = 0
      workroom = 0
      terminal = 0
      byRow = [:]
      runButton = 0
      background = 0
      dragDim = 0
    }
  }
#endif

/// Hover belongs to a row: changing it must not invalidate the sidebar's List (#534).
private struct SidebarHoverRegion<Content: View>: View {
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
/// List row.
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
          .listRowInsets(ProjectSidebar.terminalRowInsets)
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

private struct SidebarAddProjectButton: View {
  @EnvironmentObject private var store: AppStore
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    // Add Project, bottom-right. No key equivalent — File ▸ New Project… lost ⌘O to Open Workroom…
    // (issue #94). Routes through the store's request flag so the importer (re-homed to RootView,
    // issue #23 OV1) can present even when this sidebar is collapsed in Workrooms View.
    Button {
      store.modals.requestAddProject = true
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Add a project folder")
    .accessibilityLabel("Add Project")
    .accessibilityIdentifier("AddProject")
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

  var body: some View { UnreadDot(count: count) }

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

struct SidebarRootStatusLabel: ViewModifier {
  @EnvironmentObject private var vcsStatus: VCSStatusService
  let id: SidebarID
  let rootLabel: String
  let programLabels: [String]

  func body(content: Content) -> some View {
    let label =
      ([
        rootLabel,
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
  @Environment(\.themeTokens) private var tokens

  private var glyph: some View {
    Image(systemName: "plus")
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .padding(4)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(tokens.hover.opacity(hovering ? 1 : 0))
      )
  }

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
    .help(expanded ? "Hide terminals" : "Show terminals")
    .accessibilityLabel(expanded ? "Hide terminals" : "Show terminals")
  }
}

/// The ✕ revealed when a terminal row is hovered (issue #30). Mirrors `DeleteRowButton`'s
/// reveal-on-hover layout, but neutral rather than red — closing a terminal is gated by the same
/// confirmation as ⌘W (`requestCloseTerminalTab`), not the harder workroom deletion.
struct CloseTerminalRowButton: View {
  let title: String
  let visible: Bool
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Close \(title)")
    .accessibilityLabel("Close \(title)")
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }
}
