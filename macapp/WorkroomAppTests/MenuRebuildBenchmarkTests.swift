import AppKit
import Observation
import SwiftUI
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

@MainActor
final class MenuRebuildBenchmarkTests: XCTestCase {
  @Observable fileprivate final class Flags {
    var hasNotifications = false
  }

  private struct FixtureRoot: View {
    let store: AppStore
    let flags: Flags

    var body: some View {
      TextField("Menu fixture", text: .constant("Focus"))
        .focusedSceneValue(store)
        .focusedValue(store)
        .modifier(RoomCommandStateValues(store: store))
        .focusedSceneValue(\.hasProjects, true)
        .focusedSceneValue(\.hasNotifications, flags.hasNotifications)
        .frame(width: 300, height: 100)
    }
  }

  private func items(_ title: String, in menu: NSMenu?) -> [NSMenuItem] {
    var found: [NSMenuItem] = []
    for entry in menu?.items ?? [] {
      if entry.title == title { found.append(entry) }
      found += items(title, in: entry.submenu)
    }
    return found
  }

  private func item(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
    items(title, in: menu).last
  }

  private func flush(_ hosting: NSView) async {
    hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(30))
    hosting.layoutSubtreeIfNeeded()
    NSApp.mainMenu?.update()
    item("Room", in: NSApp.mainMenu)?.submenu?.update()
  }

  private func menuStateWhileOpen(_ title: String, window: NSWindow) -> [String: Bool]? {
    guard let menu = item(title, in: NSApp.mainMenu)?.submenu else { return nil }
    var state: [String: Bool]?
    let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
      MainActor.assumeIsolated {
        state = Dictionary(
          menu.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0.isEnabled) },
          uniquingKeysWith: { _, new in new })
        menu.cancelTracking()
      }
    }
    RunLoop.main.add(timer, forMode: .eventTracking)
    defer { timer.invalidate() }
    menu.popUp(positioning: nil, at: NSPoint(x: window.frame.midX, y: window.frame.midY), in: nil)
    return state
  }

  private func commitEnabledWhileOpen(_ window: NSWindow) -> Bool? {
    menuStateWhileOpen("Room", window: window)?["Commit…"]
  }

  func testUnrelatedStatusDoesNotRebuildCommands() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-menu")
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("the real-scene menu harness requires macOS 26")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppStore()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = (0..<32).map { index in
      let path = index == 0 ? directory.path : "/menu-benchmark/project-\(index)"
      return Project(
        path: path, vcs: "git",
        workrooms: (0..<5).map {
          Workroom(
            name: "room-\($0)", path: "\(path)/room-\($0)", vcsName: "room-\($0)", warnings: [])
        })
    }
    let selected = SidebarID.root(project: directory.path)
    let other = SidebarID.root(project: store.projects[1].path)
    let target = try XCTUnwrap(store.target(for: selected))
    _ = store.terminals.addTab(for: target)
    store.selectedTargetID = selected
    store.selectionStatusTask?.cancel()
    store.refreshSelectionHasTabs()
    store.workroomStatuses[selected] = WorkroomStatus(dirty: false)
    XCTAssertEqual(store.inspectorTargetID, selected)

    let flags = Flags()
    let root = FixtureRoot(store: store, flags: flags)
    let sceneID = "menu-benchmark-\(UUID().uuidString)"
    let updater = Updater()
    let representation = NSHostingSceneRepresentation {
      Window(sceneID, id: sceneID) { root }
        .commandsRemoved()
        .commands { WorkroomCommands(updater: updater) }
    }
    NSApp.addSceneRepresentation(representation)
    representation.environment.openWindow(id: sceneID)
    for _ in 0..<100 {
      if NSApp.windows.contains(where: { $0.title == sceneID }) { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    let window = try XCTUnwrap(
      NSApp.windows.first(where: { $0.title == sceneID }), "must open the real benchmark scene")
    let hosting = try XCTUnwrap(window.contentView)
    let previousPolicy = NSApp.activationPolicy()
    let policyChanged = NSApp.setActivationPolicy(.regular)
    defer { NSApp.setActivationPolicy(previousPolicy) }
    let activationRequested = NSRunningApplication.current.activate(
      options: [.activateAllWindows, .activateIgnoringOtherApps])
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    defer {
      window.close()
      Task { await store.terminals.reapAll() }
    }
    await flush(hosting)
    XCTAssertNotNil(item("Commit…", in: NSApp.mainMenu), "must host the real Room menu")
    store.mergeLocalStatus(WorkroomStatus(dirty: true), into: selected)
    XCTAssertTrue(store.canCommit(selected), "fixture must have committable changes")
    await flush(hosting)
    guard commitEnabledWhileOpen(window) == true else {
      return XCTFail(
        "menu did not enable Commit; active=\(NSApp.isActive), key=\(window.isKeyWindow), "
          + "visible=\(window.isVisible), canBecomeKey=\(window.canBecomeKey), "
          + "policy=\(NSApp.activationPolicy().rawValue), policyChanged=\(policyChanged), activation=\(activationRequested), "
          + "canCommit=\(store.canCommit(selected)), modal=\(store.hasModalPresentation), "
          + "inspected=\(String(describing: store.inspectorTargetID)), passes=\(WorkroomCommands.bodyPasses), "
          + "nativeItems=\(items("Commit…", in: NSApp.mainMenu).map { $0.isEnabled })")
    }
    store.mergeLocalStatus(WorkroomStatus(dirty: false), into: selected)
    await flush(hosting)
    XCTAssertEqual(
      commitEnabledWhileOpen(window), false,
      "selected clean status must disable Commit again")

    let pr = PullRequestInfo(
      number: 12, title: "A change", state: .open, isDraft: true,
      url: "https://github.com/example/repo/pull/12", reviewDecision: nil, reviewers: [])
    store.workroomStatuses[selected] = WorkroomStatus(dirty: true, pr: pr)
    await flush(hosting)
    var room = try XCTUnwrap(menuStateWhileOpen("Room", window: window))
    XCTAssertEqual(room["Go to Pull Request"], true)
    XCTAssertEqual(room[PRAction.markReady.label], true)
    store.prActionInFlight = true
    await flush(hosting)
    room = try XCTUnwrap(menuStateWhileOpen("Room", window: window))
    XCTAssertEqual(room[PRAction.markReady.label], false)
    store.prActionInFlight = false
    store.auxSheetPresented = true
    await flush(hosting)
    room = try XCTUnwrap(menuStateWhileOpen("Room", window: window))
    XCTAssertEqual(room["Commit…"], false)
    XCTAssertNil(room["Go to Pull Request"], "a modal hides inspected PR actions")
    store.auxSheetPresented = false
    await flush(hosting)
    room = try XCTUnwrap(menuStateWhileOpen("Room", window: window))
    XCTAssertEqual(room[PRAction.markReady.label], true)
    store.workroomStatuses[selected] = WorkroomStatus(dirty: false)
    await flush(hosting)
    XCTAssertEqual(commitEnabledWhileOpen(window), false)
    await flush(hosting)
    try? await Task.sleep(for: .milliseconds(100))

    var idleCPU: [Double] = []
    var idlePasses: [Int] = []
    for _ in 0..<3 {
      WorkroomCommands.bodyPasses = 0
      let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      await flush(hosting)
      idleCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000)
      idlePasses.append(WorkroomCommands.bodyPasses)
      XCTAssertEqual(
        WorkroomCommands.bodyPasses, 0, "native validation alone must not rebuild commands")
    }

    var samples: [Double] = []
    var passes: [Int] = []
    for sample in 0..<3 {
      WorkroomCommands.bodyPasses = 0
      let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      store.mergeLocalStatus(WorkroomStatus(dirty: sample.isMultiple(of: 2)), into: other)
      await flush(hosting)
      samples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000)
      passes.append(WorkroomCommands.bodyPasses)
      XCTAssertEqual(
        WorkroomCommands.bodyPasses, 0, "an unrelated target must not rebuild commands")
      XCTAssertFalse(
        item("Commit…", in: NSApp.mainMenu)?.isEnabled == true, "the inspected target remains clean"
      )
    }
    var flagCPU: [Double] = []
    var flagPasses: [Int] = []
    for _ in 0..<3 {
      WorkroomCommands.bodyPasses = 0
      let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      flags.hasNotifications.toggle()
      await flush(hosting)
      flagCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000)
      flagPasses.append(WorkroomCommands.bodyPasses)
      XCTAssertEqual(
        menuStateWhileOpen("Go", window: window)?["Next Notification"], flags.hasNotifications,
        "focused-value changes must still reach the native menu")
      await flush(hosting)
    }
    try BenchmarkFixtures.write(
      [
        "projects": 32, "unrelated_status_cpu_ms": samples, "command_passes": passes,
        "idle_cpu_ms": idleCPU, "idle_passes": idlePasses,
        "focused_flag_cpu_ms": flagCPU, "focused_flag_passes": flagPasses,
      ],
      to: BenchmarkFixtures.reportURL(named: "menu-rebuild"))
  }
}
