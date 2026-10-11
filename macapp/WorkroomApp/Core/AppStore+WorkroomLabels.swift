import Defaults
import Foundation
import WorkroomDomain

/// Workroom labels (issue #41): the GUI-only display names kept in `Defaults[.workroomLabels]` and
/// merged onto the CLI's model. Moved out of `AppStore.swift` as is. Coupling points left on
/// `AppStore`: `projects`, which these methods read and rewrite, and the load and delete paths that
/// call `enrichLabels`, `pruneOrphanedLabels` and `forgetLabels`.
extension AppStore {
  // MARK: - Workroom labels (issue #41)

  /// Inject each workroom's GUI-only display label from `Defaults[.workroomLabels]` onto the freshly
  /// decoded model. The CLI JSON never carries a label, so this is the one point the app-side store
  /// is merged into `projects`. Pure transform — no side effects — so it's reused by both `apply`
  /// (full reload) and the targeted label mutators below. `internal` so it's a unit-test seam (the
  /// `apply` path that calls it is private).
  func enrichLabels(_ incoming: [Project]) -> [Project] {
    let labels = Defaults[.workroomLabels]
    guard !labels.isEmpty else { return incoming }
    return incoming.map { project in
      Project(
        path: project.path, vcs: project.vcs,
        workrooms: project.workrooms.map { wr in
          var wr = wr
          wr.label = labels[TerminalTarget.workroomID(project: project.path, name: wr.name)]
          return wr
        }, host: project.host, baseBranch: project.baseBranch)
    }
  }

  /// Garbage-collect labels whose workroom no longer exists in `live` (deleted via the CLI or
  /// another build) so the map stays bounded and a recreated same-named workroom can't inherit a
  /// stale label. Safe to run on every load because `apply` always receives the complete configured
  /// set (`ListData`/`AllProjects`). `internal` so it's a unit-test seam.
  func pruneOrphanedLabels(keeping live: [Project]) {
    let labels = Defaults[.workroomLabels]
    guard !labels.isEmpty else { return }
    var liveKeys = Set<String>()
    for project in live {
      for wr in project.workrooms {
        liveKeys.insert(TerminalTarget.workroomID(project: project.path, name: wr.name))
      }
    }
    let pruned = labels.filter { liveKeys.contains($0.key) }
    if pruned.count != labels.count { Defaults[.workroomLabels] = pruned }
  }

  /// Drop the stored labels for the named workrooms of a project (used by the delete paths so an
  /// in-app delete clears the label immediately, not just on the next prune-on-load).
  func forgetLabels(forProject path: String, workroomNames: [String]) {
    var labels = Defaults[.workroomLabels]
    var changed = false
    for name in workroomNames {
      if labels.removeValue(forKey: TerminalTarget.workroomID(project: path, name: name)) != nil {
        changed = true
      }
    }
    if changed { Defaults[.workroomLabels] = labels }
  }

  /// The name to show for a workroom referenced only by `SidebarID`/name (the tab chip and window
  /// title, which never hold the `Workroom` value). Resolves through the enriched model so there's a
  /// single read path, falling back to the real `name` when the workroom isn't in `projects` yet
  /// (a mid-reload race) — mirroring `windowTitle`'s own fallback.
  func displayName(forWorkroom name: String, inProject path: String) -> String {
    projects.first { $0.id == path }?.workrooms.first { $0.id == name }?.displayName ?? name
  }

  /// Set (or, for a blank value, remove) a workroom's display label (issue #41). Normalises at the
  /// write boundary so the stored value is always trimmed and non-empty — `displayName`'s guard is
  /// then just defense-in-depth. App-only: writes `Defaults` and rebuilds the one affected project in
  /// the shared `projects`, so every window re-renders instantly with no CLI call and without running
  /// the heavyweight `apply` (which would needlessly re-validate selection and prune splits).
  func setWorkroomLabel(_ workroom: Workroom, in project: Project, to raw: String) {
    let key = TerminalTarget.workroomID(project: project.path, name: workroom.name)
    var labels = Defaults[.workroomLabels]
    if let normalized = Workroom.normalizedLabel(raw) {
      labels[key] = normalized
    } else {
      // Blank input means "no label". The sheet disables submit on blank, so this branch is reached
      // only via `removeWorkroomLabel` (or defensively) — removal is the explicit menu action.
      labels[key] = nil
    }
    Defaults[.workroomLabels] = labels
    relabelLocally(workroom.name, in: project.path, to: labels[key])
  }

  /// Remove a workroom's display label, restoring its real name everywhere. Raised by the
  /// "Remove Label" context-menu item.
  func removeWorkroomLabel(_ workroom: Workroom, in project: Project) {
    setWorkroomLabel(workroom, in: project, to: "")
  }

  /// Targeted single-workroom rebuild of the shared `projects` (mirrors `removeWorkroomLocally`):
  /// replace just the one workroom with a copy carrying the new label, leaving sort order, selection,
  /// and splits untouched (a label never changes any of them). `internal` so store tests can drive it.
  func relabelLocally(_ name: String, in projectPath: String, to label: String?) {
    guard let pIdx = projects.firstIndex(where: { $0.id == projectPath }),
      let wIdx = projects[pIdx].workrooms.firstIndex(where: { $0.id == name })
    else { return }
    var workrooms = projects[pIdx].workrooms
    var wr = workrooms[wIdx]
    wr.label = label
    workrooms[wIdx] = wr
    let p = projects[pIdx]
    projects[pIdx] = Project(
      path: p.path, vcs: p.vcs, workrooms: workrooms, host: p.host, baseBranch: p.baseBranch)
  }
}
