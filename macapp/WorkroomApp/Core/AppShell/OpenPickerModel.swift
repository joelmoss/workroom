import Foundation
import WorkroomDomain

/// One openable row in the Open Workroom picker (issue #94): a project root or a workroom, carrying
/// the `SidebarID` the picker hands to `AppStore.openExisting`. The picker groups rows under a
/// per-project header, so each row also carries its `projectName` (the header text) and `projectPath`
/// (the grouping key).
struct OpenTarget: Identifiable, Hashable {
  let sid: SidebarID
  /// The shown text — a workroom's `displayName` (its label when set, else its name) — issue #41.
  let title: String
  /// The real, immutable workroom name (== `title` for a root or an unlabelled workroom). Kept
  /// separate so the dialog's `accessibilityIdentifier` stays keyed on the stable name even when the
  /// label changes the visible `title`, and so a workroom remains findable by its real name.
  let name: String
  let projectName: String
  let projectPath: String
  let path: String
  let isRoot: Bool

  var id: SidebarID { sid }

  /// What the query matches against: the project name **then** the title, so a fuzzy subsequence can
  /// span both fields in reading order — e.g. "proapp" matches project "projectA"'s workroom "apple"
  /// (pro→projectA, app→apple). Typing a project name also surfaces its workrooms. When a display
  /// label hides the real name (`name != title`, issue #41), the real name is appended too so a
  /// labelled workroom stays findable by it; for roots/unlabelled rows `name == title`, so nothing
  /// is added and matching is byte-for-byte what it was before labels existed.
  var searchText: String {
    name == title ? "\(projectName) \(title)" : "\(projectName) \(title) \(name)"
  }
}

/// One project's section in the grouped picker: the header text plus its visible rows (root first,
/// then workrooms alphabetically). `id` is the project path so `ForEach` is stable.
struct OpenTargetGroup: Identifiable, Hashable {
  let projectPath: String
  let projectName: String
  let rows: [OpenTarget]

  var id: String { projectPath }
}

/// Builds, filters, and groups the Open Workroom picker's rows (issue #94). Pure value logic; the
/// filter/highlight/select core is the shared `PickerModel`, so this and `ProjectPickerModel` can't
/// drift. Missing-directory targets are excluded — the picker only offers things that actually open
/// (the sidebar remains the place to reach a broken workroom).
enum OpenPickerModel {
  /// Flat list of openable rows in display order: for each project (in `projects` order), its root
  /// (unless its directory is missing) followed by its workrooms **sorted alphabetically** (excluding
  /// any with a blocking/missing-directory warning). Reuses the existing `isMissing` logic on
  /// `Project.rootTarget` / `Workroom.target`. Keyboard highlight indexes into this flat list; the
  /// view regroups it for display via `grouped`.
  static func targets(from projects: [Project]) -> [OpenTarget] {
    projects.flatMap { project -> [OpenTarget] in
      var rows: [OpenTarget] = []
      if !project.rootTarget.isMissing {
        rows.append(
          OpenTarget(
            sid: .root(project: project.path), title: project.displayName,
            name: project.displayName, projectName: project.displayName,
            projectPath: project.path, path: project.path, isRoot: true))
      }
      // Sort by the shown name (displayName) so labelled rows read in alphabetical order of what the
      // user actually sees (issue #41), with the real name as a stable tie-break.
      let workrooms = project.workrooms
        .filter { !$0.target(inProject: project.path).isMissing }
        .sorted {
          let byShown = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
          return byShown == .orderedSame
            ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            : byShown == .orderedAscending
        }
      for workroom in workrooms {
        rows.append(
          OpenTarget(
            sid: .workroom(project: project.path, name: workroom.name), title: workroom.displayName,
            name: workroom.name, projectName: project.displayName, projectPath: project.path,
            path: workroom.path, isRoot: false))
      }
      return rows
    }
  }

  /// Rows matching `query` by fuzzy, multi-token subsequence over `searchText` (empty query returns
  /// all). Tokens are whitespace-separated and AND-ed — "A app" needs both "A" and "app".
  static func filtered(_ targets: [OpenTarget], query: String) -> [OpenTarget] {
    PickerModel.fuzzyFiltered(targets, query: query) { $0.searchText }
  }

  /// Regroup a (already-filtered) flat row list into per-project sections, preserving the rows'
  /// order — so groups appear in project order and each keeps its root-then-alphabetical rows.
  /// Empty groups can't occur: a group exists only because ≥1 of its rows survived the filter.
  static func grouped(_ targets: [OpenTarget]) -> [OpenTargetGroup] {
    var order: [String] = []
    var byProject: [String: [OpenTarget]] = [:]
    for target in targets {
      if byProject[target.projectPath] == nil { order.append(target.projectPath) }
      byProject[target.projectPath, default: []].append(target)
    }
    return order.map { path in
      let rows = byProject[path] ?? []
      return OpenTargetGroup(
        projectPath: path, projectName: rows.first?.projectName ?? "", rows: rows)
    }
  }

  static func clamped(_ index: Int, count: Int) -> Int {
    PickerModel.clamped(index, count: count)
  }

  static func move(highlight: Int, by delta: Int, count: Int) -> Int {
    PickerModel.move(highlight: highlight, by: delta, count: count)
  }

  static func selection(filtered: [OpenTarget], highlight: Int) -> OpenTarget? {
    PickerModel.selection(filtered: filtered, highlight: highlight)
  }
}
