import AppKit
import SwiftUI
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// Exercises the real List at the sizes in #534, with no terminals, git probes or real projects.
/// Timings include layout and SwiftUI update processing, not the fixture construction.
@MainActor
final class SidebarBenchmarkTests: XCTestCase {
  /// VCS and notification badge changes must not rewalk every project/workroom row. The scaling
  /// fixture measured all 224 rows rebuilding before either observation boundary was moved.
  func testVCSAndNotificationUpdatesDoNotRebuildSidebarRows() throws {
    let store = AppStore()
    store.projects = (0..<32).map { index in
      let path = "/sidebar-invalidation/project-\(index)"
      return Project(
        path: path, vcs: "git",
        workrooms: (0..<5).map {
          Workroom(
            name: "room-\($0)", path: "\(path)/room-\($0)", vcsName: "room-\($0)", warnings: [])
        })
    }
    store.collapsedProjects = []
    let id = SidebarID.root(project: store.projects[0].path)
    store.workroomStatuses[id] = WorkroomStatus(dirty: false)
    ProjectSidebar.rowEvaluations = 0
    let hosting = NSHostingView(
      rootView: ProjectSidebar()
        .environmentObject(store)
        .environmentObject(store.notifications)
        .environmentObject(store.terminals)
        .frame(width: 300, height: 700))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    settle(hosting)
    hosting.displayIfNeeded()
    XCTAssertGreaterThan(ProjectSidebar.rowEvaluations, 0, "must render actual rows")
    ProjectSidebar.rowEvaluations = 0
    store.mergeLocalStatus(WorkroomStatus(dirty: true), into: id)
    settle(hosting)
    XCTAssertEqual(ProjectSidebar.rowEvaluations, 0, "a VCS badge change must not rebuild the tree")
    store.mergeLocalStatus(WorkroomStatus(dirty: false), into: id)
    settle(hosting)
    XCTAssertEqual(ProjectSidebar.rowEvaluations, 0)
    store.notifications.recordNotice(
      targetID: TerminalTarget.rootID(project: store.projects[0].path),
      source: "fixture", title: "Needs attention", body: nil)
    settle(hosting)
    XCTAssertEqual(store.notifications.total, 1, "the notice must actually be recorded")
    XCTAssertEqual(
      ProjectSidebar.rowEvaluations, 0, "a badge update must not rebuild the sidebar row tree")
  }

  private func draw(_ view: NSView) async {
    view.layoutSubtreeIfNeeded()
    // Yield the main actor as well as pumping AppKit: nested RunLoop waits alone do not let all
    // deferred SwiftUI work run. CPU time below excludes this fixed scheduling allowance.
    try? await Task.sleep(for: .milliseconds(20))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
  }

  /// Uses the binding used by the real onHover handlers, isolating state invalidation from native
  /// pointer-event delivery. A pointer entering one row must not rebuild unrelated rows.
  func testHoverOnlyRebuildsItsOwnRow() async throws {
    let store = AppStore()
    store.projects = (0..<32).map { index in
      let path = "/sidebar-hover/project-\(index)"
      return Project(
        path: path, vcs: "git",
        workrooms: (0..<5).map {
          Workroom(
            name: "room-\($0)", path: "\(path)/room-\($0)", vcsName: "room-\($0)", warnings: [])
        })
    }
    store.collapsedProjects = []
    let id = SidebarID.root(project: store.projects[0].path)
    var hover: Binding<Bool>?
    ProjectSidebar.didRenderHover = { rowID, binding in
      if rowID == id { hover = binding }
    }
    defer { ProjectSidebar.didRenderHover = nil }
    let hosting = NSHostingView(
      rootView: ProjectSidebar()
        .environmentObject(store)
        .environmentObject(store.notifications)
        .environmentObject(store.terminals)
        .frame(width: 300, height: 700))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    await draw(hosting)
    settle(hosting)
    XCTAssertNotNil(hover, "the actual root row must register its hover binding")
    func findTable(_ view: NSView) -> NSTableView? {
      if let table = view as? NSTableView { return table }
      return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    let list = try XCTUnwrap(findTable(hosting), "must host the native List")
    XCTAssertEqual(list.numberOfRows, 224, "the hover wrappers must preserve individual List rows")
    var samples: [Double] = []
    var rows: [Int] = []
    for _ in 0..<3 {
      ProjectSidebar.rowEvaluations = 0
      let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      hover?.wrappedValue = !(hover?.wrappedValue ?? false)
      await draw(hosting)
      samples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000)
      rows.append(ProjectSidebar.rowEvaluations)
      XCTAssertGreaterThan(ProjectSidebar.rowEvaluations, 0, "hover must repaint its row")
      XCTAssertLessThan(ProjectSidebar.rowEvaluations, 5, "one hover must not rewalk all 224 rows")
    }
    try BenchmarkFixtures.write(
      ["projects": 32, "workrooms_per_project": 5, "hover_cpu_ms": samples, "hover_rows": rows],
      to: BenchmarkFixtures.reportURL(named: "sidebar-hover"))
    store.collapsedProjects.insert(store.projects[0].path)
    await draw(hosting)
    settle(hosting)
    XCTAssertEqual(list.numberOfRows, 218, "collapse removes the root and five workrooms")
    store.collapsedProjects.remove(store.projects[0].path)
    await draw(hosting)
    settle(hosting)
    XCTAssertEqual(list.numberOfRows, 224, "expand restores every row")
  }

  func testSidebarScaling() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-sidebar")
    var reports: [[String: Any]] = []
    for count in [8, 16, 32, 64] {
      let store = AppStore()
      store.projects = (0..<count).map { index in
        let path = "/sidebar-benchmark/project-\(index)"
        return Project(
          path: path, vcs: "git",
          workrooms: (0..<5).map {
            Workroom(
              name: "room-\($0)", path: "\(path)/room-\($0)", vcsName: "room-\($0)", warnings: [])
          })
      }
      store.collapsedProjects = []
      store.notifications.seedForTesting(
        (0..<500).map { index in
          WorkroomNotification(
            id: UUID(),
            targetID: TerminalTarget.rootID(project: store.projects[index % count].path),
            tabID: UUID(), source: "fixture", title: "Notification \(index)", body: nil,
            date: Date(), count: 1)
        })
      let root = ProjectSidebar()
        .environmentObject(store)
        .environmentObject(store.notifications)
        .environmentObject(store.terminals)
        .frame(width: 300, height: 700)
      let hosting = NSHostingView(rootView: root)
      hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
      let window = NSWindow(
        contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      ProjectSidebar.rowEvaluations = 0
      ProjectSidebar.menuEvaluations = 0
      let start = DispatchTime.now().uptimeNanoseconds
      let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      window.contentView = hosting
      window.makeKeyAndOrderFront(nil)
      await draw(hosting)
      let initialMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      let initialCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
      settle(hosting)
      XCTAssertGreaterThan(ProjectSidebar.rowEvaluations, 0, "must render actual sidebar rows")
      let initialRows = ProjectSidebar.rowEvaluations
      let initialMenus = ProjectSidebar.menuEvaluations

      var samples: [Double] = []
      var cpuSamples: [Double] = []
      var rows: [Int] = []
      var menus: [Int] = []
      for sample in 0..<3 {
        ProjectSidebar.rowEvaluations = 0
        ProjectSidebar.menuEvaluations = 0
        let start = DispatchTime.now().uptimeNanoseconds
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        store.mergeLocalStatus(
          WorkroomStatus(dirty: sample.isMultiple(of: 2)),
          into: .root(project: store.projects[0].path))
        await draw(hosting)
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        cpuSamples.append(
          Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000)
        settle(hosting)
        rows.append(ProjectSidebar.rowEvaluations)
        menus.append(ProjectSidebar.menuEvaluations)
      }
      var notificationCPU: [Double] = []
      var notificationRows: [Int] = []
      for sample in 0..<3 {
        ProjectSidebar.rowEvaluations = 0
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        store.notifications.recordNotice(
          targetID: TerminalTarget.rootID(project: store.projects[0].path),
          source: "fixture", title: "New notice \(sample)", body: nil)
        await draw(hosting)
        notificationCPU.append(
          Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000)
        settle(hosting)
        notificationRows.append(ProjectSidebar.rowEvaluations)
      }
      let report: [String: Any] = [
        "projects": count, "workrooms_per_project": 5, "notifications": 500,
        "initial_ms": initialMS, "initial_cpu_ms": initialCPU, "initial_rows": initialRows,
        "initial_menu_entries": initialMenus,
        "status_ms": samples, "status_cpu_ms": cpuSamples,
        "status_rows": rows, "status_menu_entries": menus,
        "notification_cpu_ms": notificationCPU, "notification_rows": notificationRows,
      ]
      print("SIDEBAR \(report)")
      reports.append(report)
      window.close()
    }
    try BenchmarkFixtures.write(
      ["configuration": "Debug", "sizes": reports],
      to: BenchmarkFixtures.reportURL(named: "sidebar"))
  }
}
