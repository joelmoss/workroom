import Defaults
import Foundation
import Observation
import WorkroomDomain

/// How the sidebar's Open Tabs view groups this window's tabs, picked from its header's Group by
/// menu, one choice for every window.
enum OpenTabsGrouping: String, CaseIterable, Sendable, Defaults.Serializable {
  /// A header per project, its workrooms' tabs listed under it with each one's workroom named.
  case project
  /// A header per project, its workrooms' rows under it, each unfolding to its tabs.
  case projectWorkroom
  /// A row per workroom tab of the title bar, each unfolding to its tabs: the view as it was.
  case workroom
  /// None: every tab in one list, each with its project and workroom named. Not `none`, which an
  /// `OpenTabsGrouping?` would read as nil.
  case ungrouped

  /// Its item in the Group by menu.
  var title: String {
    switch self {
    case .project: "Project"
    case .projectWorkroom: "Project › Workroom"
    case .workroom: "Workroom"
    case .ungrouped: "None"
    }
  }

  /// Whether a project's targets go under a header of their own.
  var groupsProjects: Bool { self == .project || self == .projectWorkroom }

  /// Whether a project's workroom shows a row of its own above its tabs.
  var showsWorkroomRows: Bool { self == .projectWorkroom || self == .workroom }
}

/// The Open Tabs view's grouping, which every window's view follows as it changes. Kept in
/// `Defaults[.openTabsGrouping]`, read once: an observed object, so a change re-runs each list,
/// which a `@Default` read does not reliably do (`AppStore.collapsedProjects`).
@MainActor @Observable
final class OpenTabsGroupingSetting {
  static let shared = OpenTabsGroupingSetting()

  var grouping: OpenTabsGrouping {
    didSet { if grouping != oldValue { Defaults[.openTabsGrouping] = grouping } }
  }

  init(grouping: OpenTabsGrouping = Defaults[.openTabsGrouping]) {
    self.grouping = grouping
  }
}

/// A project's header in the Open Tabs view's project groupings.
struct OpenTabsProjectRowModel: Equatable {
  let path: String
  let name: String
  let isFolded: Bool
  /// How many of its terminals wait on the user, counted only while it is folded, the only time
  /// its header shows it, as a Projects view's project row does.
  var waitingCount = 0
  var waitingStale = false
  /// How many targets it holds, for its spoken label.
  var targetCount = 0
}

/// One top-level group of the Open Tabs view: a project and its targets' rows, or a target with
/// no project (a standalone terminal or a terminal group), or any target where projects aren't
/// grouped.
enum OpenTabsGroup {
  case project(OpenTabsProjectRowModel, rows: [OpenTabsRow])
  case target(OpenTabsRow)

  /// Its targets' rows, in list order.
  var rows: [OpenTabsRow] {
    switch self {
    case .project(_, let rows): rows
    case .target(let row): [row]
    }
  }
}

/// The Open Tabs view as a grouping lays it out: its top-level groups in list order.
struct OpenTabsLayout {
  let grouping: OpenTabsGrouping
  let groups: [OpenTabsGroup]

  /// Every target's row, in list order.
  var rows: [OpenTabsRow] { groups.flatMap(\.rows) }
}

extension AppStore {
  /// The Open Tabs view's grouping, which every window shares.
  var openTabsGrouping: OpenTabsGrouping {
    get { OpenTabsGroupingSetting.shared.grouping }
    set { OpenTabsGroupingSetting.shared.grouping = newValue }
  }

  /// The Open Tabs view as `grouping` lays it out. Targets keep the title bar's order, but a
  /// project's go together under its header, where its first one is in the title bar. A target
  /// with no project stays where it is among them. Where no workroom row says so, each tab names
  /// its workroom (`OpenTabsTabRowModel.context`), and its tabs are built whatever the workroom's
  /// fold, which shows nowhere. `showing`: as `openTabsRows(showing:)`.
  func openTabsLayout(
    grouping: OpenTabsGrouping? = nil, showing: OpenTabsItem? = nil
  ) -> OpenTabsLayout {
    let grouping = grouping ?? openTabsGrouping
    var groups: [OpenTabsGroup] = []
    var projectRows: [String: [OpenTabsRow]] = [:]
    var projectOrder: [String] = []
    for (sid, target) in displayedWorkroomTargets() {
      let path = Self.projectPath(of: sid)
      let unfolded = grouping == .ungrouped || (grouping == .project && path != nil)
      var row = openTabsRow(sid, target, showing: showing, unfolded: unfolded)
      if let context = openTabsContext(of: row, grouping: grouping) {
        row = row.withTabs(context: context)
      }
      guard grouping.groupsProjects, let path else {
        groups.append(.target(row))
        continue
      }
      if projectRows[path] == nil {
        projectOrder.append(path)
        // Its place, filled once every target is in.
        groups.append(
          .project(OpenTabsProjectRowModel(path: path, name: "", isFolded: false), rows: []))
      }
      // Its root first, as the Projects view lists it.
      if case .root = sid {
        projectRows[path, default: []].insert(row, at: 0)
      } else {
        projectRows[path, default: []].append(row)
      }
    }
    var next = projectOrder.makeIterator()
    groups = groups.map { group in
      guard case .project = group, let path = next.next() else { return group }
      let rows = projectRows[path] ?? []
      return .project(openTabsProjectModel(path, rows: rows), rows: rows)
    }
    return OpenTabsLayout(grouping: grouping, groups: groups)
  }

  /// Project `path`'s header, over `rows`.
  private func openTabsProjectModel(_ path: String, rows: [OpenTabsRow]) -> OpenTabsProjectRowModel
  {
    let isFolded = foldedOpenProjects.contains(path)
    let summary =
      isFolded
      ? rows.reduce(TargetStatusSummary()) {
        $0 + terminals.statusSummary(forTargetID: $1.target.id)
      } : TargetStatusSummary()
    return OpenTabsProjectRowModel(
      path: path,
      name: projectStore.project(at: path)?.displayName
        ?? (path as NSString).lastPathComponent,
      isFolded: isFolded, waitingCount: summary.waiting, waitingStale: summary.allWaitingStale,
      targetCount: rows.count)
  }

  /// What `row`'s tabs say of where they live under `grouping`: nothing where a workroom row says
  /// it, or under a terminal group's row in a project grouping.
  private func openTabsContext(of row: OpenTabsRow, grouping: OpenTabsGrouping)
    -> OpenTabsTabContext?
  {
    let presentation = row.model.presentation
    switch (grouping, row.sid) {
    case (.workroom, _), (.projectWorkroom, _), (.project, .standalone),
      (.project, .terminalGroup), (_, .project):
      return nil
    case (.ungrouped, .standalone), (.ungrouped, .terminalGroup):
      return OpenTabsTabContext(project: nil, name: .text(presentation.primaryLabel))
    case (_, .root(let path)):
      return OpenTabsTabContext(
        project: grouping == .ungrouped ? presentation.primaryLabel : nil,
        name: .root(projectPath: path)
      )
    case (_, .workroom), (_, .creation):
      return OpenTabsTabContext(
        project: grouping == .ungrouped ? presentation.primaryLabel : nil,
        name: .text(presentation.workroomName ?? row.target.title))
    }
  }
}

extension OpenTabsRow {
  /// It, its tabs saying `context` of where they live.
  func withTabs(context: OpenTabsTabContext) -> OpenTabsRow {
    OpenTabsRow(
      model: model,
      tabs: tabs.map { tab in
        var model = tab.model
        model.context = context
        return OpenTabsTabRow(model: model, tab: tab.tab)
      })
  }
}

/// What the Open Tabs view's Expand All / Collapse All button does now.
enum OpenTabsFoldAll: Equatable {
  /// Something is unfolded: fold everything.
  case collapse
  /// Everything is folded: unfold it all.
  case expand
}

extension AppStore {
  // MARK: Project folds

  /// Fold or unfold project `path`'s group.
  func setOpenProject(_ path: String, folded: Bool) {
    if folded { foldedOpenProjects.insert(path) } else { foldedOpenProjects.remove(path) }
  }

  /// A project header's click, chevron or Expand/Collapse.
  func toggleOpenProjectFold(_ path: String) {
    setOpenProject(path, folded: !foldedOpenProjects.contains(path))
  }

  /// A project header's Show in Projects: the Projects view, the project expanded in it.
  func showOpenProjectInProjects(_ path: String) {
    collapsedProjects.remove(path)
    sidebarView = .projects
  }

  /// A folded project header's waiting mark: the terminal of its targets here that has waited
  /// longest, as a Projects view's collapsed project's mark does.
  func showWaiting(inOpenProject path: String) {
    let targets = displayedWorkroomTargets().filter { Self.projectPath(of: $0.sid) == path }
    let oldest = targets.flatMap { _, target in
      terminals.blockedTabs(forTargetID: target.id).map { (target.id, $0.tab, $0.since) }
    }
    .min { $0.2 < $1.2 }
    guard let oldest else { return }
    openTerminal(targetID: oldest.0, tabID: oldest.1)
  }

  // MARK: Expand All / Collapse All

  /// What the header's button does in `grouping`: nil when nothing there can fold (None, or only
  /// standalone terminals), which disables it.
  func openTabsFoldAll(grouping: OpenTabsGrouping? = nil) -> OpenTabsFoldAll? {
    let (projects, targets) = openTabsFoldables(grouping: grouping)
    guard !projects.isEmpty || !targets.isEmpty else { return nil }
    let unfolded =
      projects.contains { !foldedOpenProjects.contains($0) }
      || targets.contains { !isOpenRowFolded($0) }
    return unfolded ? .collapse : .expand
  }

  /// Folds or unfolds every row `grouping` shows that folds, at every level. The selected row folds
  /// too, until it is next selected, as a fold by hand does.
  func foldAllOpenRows(_ action: OpenTabsFoldAll, grouping: OpenTabsGrouping? = nil) {
    let (projects, targets) = openTabsFoldables(grouping: grouping)
    let folded = action == .collapse
    for path in projects { setOpenProject(path, folded: folded) }
    for sid in targets { setOpenRow(sid, folded: folded) }
  }

  /// The projects and targets whose rows fold in `grouping`'s list: every project header, and each
  /// target row shown with tabs under it. Read from the targets alone, building no row, as the
  /// header's button reads it on every change of the window.
  private func openTabsFoldables(grouping: OpenTabsGrouping?)
    -> (projects: [String], targets: [SidebarID])
  {
    let grouping = grouping ?? openTabsGrouping
    guard grouping != .ungrouped else { return ([], []) }
    var projects: [String] = []
    var targets: [SidebarID] = []
    for (sid, target) in displayedWorkroomTargets() {
      let path = Self.projectPath(of: sid)
      if grouping.groupsProjects, let path, !projects.contains(path) { projects.append(path) }
      // A project's target shows no row of its own in Project.
      if grouping == .project, path != nil { continue }
      let count = terminals.tabs(for: target).count
      if TerminalPanes.showsTabStrip(tabCount: count, for: target.id) { targets.append(sid) }
    }
    return (projects, targets)
  }
}
