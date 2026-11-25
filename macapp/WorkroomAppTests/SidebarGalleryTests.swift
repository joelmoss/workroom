import XCTest

@testable import Workroom

/// The sidebar gallery (`-WorkroomUITestSidebarGallery`) is only worth looking at if every row
/// shows what its entry says: each seam it seeds through no-ops quietly on a missing tab or target,
/// so this walks the table and reads each row's model back.
@MainActor
final class SidebarGalleryTests: XCTestCase {
  private typealias Gallery = SidebarGallery

  private func seededStore() -> AppStore {
    let store = AppStore()
    store.projectStore.projects = Gallery.projects()
    Gallery.seed(store)
    return store
  }

  func testEveryProjectRowShowsWhatItsEntrySays() throws {
    let store = seededStore()
    for entry in Gallery.projectEntries {
      let path = Gallery.projectPath(entry)
      let project = try XCTUnwrap(store.projectStore.project(at: path), entry.name)
      XCTAssertEqual(store.collapsedProjects.contains(path), entry.collapsed, entry.name)
      check(entry.root, project.rootTarget, in: store, "\(entry.name) root")
      for room in entry.rooms {
        let workroom = try XCTUnwrap(project.workrooms.first { $0.name == room.name }, room.name)
        let target = workroom.target(inProject: path)
        check(room.target, target, in: store, room.name)
        XCTAssertEqual(workroom.displayName, room.label ?? room.name, room.name)
        XCTAssertEqual(workroom.warnings.isEmpty, room.warning == nil && !room.missing, room.name)
        XCTAssertEqual(workroom.host?.kind, room.host?.kind, room.name)
        XCTAssertEqual(
          store.lifecycle.isSetupPending(workroom, inProject: path),
          room.host?.setupPending == true, room.name)
        let run = store.lifecycle.creationRun(for: .workroom(project: path, name: room.name))
        XCTAssertEqual(run != nil, room.target.create != nil, room.name)
        if room.target.create == .failed {
          XCTAssertTrue(WorkroomLifecycle.CreateStep(try XCTUnwrap(run)).failed, room.name)
        }
      }
      let provisional = store.lifecycle.creationRuns.values.filter {
        $0.project.path == path && $0.name == nil
      }
      XCTAssertEqual(provisional.count, entry.provisionalCreate == nil ? 0 : 1, entry.name)
    }
  }

  /// The Open section (#819) lists the gallery's workroom tabs, the standalone terminals and groups
  /// among them, with tab rows under the ones the gallery unfolds.
  func testTheOpenSectionShowsTheGallerysWorkroomTabs() throws {
    let store = seededStore()
    let rows = store.openSectionRows()
    let standalones = rows.filter { if case .standalone = $0.sid { true } else { false } }
    XCTAssertEqual(standalones.count, Gallery.standaloneTerminals.count)
    XCTAssertTrue(rows.contains { if case .terminalGroup = $0.sid { true } else { false } })
    XCTAssertTrue(rows.contains { if case .workroom = $0.sid { true } else { false } })
    XCTAssertTrue(rows.contains { !$0.isFolded && !$0.tabs.isEmpty }, "some show their tabs")
  }

  func testEveryTerminalsSectionRowShowsWhatItsEntrySays() throws {
    let store = seededStore()
    let section = store.terminalsSection
    let standalones = section.rows.filter {
      if case .standalone = $0 { return true }
      return false
    }
    XCTAssertEqual(standalones.count, Gallery.standaloneTerminals.count)
    for (entry, terminal) in zip(standalones, Gallery.standaloneTerminals) {
      let target = try XCTUnwrap(store.target(for: entry.sidebarID))
      check(
        Gallery.Target(terminals: [terminal]), target, in: store, "standalone \(terminal.title)")
      // A finished one shows its check on its row.
      XCTAssertEqual(
        store.terminals.statusSummary(forTargetID: target.id).done > 0,
        terminal.mark == .done || terminal.mark == .doneStale,
        "standalone \(terminal.title): done")
    }
    let groups = section.rows.compactMap { row -> TerminalGroup? in
      if case .group(let group) = row, !group.isBuiltIn { return group }
      return nil
    }
    XCTAssertEqual(groups.map(\.name), Gallery.groups.map(\.name))
    for (group, entry) in zip(groups, Gallery.groups) {
      XCTAssertEqual(group.isFolded, entry.folded, entry.name ?? "unnamed")
      let target = try XCTUnwrap(store.target(for: .terminalGroup(group.id)))
      check(
        Gallery.Target(terminals: entry.terminals), target, in: store,
        "group \(entry.name ?? "unnamed")")
    }
  }

  /// `seed`'s row reads its terminals as `seed` says, each terminal its own mark, and its run,
  /// expansion and unread dot.
  private func check(
    _ seed: Gallery.Target, _ target: TerminalTarget, in store: AppStore, _ name: String
  ) {
    let activity = store.sidebarActivity(of: target.id)
    XCTAssertEqual(activity.waiting, seed.waiting, "\(name): waiting")
    XCTAssertEqual(activity.waitingStale, seed.waitingStale, "\(name): stale")
    XCTAssertEqual(activity.failed, seed.failed, "\(name): failed")
    XCTAssertEqual(activity.running, seed.running, "\(name): running")
    let tabs = store.terminals.tabs(for: target)
    XCTAssertEqual(tabs.count, seed.terminals.count, "\(name): terminals")
    for (tab, terminal) in zip(tabs, seed.terminals) {
      XCTAssertEqual(tab.indicator, indicator(terminal.mark), "\(name): \(terminal.title)")
      XCTAssertEqual(tab.terminal?.liveTitle, terminal.title, name)
      XCTAssertEqual(tab.terminal?.userTitle, terminal.name, name)
      if terminal.tool != nil { XCTAssertNotNil(tab.recognizedTool, "\(name): \(terminal.title)") }
      if terminal.unread {
        XCTAssertGreaterThan(store.notifications.count(tab: tab.id), 0, "\(name): unread tab")
      }
    }
    XCTAssertEqual(store.isTerminalsExpanded(target.id), seed.expanded, "\(name): expanded")
    let state = store.runCommand.runStates[target.id]
    XCTAssertEqual(state?.isRunning ?? false, seed.run != nil, "\(name): run")
    XCTAssertEqual(state?.isStopping ?? false, seed.run == .stopping, "\(name): stopping")
    if seed.unread {
      XCTAssertGreaterThan(store.notifications.count(target: target.id), 0, "\(name): unread")
    }
  }

  private func indicator(_ mark: Gallery.Mark) -> PaneIndicator {
    switch mark {
    case .idle: .none
    case .busy: .running(failed: false)
    case .waiting, .waitingStale: .blocked
    case .failed: .error
    case .done, .doneStale: .done
    }
  }
}
