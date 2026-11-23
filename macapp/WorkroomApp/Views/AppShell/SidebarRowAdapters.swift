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
    let summary =
      expanded
      ? TargetStatusSummary()
      : project.targetIDs.reduce(TargetStatusSummary()) {
        $0 + store.terminals.statusSummary(forTargetID: $1)
      }
    // Disconnected only when every waiting terminal is: one that can be answered keeps the hand.
    return SidebarProjectRowModel(
      project: project, expanded: expanded, waiting: summary.waiting,
      waitingStale: summary.allWaitingStale)
  }
}

/// Builds a project's root row. Of the project it holds what the row shows, its path (its id) and
/// its name, and not its workrooms, so a pass of the sidebar compares no project's workroom list.
struct SidebarRootRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  let projectPath: String
  let projectName: String
  let hovered: Bool
  let drag: SidebarDragPlumbing
  let actions: SidebarActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.projectPath == rhs.projectPath && lhs.projectName == rhs.projectName
      && lhs.hovered == rhs.hovered && lhs.drag == rhs.drag
  }

  var body: some View {
    SidebarRootRow(model: model, hovered: hovered, drag: drag, actions: actions).equatable()
  }

  private var model: SidebarRootRowModel {
    // Whether the folder is gone is read from the store, not `stat`ed: nothing observable changes
    // when a folder goes, so a `stat` here would keep what it saw until the row next re-ran.
    let target = store.projectStore.rootTarget(path: projectPath, name: projectName)
    return SidebarRootRowModel(
      projectPath: projectPath, projectName: projectName, target: target,
      subtree: store.sidebarSubtree(of: target), activity: store.sidebarActivity(of: target.id))
  }
}

/// Builds a workroom's row. Of its project it holds the path alone, all the row shows of it.
struct SidebarWorkroomRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var lifecycle: WorkroomLifecycle
  /// Rarely changes: a host going, or being found again.
  @ObservedObject private var goneHosts = GoneHosts.shared
  let workroom: Workroom
  let projectPath: String
  let hovered: Bool
  let drag: SidebarDragPlumbing
  let actions: SidebarActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workroom == rhs.workroom && lhs.projectPath == rhs.projectPath
      && lhs.hovered == rhs.hovered && lhs.drag == rhs.drag
  }

  var body: some View {
    SidebarWorkroomRow(model: model, hovered: hovered, drag: drag, actions: actions).equatable()
  }

  private var model: SidebarWorkroomRowModel {
    let target = workroom.target(inProject: projectPath)
    return SidebarWorkroomRowModel(
      projectPath: projectPath, workroom: workroom, target: target,
      isCreating: lifecycle.isCreatingWorkroom(workroom, inProject: projectPath),
      creationRun: lifecycle.creationRun(
        for: .workroom(project: projectPath, name: workroom.name)
      ).map(SidebarCreationRunRef.init),
      subtree: store.sidebarSubtree(of: target), activity: store.sidebarActivity(of: target.id),
      hostGone: goneHosts.contains(workroom.host?.id),
      setupPending: lifecycle.isSetupPending(workroom, inProject: projectPath))
  }
}

/// Builds one terminal's row in a target's subtree.
struct SidebarTerminalRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  let parent: SidebarID
  let hovered: Bool
  let actions: SidebarActions
  /// Who holds the terminal when it isn't this window: the Quick Terminal's panel (story 10).
  var holder: (any PaneHost)? = nil
  var style: SidebarTerminalRowStyle = .tree

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.tabID == rhs.tabID && lhs.target == rhs.target && lhs.parent == rhs.parent
      && lhs.hovered == rhs.hovered && lhs.holder === rhs.holder && lhs.style == rhs.style
  }

  var body: some View {
    if let tab = (holder?.terminals ?? store.terminals).tab(tabID, for: target) {
      SidebarTerminalRow(
        model: model(of: tab), content: tab.content, hovered: hovered, actions: actions,
        holder: holder
      )
      .equatable()
    }
  }

  private func model(of tab: TerminalTab) -> SidebarTerminalRowModel {
    let title: SidebarTerminalRowModel.TitleSource =
      if case .terminal(let state) = tab.content {
        .live(
          ObjectIdentifier(state.titleCell), userTitle: state.userTitle,
          defaultName: state.defaultName)
      } else {
        .fixed(tab.title)
      }
    return SidebarTerminalRowModel(
      tabID: tab.id, target: target, parent: parent, title: title,
      glyph: tab.content.glyph ?? "terminal", tool: tab.recognizedTool, indicator: tab.indicator,
      programStatus: tab.programStatus, hasSession: tab.terminal?.sessionID != nil, style: style)
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
  func sidebarActivity(of targetID: TerminalTarget.ID) -> SidebarTargetActivity {
    SidebarTargetActivity(terminals.statusSummary(forTargetID: targetID))
  }

  /// What a Terminals-section row's terminals report on it (story 13): every holder's, since a
  /// standalone terminal or a group's terminals may be in another window or the Quick Terminal's
  /// panel, and the row is in every window. `excluding` leaves out the holder whose terminals are
  /// listed under the row, as their own rows show their marks; another holder's still count.
  func sectionActivity(of targetID: TargetID, excluding listed: TerminalPanes? = nil)
    -> SidebarTargetActivity
  {
    SidebarTargetActivity(
      terminalsSection.observedHolders.reduce(TargetStatusSummary()) {
        $1.terminals === listed ? $0 : $0 + $1.terminals.statusSummary(forTargetID: targetID)
      })
  }

  /// A Terminals-section row's waiting mark was clicked: focus the terminal in it that has waited
  /// longest, in whichever holder has it, bringing that window (or panel) forward.
  func showWaiting(inSectionTarget targetID: TargetID) {
    let oldest = terminalsSection.allHolders.flatMap { holder in
      holder.terminals.blockedTabs(forTargetID: targetID).map { (holder, $0.tab, $0.since) }
    }
    .min { $0.2 < $1.2 }
    guard let (holder, tab, _) = oldest else { return }
    holder.revealTerminal(tab, inTarget: targetID)
  }
}

// MARK: Backgrounds

/// A root, workroom or create's row highlight, drawn at the row-background level so hover and
/// selection share the same (smaller, inset) geometry. The selected row wears the focused
/// workroom card's fill, as the right sidebar's header does (`InspectorWorkroomHeader`), so the
/// row, the pane and the header read as one workroom; hovered rows a subtle one. Drawn ourselves
/// so we control the size rather than the full-row system selection highlight. It reads the
/// selection itself, so a selection repaints two backgrounds and re-runs no row.
///
/// The store is handed in, not taken from the environment: a row's background is laid out once
/// more while its row animates out of the List (a project collapsing), without the environment
/// objects, and an `@EnvironmentObject` read there traps.
struct SidebarRowBackground: View {
  let store: AppStore
  let id: SidebarID
  let hovered: Bool
  /// A terminal group whose terminals show under it: the focused one's row wears the selection,
  /// so the group's doesn't.
  var passesSelectionToChild = false

  var body: some View {
    #if DEBUG
      let _ = { SidebarRowPasses.background += 1 }()
    #endif
    if store.selectedTargetID == id, !passesSelectionToChild {
      SidebarSelectedRowFill()
    } else {
      RowHighlight(
        selected: false, hovered: hovered, horizontalPadding: SidebarRowMetrics.listContentInset)
    }
  }
}

/// A selected sidebar row's fill: the focused workroom card's, inset as a hovered row's is.
struct SidebarSelectedRowFill: View {
  var body: some View {
    WorkroomPaneCardBackground(highlighted: true)
      .clipShape(RoundedRectangle(cornerRadius: Radius.s))
      .padding(.horizontal, SidebarRowMetrics.listContentInset)
      .padding(.vertical, 1)
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
  /// A `.section` row wears a standalone terminal's row's highlights (`SidebarRowBackground`).
  var style: SidebarTerminalRowStyle = .tree

  var body: some View {
    // The focused terminal is read only for the selected target's rows.
    let selected =
      store.selectedTargetID == parent && store.terminals.focusedTab(for: target)?.id == tabID
    if style == .section {
      if selected {
        SidebarSelectedRowFill()
      } else {
        RowHighlight(
          selected: false, hovered: hovered, horizontalPadding: SidebarRowMetrics.listContentInset)
      }
    } else {
      treeFill(selected: selected)
    }
  }

  @ViewBuilder private func treeFill(selected: Bool) -> some View {
    // Lighter than the root/workroom selection fill (0.13): the selected workroom is the primary
    // selection, the focused terminal a secondary "active within" cue — so the two don't read as
    // two equal selections when a subtree is open (issue #30 design pass).
    let fill: Color =
      selected ? tokens.hover : (hovered ? tokens.hover.opacity(0.5) : .clear)
    #if DEBUG
      let _ = { SidebarRowPasses.terminalFills[tabID] = fill }()
    #endif
    RoundedRectangle(cornerRadius: Radius.s)
      .fill(fill)
      .padding(.horizontal, SidebarRowMetrics.listContentInset)
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
    runCommandMenuItems(
      host: store,
      target: store.projectStore.rootTarget(path: project.path, name: project.displayName))
    Divider()
    Button {
      store.openProjectSettings(project)
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

/// A terminal row's context menu, acting on whoever holds the terminal: this window, or the Quick
/// Terminal's panel (`holder`).
struct SidebarTerminalMenu: View {
  @EnvironmentObject private var store: AppStore
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  var holder: (any PaneHost)? = nil
  /// Rename…, which the row edits in place.
  var rename: () -> Void = {}

  var body: some View {
    let host: any PaneHost = holder ?? store
    let panes = host.terminals
    let tab = panes.tab(tabID, for: target)
    if host.runTabID(for: target.id) == tabID {
      runCommandMenuItems(host: host, target: target)
      Divider()
    }
    // Any terminal can be named, and moved anywhere, from its row as from its tab (stories 28, 41).
    if let tab, case .terminal = tab.content {
      sidebarRenameMenuItem(action: rename)
      terminalMoveMenu(
        host: host, tabID: tabID, target: target,
        help: "Move this terminal to a standalone terminal, a group or a workroom")
      Divider()
    }
    // The escape hatch for a program that left a request behind (#358).
    if tab?.programStatus?.hasReport == true {
      Button {
        panes.clearProgramStatus(tab: tabID, target: target.id)
      } label: {
        Label("Clear Status", systemImage: "hand.raised.slash")
      }
      // Unreachable, the daemon never hears the clear and the reconnect puts the mark back.
      .disabled(tab?.programStatus?.stale == true)
      Divider()
    }
    paneWindowMenuItem(host: host, tabID: tabID, targetID: target.id)
    Divider()
    Button(role: .destructive) {
      host.requestCloseTerminalTab(tabID, for: target)
    } label: {
      Label("Close \(tab?.title ?? "")", systemImage: "xmark")
    }
  }
}
