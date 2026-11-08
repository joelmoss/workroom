import DesignSystem
import SwiftUI
import TerminalModel
import WorkroomDomain

// The sidebar's four kinds of row, each a store-free view of a value model behind an equality gate.
// An adapter per row (`SidebarRowAdapters.swift`) reads the window's stores and builds the model, so
// a change re-runs the adapters that read it, and a row's body runs only when its model, its hover
// or its drag plumbing changed. What changes often and shows in one corner of a row (VCS status,
// unread counts, selection, the drag, the run) is read in a leaf of its own instead.

/// What the sidebar's rows do. Built from the window's store on each sidebar pass; every closure
/// takes the ids it acts on and captures only the store, so a row whose gate skipped still acts on
/// what it shows, never on the values of an older pass.
struct SidebarActions {
  /// Select a target (root or workroom) on tap, and follow it with the New-Workroom context
  /// project. By tap rather than the `List`'s own `selection:`: the plain list style (needed to
  /// size the compact terminal rows) draws its own full-width selection bar that would double up
  /// with the rows' rounded highlight (`SidebarRowBackground`).
  var select: @MainActor (SidebarID) -> Void
  /// Expand or collapse the project at a path.
  var toggleProject: @MainActor (String) -> Void
  /// Show or hide a target's terminal rows (issue #30).
  var toggleTerminals: @MainActor (TerminalTarget.ID) -> Void
  /// Focus the terminal that has waited longest among these targets (#358).
  var showWaiting: @MainActor ([TerminalTarget.ID]) -> Void
  var openProjectSettings: @MainActor (Project) -> Void
  /// Ask to delete the workroom a row shows (`RootView`'s confirmation).
  var deleteWorkroom: @MainActor (SidebarID) -> Void
  /// Select a terminal row's target and focus that terminal.
  var revealTerminal: @MainActor (TerminalTab.ID, SidebarID) -> Void
  var closeTerminal: @MainActor (TerminalTab.ID, TerminalTarget) -> Void
  /// Form or extend a workroom split: a row dropped beside a pane, on one of its edges.
  var insertSplit: @MainActor (SidebarID, SidebarID, PaneEdge, CGRect) -> Void

  @MainActor static func live(store: AppStore) -> SidebarActions {
    SidebarActions(
      select: { [store] id in
        store.selectedTargetID = id
        switch id {
        case .root(let path), .workroom(let path, _):
          store.selectedProjectID = path
        default:
          break
        }
      },
      // Mutating `store.collapsedProjects` re-evaluates the sidebar synchronously, so the tree
      // commits on the click; see the property's note for why a `@Default` only updated after the
      // pointer moved. The `List`'s `.animation(value: store.collapsedProjects)` animates it.
      toggleProject: { [store] path in
        if store.collapsedProjects.contains(path) {
          store.collapsedProjects.remove(path)
        } else {
          store.collapsedProjects.insert(path)
        }
      },
      toggleTerminals: { [store] id in store.toggleTerminals(for: id) },
      // Only ⇧⌘M looks further than these targets.
      showWaiting: { [store] targetIDs in
        let oldest = targetIDs.flatMap { targetID in
          store.terminals.blockedTabs(forTargetID: targetID).map { (targetID, $0.tab, $0.since) }
        }
        .min { $0.2 < $1.2 }
        guard let oldest else { return }
        store.openTerminal(targetID: oldest.0, tabID: oldest.1)
      },
      openProjectSettings: { [store] project in
        store.modals.pendingProjectSettings = PendingProjectSettings(project: project)
      },
      deleteWorkroom: { [store] id in
        guard let (workroom, project) = store.workroomAndProject(for: id) else { return }
        store.modals.pendingDeletion = PendingWorkroomDeletion(
          workroom: workroom, project: project)
      },
      revealTerminal: { [store] tabID, parent in store.revealTerminal(tabID, at: parent) },
      closeTerminal: { [store] tabID, target in store.requestCloseTerminalTab(tabID, for: target) },
      insertSplit: { [store] id, beside, edge, rect in
        store.insertWorkroomSplit(id, beside: beside, edge: edge, destinationRect: rect)
      })
  }

  /// Does nothing: for previews.
  static var inert: SidebarActions {
    SidebarActions(
      select: { _ in }, toggleProject: { _ in }, toggleTerminals: { _ in }, showWaiting: { _ in },
      openProjectSettings: { _ in }, deleteWorkroom: { _ in }, revealTerminal: { _, _ in },
      closeTerminal: { _, _ in }, insertSplit: { _, _, _, _ in })
  }
}

/// The sizes the sidebar's rows share.
enum SidebarRowMetrics {
  /// Width of the shared leading icon column on the root/workroom/terminal rows — it holds the
  /// disclosure caret (root/workroom, only at ≥2 terminals) or the terminal glyph, and is always
  /// reserved so the labels beside it line up whether or not a caret is shown.
  static let caretWidth: CGFloat = 14
  /// Fixed content height shared by the project row and its root/workroom children so every row in
  /// the tree is the same height regardless of which trailing controls (run/delete/spinner) it shows
  /// (issue: uniform row sizing). Paired with the sidebar's matching top/bottom insets. Terminal rows
  /// are a deliberately more compact tier (their own glyph + footnote) and keep their own insets.
  static let rowHeight: CGFloat = 20
}

/// What a root or workroom row's leading column shows: whether the row owns a terminal subtree
/// (≥2 terminals) and, when it does, whether that subtree is open.
struct SidebarSubtreeState: Equatable {
  var hasSubtree = false
  var expanded = false
}

/// What a target's terminals report on its root or workroom row (#358): how many wait on the user
/// (and whether one of those is on a host whose link is down), and whether one is working or
/// failed.
struct SidebarTargetActivity: Equatable {
  var waiting = 0
  var waitingStale = false
  var failed = false
  var running = false
}

// MARK: Project

struct SidebarProjectRowModel: Equatable {
  let project: Project
  let expanded: Bool
  /// How many terminals wait on the user across the project, counted only while it is collapsed,
  /// which is the only time the row shows it.
  var waiting = 0
  var waitingStale = false
}

/// A project: its name and disclosure chevron, its aggregate marks while collapsed, and its
/// settings and New Workroom buttons.
struct SidebarProjectRow: View, Equatable {
  let model: SidebarProjectRowModel
  let hovered: Bool
  let actions: SidebarActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.model == rhs.model && lhs.hovered == rhs.hovered
  }

  var body: some View {
    #if DEBUG
      let _ = {
        ProjectSidebar.rowEvaluations += 1
        SidebarRowPasses.project += 1
        SidebarRowPasses.byRow[.project(model.project.path), default: 0] += 1
      }()
    #endif
    let project = model.project
    HStack(spacing: 6) {
      // The whole caret/name area toggles expansion; clicking anywhere on it (including the
      // trailing empty space) collapses or expands the project.
      Button {
        actions.toggleProject(project.path)
      } label: {
        HStack(spacing: 6) {
          // The project chevron sits to the right of the project name — projects keep their own
          // disclosure idiom, distinct from the leading caret column the root/workroom/terminal rows
          // share. Always shown (every project has at least the root as a child).
          Text(project.displayName).font(.callout).fontWeight(.medium)
            .foregroundStyle(.secondary)
          Image(systemName: model.expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(model.expanded ? "Collapse project" : "Expand project")

      // Aggregate dot so notifications are visible even when the project is collapsed.
      SidebarUnreadDot(source: .project(project))
      // A collapsed project still says a terminal waits on you (#358), in a slot reserved while
      // collapsed so the dots beside it never move when one starts or stops waiting.
      if !model.expanded {
        ZStack {
          if model.waiting > 0 {
            NeedsYouButton(count: model.waiting, stale: model.waitingStale, showsCount: false) {
              actions.showWaiting(project.targetIDs)
            }
            .accessibilityIdentifier("sidebar.project.\(project.displayName).needsYou")
          }
        }
        .frame(width: 24)
      }
      // Aggregate VCS status (worst child) when collapsed — so collapsing a project doesn't
      // hide the command-center signal (issue #24). Only when collapsed: expanded projects show
      // each row's own dot. Visually distinct from the UnreadDot above (different concern).
      if !model.expanded {
        SidebarAggregateStatus(projectPath: project.path)
      }

      // Project settings (run command, etc.), revealed on hover to the left of the new-workroom
      // button (issue #7). Laid out always (opacity-gated) so the row size is stable.
      SettingsRowButton(
        help: "Project settings for \(project.displayName)", visible: hovered
      ) {
        actions.openProjectSettings(project)
      }
      // "+" asks where, as the context menu does (#309). A create shows its progress in its own pane
      // and row, never here (#483).
      CreateRowButton(
        help:
          "New workroom in \(project.displayName), on this Mac, in a local container or on "
          + HostKind.remoteProviders.map(\.displayName).joined(separator: " or "),
        places: { NewWorkroomPlacesMenu(project: project) }
      )
    }
    .frame(height: SidebarRowMetrics.rowHeight)
    .contentShape(Rectangle())
    .accessibilityIdentifier("sidebar.project.\(project.displayName)")
    .accessibilityActions {
      if !model.expanded, model.waiting > 0 {
        Button(ProgramStatusPresentation.showWaitingAction) {
          actions.showWaiting(project.targetIDs)
        }
      }
    }
    .contextMenu {
      SidebarProjectMenu(project: project)
    }
  }
}

// MARK: Root

struct SidebarRootRowModel: Equatable {
  let projectPath: String
  let projectName: String
  let target: TerminalTarget
  let subtree: SidebarSubtreeState
  let activity: SidebarTargetActivity

  var id: SidebarID { .root(project: projectPath) }
}

/// The always-present project-root row: the first child under each project. Reads like a workroom
/// (a leading house glyph marking it as the root, then the current branch) — so roots and
/// workrooms share one left edge. Selectable (opens a terminal at the project directory); never
/// deletable. Its branch is read by the label, the tooltip and the spoken label alone, so a branch
/// resolving re-runs no row.
struct SidebarRootRow: View, Equatable {
  let model: SidebarRootRowModel
  let hovered: Bool
  let drag: SidebarDragPlumbing
  let actions: SidebarActions
  /// `drag`'s identity, for the gate: the plumbing itself holds closures, which a nonisolated
  /// comparison can't reach.
  private let dragToken: UUID

  init(
    model: SidebarRootRowModel, hovered: Bool, drag: SidebarDragPlumbing, actions: SidebarActions
  ) {
    self.model = model
    self.hovered = hovered
    self.drag = drag
    self.actions = actions
    dragToken = drag.token
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.model == rhs.model && lhs.hovered == rhs.hovered && lhs.dragToken == rhs.dragToken
  }

  var body: some View {
    #if DEBUG
      let _ = {
        ProjectSidebar.rowEvaluations += 1
        SidebarRowPasses.root += 1
        SidebarRowPasses.byRow[model.id, default: 0] += 1
      }()
    #endif
    let id = model.id
    let target = model.target
    let activity = model.activity
    HStack(spacing: 6) {
      SidebarLeadingSlot(
        id: id, target: target, root: true, subtree: model.subtree, hovered: hovered,
        toggle: { actions.toggleTerminals(target.id) })
      SidebarRootLabel(projectID: model.projectPath)
      Spacer(minLength: 0)
      SidebarUnreadDot(source: .target(target.id))
      if target.isMissing {
        WarningGlyph()
          .help("Project folder not found")
      }
      // OSC-9;4 spinner (any terminal's agent activity), to the LEFT of the run button — mirroring
      // the workroom rows' spinner/delete-then-run order.
      // One mark (#358): waiting beats a stopped error beats running.
      if activity.waiting > 0 {
        NeedsYouButton(count: activity.waiting, stale: activity.waitingStale) {
          actions.showWaiting([target.id])
        }
        .accessibilityIdentifier("sidebar.root.\(model.projectName).needsYou")
      } else if activity.failed || activity.running {
        RunningSpinner(failed: activity.failed)
      }
      // Only an active run gets a control on the project root: click it to stop the command.
      RowRunButton(target: target, projectPath: model.projectPath)
    }.frame(height: SidebarRowMetrics.rowHeight)
      .contentShape(Rectangle())
      .modifier(SidebarDragDim(id: id, drag: drag.drag))
      .onTapGesture { actions.select(id) }
      // Drag this root onto a displayed workroom pane to split them (issue #101). Simultaneous so the
      // List still scrolls vertically; the tap above still selects.
      .simultaneousGesture(drag.splitGesture(id, actions: actions))
      .modifier(SidebarRootTooltip(projectID: model.projectPath))
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .modifier(
        SidebarRootStatusLabel(
          id: id, projectID: model.projectPath, isMissing: target.isMissing,
          // The marks' spoken twins: this row ignores its children, so their own labels are lost.
          programLabels: [
            activity.waiting > 0
              ? ProgramStatusPresentation.waitingLabel(
                count: activity.waiting, stale: activity.waitingStale) : "",
            activity.failed && activity.waiting == 0 ? "a command reported an error" : "",
          ])
      )
      .accessibilityActions {
        if activity.waiting > 0 {
          Button(ProgramStatusPresentation.showWaitingAction) { actions.showWaiting([target.id]) }
        }
      }
      .contextMenu {
        SidebarRunMenu(target: target)
      }
  }
}

// MARK: Workroom

struct SidebarWorkroomRowModel: Equatable {
  let projectPath: String
  let workroom: Workroom
  let target: TerminalTarget
  /// A remote workroom still being made: its row opens its creation pane (#483), but has nothing to
  /// drag, label or delete yet.
  let pending: Bool
  /// Its create is still running (#116), from any window: it can't be deleted mid-setup.
  let isCreating: Bool
  /// A create's progress, for every kind, while its run lasts (#483).
  let creationRun: SidebarCreationRunRef?
  let subtree: SidebarSubtreeState
  let activity: SidebarTargetActivity

  var id: SidebarID { .workroom(project: projectPath, name: workroom.name) }
}

/// A create's run, compared by identity: the step circle observes the run itself.
struct SidebarCreationRunRef: Equatable {
  let run: CreationRun

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.run === rhs.run }
}

struct SidebarWorkroomRow: View, Equatable {
  let model: SidebarWorkroomRowModel
  let hovered: Bool
  let drag: SidebarDragPlumbing
  let actions: SidebarActions
  /// `drag`'s identity, for the gate (see `SidebarRootRow.dragToken`).
  private let dragToken: UUID

  init(
    model: SidebarWorkroomRowModel, hovered: Bool, drag: SidebarDragPlumbing,
    actions: SidebarActions
  ) {
    self.model = model
    self.hovered = hovered
    self.drag = drag
    self.actions = actions
    dragToken = drag.token
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.model == rhs.model && lhs.hovered == rhs.hovered && lhs.dragToken == rhs.dragToken
  }

  var body: some View {
    #if DEBUG
      let _ = {
        ProjectSidebar.rowEvaluations += 1
        SidebarRowPasses.workroom += 1
        SidebarRowPasses.byRow[model.id, default: 0] += 1
      }()
    #endif
    let id = model.id
    let workroom = model.workroom
    let target = model.target
    let activity = model.activity
    HStack(spacing: 6) {
      // Leading identity glyph (a cube for a workroom), swapped for the expand/collapse chevron on
      // hover when the row has ≥2 terminals — the same left edge as the root row, so roots and
      // workrooms read as aligned siblings.
      SidebarLeadingSlot(
        id: id, target: target, root: false, subtree: model.subtree, hovered: hovered,
        toggle: { actions.toggleTerminals(target.id) })
      // lineLimit so a long name yields to the VCS badges — truncation priority: name first (#24).
      // Shows the display label when one is set (issue #41), else the real workroom name.
      Text(workroom.displayName).font(.callout).lineLimit(1).truncationMode(.tail)
      Spacer()
      SidebarUnreadDot(source: .target(target.id))
      ForEach(workroom.warnings, id: \.kind) { warning in
        WarningGlyph()
          .help(warning.message)
      }
      // Spinner/delete slot: a progress spinner while the workroom's setup runs (issue #116) or a
      // command runs (issue #28), swapped for the delete button on hover — so a workroom stays
      // deletable even mid-run. The delete button is always laid out (it reveals via opacity), so it
      // fixes the slot's size and the smaller spinner can't shift the row. Trailing, so the spinner
      // lines up with the root row's, which has no slot.
      ZStack(alignment: .trailing) {
        // A create's progress, for every kind, while its run lasts (#483).
        if let run = model.creationRun?.run {
          CreateStepCircle(run: run)
        } else if activity.waiting == 0, activity.failed || activity.running, !hovered {
          RunningSpinner(failed: activity.failed)
        }
        // Hidden while the workroom's setup is still running — it can't be deleted mid-setup (#116).
        DeleteRowButton(
          name: workroom.displayName,
          visible: hovered && !model.isCreating
        ) {
          actions.deleteWorkroom(id)
        }
      }
      // A waiting terminal (#358) takes the mark's place and stays on hover: the delete button
      // appears in its own slot, on the glyph's leading side, so nothing moves.
      if activity.waiting > 0 {
        NeedsYouButton(count: activity.waiting, stale: activity.waitingStale) {
          actions.showWaiting([target.id])
        }
        .accessibilityIdentifier("sidebar.workroom.\(workroom.name).needsYou")
      }
      // The run's stop control is only present while its command is running, as on the root row.
      RowRunButton(
        target: target, projectPath: model.projectPath,
        identifier: "sidebar.workroom.\(workroom.name).run")
    }.frame(height: SidebarRowMetrics.rowHeight)
      .contentShape(Rectangle())
      .modifier(SidebarDragDim(id: id, drag: drag.drag))
      .onTapGesture { actions.select(id) }
      // Drag this workroom onto a displayed pane to split them (issue #101). Simultaneous so the List
      // still scrolls vertically; the tap above still selects.
      .simultaneousGesture(
        drag.splitGesture(id, actions: actions), including: model.pending ? .none : .all
      )
      .accessibilityIdentifier("sidebar.workroom.\(workroom.name)")
      .accessibilityAddTraits(.isButton)
      .accessibilityActions {
        if activity.waiting > 0 {
          Button(ProgramStatusPresentation.showWaitingAction) { actions.showWaiting([target.id]) }
        }
      }
      .contextMenu {
        // A workroom still being made has nothing to open, label or delete yet.
        if !model.pending {
          WorkroomMenuAdapter(sid: id, target: target, style: .sidebarRow)
        }
      }
  }
}

// MARK: Terminal

struct SidebarTerminalRowModel: Equatable {
  /// Where a row's title is read from, comparable without reading the title: a terminal's
  /// live-title cell by identity, a content tab's own title by value.
  enum TitleSource: Equatable {
    case live(ObjectIdentifier)
    case fixed(String)
  }

  let tabID: TerminalTab.ID
  let target: TerminalTarget
  /// The root or workroom row the terminal is listed under.
  let parent: SidebarID
  let title: TitleSource
  /// A content tab gets the same glyph the tab strip and the pane title bar use (#66), so a glance
  /// at the row says "this isn't a terminal". `TabContent.glyph` is that one source; it returns nil
  /// for a terminal (the unmarked default elsewhere), and this row is the one place that wants an
  /// explicit terminal glyph instead, since every row here carries one.
  let glyph: String
  let indicator: PaneIndicator
  let programStatus: ProgramStatusRollup?
  /// Whether it is a terminal attached to a daemon session, whose host can say why its program
  /// reports nothing (`SidebarTerminalTooltip`).
  let hasSession: Bool

  var isRunning: Bool {
    if case .running = indicator { return true }
    return false
  }
  var isProgressFailed: Bool { indicator == .running(failed: true) }
}

/// One terminal in a target's expanded subtree (issue #30): a terminal glyph centered in the shared
/// caret column (sharing the chevron's vertical axis, and keeping the title in the same column as
/// the root/workroom labels above it), the tab's live title, a per-tab unread dot, and — swapped on
/// hover like the workroom row — a running spinner or a close button. The row mirrors the workroom
/// row's layout exactly (no `Button` wrapper, which would inset the title and break the shared
/// label column); the tap is a gesture that selects the target and focuses this terminal — it never
/// becomes the `List` selection, so `selectedTargetID` stays a root/workroom.
struct SidebarTerminalRow: View, Equatable {
  let model: SidebarTerminalRowModel
  /// What the title is read from. Outside the model, which compares `model.title` in its place.
  let content: TabContent
  let hovered: Bool
  let actions: SidebarActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.model == rhs.model && lhs.hovered == rhs.hovered
  }

  var body: some View {
    #if DEBUG
      let _ = { SidebarRowPasses.terminal += 1 }()
    #endif
    HStack(spacing: 6) {
      // Leading glyph centered in the shared caret slot, same size/weight as the root house and the
      // workroom chevron so the leading-icon column reads as one set. The fixed-width frame keeps the
      // title in the same column as the root/workroom labels regardless of the symbol's intrinsic width.
      Image(systemName: model.glyph)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, alignment: .center)
      // The title is read in a leaf (`TabTitleReader`): a terminal's changes many times a second,
      // and the row's body must not re-run for each one.
      TabTitleReader(content: content) { title in
        Text(title)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)

      SidebarUnreadDot(source: .tab(model.tabID))

      // Same swapped slot as the workroom row: a spinner while a command runs, replaced by the close
      // button on hover. The close button is always laid out (revealed via opacity) so the row size
      // is stable and the smaller spinner can't shift it.
      ZStack {
        if model.isRunning || model.indicator == .error, !hovered {
          RunningSpinner(failed: model.isProgressFailed || model.indicator == .error)
        }
        TabTitleReader(content: content) { title in
          CloseTerminalRowButton(title: title, visible: hovered) {
            actions.closeTerminal(model.tabID, model.target)
          }
        }
      }
      // A waiting or finished program (#358) takes the spinner's place and stays on hover, with the
      // close button in its own slot on the glyph's leading side.
      if model.indicator == .blocked || model.indicator == .done {
        ProgramStatusGlyph(
          mark: model.indicator == .blocked ? .blocked : .done,
          stale: model.programStatus?.stale == true
        )
        .frame(width: 16)
        .accessibilityHidden(true)
      }
    }
    // A small indent so the expanded terminal rows read as children of their root/workroom row.
    .padding(.leading, 8)
    .contentShape(Rectangle())
    .onTapGesture { actions.revealTerminal(model.tabID, model.parent) }
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { actions.revealTerminal(model.tabID, model.parent) }
    .withTabTitle(content) { row, title in
      row
        .modifier(
          SidebarTerminalTooltip(
            title: title, indicator: model.indicator, rollup: model.programStatus,
            hasSession: model.hasSession, hostID: model.target.hostID)
        )
        .accessibilityLabel(
          ([title]
            + ProgramStatusPresentation.accessibilityParts(
              indicator: model.indicator, rollup: model.programStatus)).joined(separator: ", ")
        )
        .accessibilityIdentifier("sidebar.terminal.\(title)")
    }
    .contextMenu {
      SidebarTerminalMenu(tabID: model.tabID, target: model.target)
    }
  }
}

// MARK: Shared parts

/// The leading icon column for a root/workroom row (issue #30): the identity glyph — a house for the
/// project root, a cube for a workroom. When the row owns ≥2 terminals it's expandable, and
/// hovering the row swaps the glyph for the expand/collapse chevron — so the chevron shows only when
/// it's both usable and the row is the pointer's focus. The chevron's own `Button` toggles expansion
/// without selecting the row (a button inside a selectable `List` row swallows the tap). Both occupy
/// `caretWidth` (centered), so sibling rows share one left edge and the glyph/chevron sit on the same
/// vertical axis as the terminal-row glyph below.
private struct SidebarLeadingSlot: View {
  let id: SidebarID
  let target: TerminalTarget
  let root: Bool
  let subtree: SidebarSubtreeState
  let hovered: Bool
  let toggle: () -> Void

  var body: some View {
    if subtree.hasSubtree, hovered {
      TerminalDisclosureButton(
        expanded: subtree.expanded, width: SidebarRowMetrics.caretWidth, action: toggle)
    } else {
      // The glyph's tint carries the VCS dirty signal (orange) in place of a separate status dot. A
      // workroom on a host wears the network, with the host's kind as its tooltip (#309).
      SidebarStatusGlyph(id: id, symbol: root ? "house" : target.workroomGlyph)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
        .help(root ? "" : target.hostTooltip)
        .accessibilityLabel(root ? "Project root" : target.hostKind ?? "Workroom")
    }
  }
}

#if DEBUG
  #Preview("Sidebar rows") {
    // A project, its root with a terminal waiting on the user, a workroom running a command, and
    // that workroom's terminal. The leaves in the rows read the store they are handed here.
    let store = AppStore()
    let path = "/tmp/platform"
    let workroom = Workroom(
      name: "fix-auth", path: "\(path)/fix-auth", vcsName: "fix-auth", warnings: [])
    let project = Project(path: path, vcs: "git", workrooms: [workroom])
    let root = project.rootTarget
    let target = workroom.target(inProject: path)
    let terminal = TabContent.terminal(
      TerminalState(defaultTitle: "zsh", launch: .shell, launchDirectory: target.path))
    VStack(alignment: .leading, spacing: 4) {
      SidebarProjectRow(
        model: SidebarProjectRowModel(project: project, expanded: true), hovered: false,
        actions: .inert)
      SidebarRootRow(
        model: SidebarRootRowModel(
          projectPath: path, projectName: project.displayName, target: root,
          subtree: SidebarSubtreeState(),
          activity: SidebarTargetActivity(waiting: 1)),
        hovered: false, drag: .inert, actions: .inert)
      SidebarWorkroomRow(
        model: SidebarWorkroomRowModel(
          projectPath: path, workroom: workroom, target: target, pending: false,
          isCreating: false, creationRun: nil,
          subtree: SidebarSubtreeState(hasSubtree: true, expanded: true),
          activity: SidebarTargetActivity(running: true)),
        hovered: false, drag: .inert, actions: .inert)
      SidebarTerminalRow(
        model: SidebarTerminalRowModel(
          tabID: UUID(), target: target, parent: .workroom(project: path, name: "fix-auth"),
          title: .fixed("zsh"), glyph: "terminal", indicator: .running(failed: false),
          programStatus: nil, hasSession: false),
        content: terminal, hovered: false, actions: .inert)
    }
    .padding(8)
    .environmentObject(store)
    .environmentObject(store.runCommand)
    .environmentObject(store.vcsStatus)
    .environmentObject(store.lifecycle)
    .environmentObject(store.notifications)
    .themeTokensRoot()
    .frame(width: 280)
  }
#endif
