import DesignSystem
import SwiftUI
import WorkroomDomain

// Each sidebar row's adapter: the one place its model is read from the window's stores, so a change
// re-runs only the adapters that read it. Every adapter sits behind its own equality gate, so a
// sidebar pass that rebuilds the tree (a project collapsing, a workroom added) re-runs none whose
// inputs are unchanged; and each builds its row behind the row's gate, so a change that leaves the
// row's model as it was re-runs no row body. The rows' context menus are adapters too: their
// content is built when the menu opens, so their reads are in no row's body.

/// Builds a project's row.
struct SidebarProjectRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  let project: Project
  let hovered: Bool
  let actions: SidebarActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.project == rhs.project && lhs.hovered == rhs.hovered
  }

  var body: some View {
    SidebarProjectRow(model: model, hovered: hovered, actions: actions).equatable()
  }

  private var model: SidebarProjectRowModel {
    let expanded = !store.collapsedProjects.contains(project.path)
    // The waiting count shows only while collapsed, so an expanded project observes no terminal.
    guard !expanded else { return SidebarProjectRowModel(project: project, expanded: true) }
    let ids = project.targetIDs
    let terminals = store.terminals
    let waiting = ids.reduce(0) { $0 + terminals.blockedTerminalCount(forTargetID: $1) }
    return SidebarProjectRowModel(
      project: project, expanded: false, waiting: waiting,
      waitingStale: waiting > 0 && ids.contains { terminals.isWaitingStale(forTargetID: $0) })
  }
}

/// Builds a project's root row.
struct SidebarRootRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var vcsStatus: VCSStatusService
  let project: Project
  let hovered: Bool
  let drag: SidebarDragPlumbing
  let actions: SidebarActions
  /// `drag`'s identity, for the gate (see `SidebarRootRow.dragToken`).
  private let dragToken: UUID

  init(project: Project, hovered: Bool, drag: SidebarDragPlumbing, actions: SidebarActions) {
    self.project = project
    self.hovered = hovered
    self.drag = drag
    self.actions = actions
    dragToken = drag.token
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.project == rhs.project && lhs.hovered == rhs.hovered && lhs.dragToken == rhs.dragToken
  }

  var body: some View {
    SidebarRootRow(model: model, hovered: hovered, drag: drag, actions: actions).equatable()
  }

  private var model: SidebarRootRowModel {
    let target = project.rootTarget
    return SidebarRootRowModel(
      projectPath: project.path, projectName: project.displayName, target: target,
      style: RootPresentation.make(vcsStatus.rootRefs[project.id] ?? .unresolved),
      subtree: store.sidebarSubtree(of: target), activity: store.sidebarActivity(of: target.id))
  }
}

/// Builds a workroom's row.
struct SidebarWorkroomRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var lifecycle: WorkroomLifecycle
  let workroom: Workroom
  let project: Project
  let hovered: Bool
  let drag: SidebarDragPlumbing
  let actions: SidebarActions
  /// `drag`'s identity, for the gate (see `SidebarRootRow.dragToken`).
  private let dragToken: UUID

  init(
    workroom: Workroom, project: Project, hovered: Bool, drag: SidebarDragPlumbing,
    actions: SidebarActions
  ) {
    self.workroom = workroom
    self.project = project
    self.hovered = hovered
    self.drag = drag
    self.actions = actions
    dragToken = drag.token
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workroom == rhs.workroom && lhs.project == rhs.project && lhs.hovered == rhs.hovered
      && lhs.dragToken == rhs.dragToken
  }

  var body: some View {
    SidebarWorkroomRow(model: model, hovered: hovered, drag: drag, actions: actions).equatable()
  }

  private var model: SidebarWorkroomRowModel {
    let target = workroom.target(inProject: project.path)
    let isCreating = lifecycle.isCreatingWorkroom(workroom, in: project)
    return SidebarWorkroomRowModel(
      projectPath: project.path, workroom: workroom, target: target,
      pending: workroom.host != nil && isCreating, isCreating: isCreating,
      creationRun: lifecycle.creationRun(
        for: .workroom(project: project.path, name: workroom.name)
      ).map(SidebarCreationRunRef.init),
      subtree: store.sidebarSubtree(of: target), activity: store.sidebarActivity(of: target.id))
  }
}

/// Builds one terminal's row in a target's subtree.
struct SidebarTerminalRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  /// Each host's program-status link (#358), for the "Program status: …" tooltip line: observed so
  /// a host that connects repaints the line.
  @ObservedObject private var programStatus = ProgramStatusMonitor.shared
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  let parent: SidebarID
  let hovered: Bool
  let actions: SidebarActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.tabID == rhs.tabID && lhs.target == rhs.target && lhs.parent == rhs.parent
      && lhs.hovered == rhs.hovered
  }

  var body: some View {
    if let tab = store.terminals.tab(tabID, for: target) {
      SidebarTerminalRow(
        model: model(of: tab), content: tab.content, hovered: hovered, actions: actions
      )
      .equatable()
    }
  }

  private func model(of tab: TerminalTab) -> SidebarTerminalRowModel {
    let title: SidebarTerminalRowModel.TitleSource =
      if case .terminal(let state) = tab.content {
        .live(ObjectIdentifier(state.titleCell))
      } else {
        .fixed(tab.title)
      }
    return SidebarTerminalRowModel(
      tabID: tab.id, target: target, parent: parent, title: title,
      glyph: tab.content.glyph ?? "terminal", indicator: tab.indicator,
      programStatus: tab.programStatus,
      tooltipLines: ProgramStatusPresentation.tooltipLines(
        for: tab, of: target, hosts: programStatus.hosts))
  }
}

extension AppStore {
  /// Whether `target`'s row has a terminal subtree (≥2 terminals), and whether it is open; the
  /// expansion is read only for a row that has one.
  fileprivate func sidebarSubtree(of target: TerminalTarget) -> SidebarSubtreeState {
    let hasSubtree = terminals.tabs(for: target).count >= 2
    return SidebarSubtreeState(
      hasSubtree: hasSubtree, expanded: hasSubtree && isTerminalsExpanded(target.id))
  }

  /// What `targetID`'s terminals report on its row (#358).
  fileprivate func sidebarActivity(of targetID: TerminalTarget.ID) -> SidebarTargetActivity {
    let waiting = terminals.blockedTerminalCount(forTargetID: targetID)
    return SidebarTargetActivity(
      waiting: waiting,
      waitingStale: waiting > 0 && terminals.isWaitingStale(forTargetID: targetID),
      failed: terminals.isProgressFailed(forTargetID: targetID)
        || terminals.hasProgramError(forTargetID: targetID),
      running: terminals.isRunning(forTargetID: targetID))
  }
}

// MARK: Backgrounds

/// A root, workroom or create's row highlight, drawn at the row-background level so hover and
/// selection share the same (smaller, inset) geometry. The selected row wears the focused workroom
/// card's fill, as the right sidebar's header does (`InspectorWorkroomHeader`), so the row, the pane
/// and the header read as one workroom; hovered rows a subtle one. Drawn ourselves so we control the
/// size rather than the full-row system selection highlight. It reads the selection itself, so a
/// selection repaints two backgrounds and re-runs no row.
///
/// The store is handed in, not taken from the environment: a row's background is laid out once
/// more while its row animates out of the List (a project collapsing), without the environment
/// objects, and an `@EnvironmentObject` read there traps.
struct SidebarRowBackground: View {
  let store: AppStore
  let id: SidebarID
  let hovered: Bool

  var body: some View {
    #if DEBUG
      let _ = { SidebarRowPasses.background += 1 }()
    #endif
    if store.selectedTargetID == id {
      WorkroomPaneCardBackground(highlighted: true)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s))
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, 1)
    } else {
      RowHighlight(selected: false, hovered: hovered)
    }
  }
}

/// A terminal row's highlight — the same geometry, with its own row-local hover state — selected
/// when its target is the selected row and it is that target's focused terminal. Handed the store
/// and the theme, as `SidebarRowBackground` is.
struct SidebarTerminalRowBackground: View {
  let store: AppStore
  let tokens: ThemeTokens
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  let parent: SidebarID
  let hovered: Bool

  var body: some View {
    // The focused terminal is read only for the selected target's rows.
    let selected =
      store.selectedTargetID == parent && store.terminals.focusedTab(for: target)?.id == tabID
    // Lighter than the root/workroom selection fill (0.13): the selected workroom is the primary
    // selection, the focused terminal a secondary "active within" cue — so the two don't read as two
    // equal selections when a subtree is open (issue #30 design pass).
    let fill: Color =
      selected ? tokens.hover : (hovered ? tokens.hover.opacity(0.5) : .clear)
    RoundedRectangle(cornerRadius: Radius.s)
      .fill(fill)
      .padding(.horizontal, Spacing.m)
      .padding(.vertical, 1)
  }
}

// MARK: Menus

/// A project row's context menu.
struct SidebarProjectMenu: View {
  @EnvironmentObject private var store: AppStore
  let project: Project

  var body: some View {
    // New Workroom asks where: this Mac, a local container or boxd (#253, #309, #356).
    Menu {
      NewWorkroomPlacesMenu(project: project)
    } label: {
      Label("New Workroom", systemImage: "plus")
    }
    // No tooltip here: a submenu's parent shows it on top of the submenu, over This Mac. Each
    // entry has its own.
    Divider()
    runCommandMenuItems(host: store, target: project.rootTarget)
    Divider()
    Button {
      store.modals.pendingProjectSettings = PendingProjectSettings(project: project)
    } label: {
      Label("Project Settings…", systemImage: "gearshape")
    }
    Divider()
    Button(role: .destructive) {
      store.modals.pendingProjectDeletion = PendingProjectDeletion(project: project)
    } label: {
      Label("Delete Project…", systemImage: "trash")
    }
  }
}

/// A root row's context menu: its run command.
struct SidebarRunMenu: View {
  @EnvironmentObject private var store: AppStore
  let target: TerminalTarget

  var body: some View {
    runCommandMenuItems(host: store, target: target)
  }
}

/// A terminal row's context menu.
struct SidebarTerminalMenu: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var runCommand: RunCommandController
  let tabID: TerminalTab.ID
  let target: TerminalTarget

  var body: some View {
    let tab = store.terminals.tab(tabID, for: target)
    if runCommand.runTabID(for: target.id) == tabID {
      runCommandMenuItems(host: store, target: target)
      Divider()
    }
    // The escape hatch for a program that left a request behind (#358).
    if tab?.programStatus?.hasReport == true {
      Button {
        store.terminals.clearProgramStatus(tab: tabID, target: target.id)
      } label: {
        Label("Clear Status", systemImage: "hand.raised.slash")
      }
      // Unreachable, the daemon never hears the clear and the reconnect puts the mark back.
      .disabled(tab?.programStatus?.stale == true)
      Divider()
    }
    paneWindowMenuItem(host: store, tabID: tabID, targetID: target.id)
    Divider()
    Button(role: .destructive) {
      store.requestCloseTerminalTab(tabID, for: target)
    } label: {
      Label("Close \(tab?.title ?? "")", systemImage: "xmark")
    }
  }
}
