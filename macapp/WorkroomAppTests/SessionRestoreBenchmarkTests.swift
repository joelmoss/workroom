import AppKit
import Darwin
import WorkroomWire
import XCTest

@testable import Workroom

/// Real recovery loop and engine against owned inert children, never saved user sessions.
@MainActor
final class SessionRestoreBenchmarkTests: XCTestCase {
  @MainActor private final class Heartbeat {
    var last = DispatchTime.now().uptimeNanoseconds
    var largestGapMS = 0.0
    func tick() {
      let now = DispatchTime.now().uptimeNanoseconds
      largestGapMS = max(largestGapMS, Double(now - last) / 1e6)
      last = now
    }
  }

  func testStaleSocketCost() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-restore")
    let directory = URL(fileURLWithPath: "/tmp/wr-stale-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("session.sock").path
    let listener = try UnixSocketListener.listen(at: path)
    close(listener)
    let client = PersistentSessionControlClient(socketPath: path)
    let ids = (0..<16).map { _ in SessionIdentifier(UUID()) }
    var samples: [Double] = []
    for _ in 0..<5 {
      let start = DispatchTime.now().uptimeNanoseconds
      for id in ids {
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        guard case .notOwned = client.ownership(identifier: id) else {
          return XCTFail("a stale socket must be a definitive no")
        }
      }
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    try BenchmarkFixtures.write(
      ["probes_per_sample": ids.count, "elapsed_ms": samples],
      to: BenchmarkFixtures.reportURL(named: "session-restore").appendingPathExtension("stale.json")
    )
  }

  func testHiddenRestoreAndFirstMount() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-restore")
    var samples: [[String: Any]] = []
    for count in [1, 8, 16] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "restore-benchmark-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let launches = directory.appendingPathComponent("children")
      let sessions = TerminalSessions()
      sessions.recency = SwitcherRecency()
      sessions.sessionService = PersistentSessionService(
        probe: { _ in .unhealthy(reason: "owned restore benchmark") },
        ownership: { _ in .notOwned })
      sessions.makeView = { _, cwd, _ in
        let script =
          "printf '%s\\n' \"$$\" >> "
          + CommandLineInstaller.shellQuoted(launches.path)
          + "; IFS= read -r ignored; printf '\\033]9;restore fixture \(count)\\007'; IFS= read -r done"
        return GhosttySurfaceView(
          workingDirectory: cwd, command: "/bin/sh -c " + CommandLineInstaller.shellQuoted(script))
      }
      var views: [GhosttySurfaceView] = []
      var descriptors: [SessionDescriptor] = []
      defer { for view in views { view.tearDown() } }
      let restoreStart = DispatchTime.now().uptimeNanoseconds
      for index in 0..<count {
        let target = TerminalTarget(
          id: "root|\(directory.path)/\(index)", title: "Fixture \(index)",
          path: directory.path, isMissing: false)
        let id = UUID()
        sessions.restore(
          TargetSession(
            targetID: target.id,
            tabs: [
              TabSession(
                key: "pane", kind: TabSession.terminalKind,
                terminal: TerminalPayload(defaultTitle: "Terminal 1", sessionID: id.uuidString))
            ]),
          for: target)
        let view = try XCTUnwrap(sessions.tabs(for: target).first?.surface)
        // Keep the model's recovery identity, but engine creation runs our inert command rather
        // than touching a shared helper. The restore factory and recovery loop are unchanged.
        view.persistentSessionID = nil
        views.append(view)
        descriptors.append(
          SessionDescriptor(
            identifier: SessionIdentifier(id), shellProcessID: 123, ttyDevice: 0,
            workingDirectory: directory.path, isAttached: false,
            metadata: [SessionEnvironmentEntry(key: "command", value: "claude")]))
      }
      let restoreMS = Double(DispatchTime.now().uptimeNanoseconds - restoreStart) / 1e6
      let heartbeat = Heartbeat()
      let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
        MainActor.assumeIsolated { heartbeat.tick() }
      }
      defer { timer.invalidate() }
      let start = DispatchTime.now().uptimeNanoseconds
      let main = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      await sessions.materializeLivePersistentSessions(
        reattaches: { _ in true }, load: { descriptors })
      let mainMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - main) / 1e6
      let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
      heartbeat.tick()
      timer.invalidate()
      let hidden = views.filter { $0.surface != nil }.count
      XCTAssertEqual(sessions.activeCodingAgentBackends, [.claude], "metadata stays eager")
      try await Task.sleep(for: .milliseconds(250))
      let childrenBeforeMount = Self.children(launches).count
      let view = try XCTUnwrap(views.first)
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 800, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      let mountStart = DispatchTime.now().uptimeNanoseconds
      view.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
      window.contentView = view
      window.makeKeyAndOrderFront(nil)
      window.layoutIfNeeded()
      let mountMS = Double(DispatchTime.now().uptimeNanoseconds - mountStart) / 1e6
      XCTAssertNotNil(view.surface, "first mount must create the real engine")
      for _ in 0..<100 where Self.children(launches).count < max(1, hidden) {
        try await Task.sleep(for: .milliseconds(10))
      }
      let mounted = views.filter { $0.surface != nil }.count
      let children = Self.children(launches)
      samples.append([
        "panes": count, "restore_models_ms": restoreMS, "recovery_elapsed_ms": elapsedMS,
        "recovery_main_cpu_ms": mainMS, "hidden_surfaces": hidden,
        "largest_main_loop_gap_ms": heartbeat.largestGapMS,
        "children_before_mount": childrenBeforeMount, "first_mount_ms": mountMS,
        "surfaces_after_one_mount": mounted, "children_after_one_mount": children.count,
      ])
      if count > 1, let hiddenView = views.last {
        XCTAssertNil(hiddenView.window)
        var notifications: [TerminalActivity] = []
        hiddenView.onActivity = { notifications.append($0) }
        // The engine rate-limits desktop notifications globally. Each owned sample emits one.
        try await Task.sleep(for: .milliseconds(1_100))
        hiddenView.sendText("notify\r")
        for _ in 0..<100 where notifications.isEmpty {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(notifications.isEmpty, "a restored hidden program must still notify")
      }
      for view in views { view.tearDown() }
      for _ in 0..<100 where children.contains(where: { kill($0, 0) == 0 }) {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(children.contains(where: { kill($0, 0) == 0 }), "owned children must exit")
    }
    try BenchmarkFixtures.write(
      ["configuration": "Debug", "samples": samples],
      to: BenchmarkFixtures.reportURL(named: "session-restore"))
    for sample in samples {
      let count = try XCTUnwrap(sample["panes"] as? Int)
      XCTAssertEqual(sample["hidden_surfaces"] as? Int, count, "keep notification attachments")
      XCTAssertEqual(sample["children_before_mount"] as? Int, count)
      XCTAssertEqual(sample["surfaces_after_one_mount"] as? Int, count)
      XCTAssertEqual(sample["children_after_one_mount"] as? Int, count)
      if count == 16 {
        XCTAssertLessThan(
          try XCTUnwrap(sample["largest_main_loop_gap_ms"] as? Double), 80,
          "warm hidden recovery must leave room for main-loop work")
      }
    }
  }

  private static func children(_ log: URL) -> [pid_t] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
      .split(separator: "\n").compactMap { pid_t($0) }
  }
}
