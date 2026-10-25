import AppKit
import SwiftUI
import WorkroomSystem
import XCTest

@testable import Workroom

private struct UsageFixtureRunner: StatusCommandRunning {
  let executable: URL

  func run(_ name: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    await StatusCommandRunner().run(executable.path, args, in: directory, timeout: timeout)
  }
}

/// Real usage process transports against owned local scripts: no accounts, credentials or network.
@MainActor
final class UsagePollingBenchmarkTests: XCTestCase {
  func testStartupProcessPlacement() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-usage")
    let output = BenchmarkFixtures.reportURL(named: "usage-polling")
    var samples: [[String: Any]] = []
    for _ in 0..<3 {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "usage-launch-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let log = directory.appendingPathComponent("processes")
      let cswap = directory.appendingPathComponent("cswap")
      let codex = directory.appendingPathComponent("codex")
      try """
      #!/bin/sh
      printf 'cswap %s\\n' "$$" >> '\(log.path)'
      printf '%s\\n' '{"schemaVersion":1,"accounts":[]}'
      """.write(to: cswap, atomically: true, encoding: .utf8)
      try """
      #!/bin/sh
      printf 'codex %s\\n' "$$" >> '\(log.path)'
      while IFS= read -r line; do
        case "$line" in
          *rateLimits*) printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000000000}}}}' ;;
        esac
      done
      """.write(to: codex, atomically: true, encoding: .utf8)
      for script in [cswap, codex] {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      }
      let start = ContinuousClock.now
      let main = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      let monitor = CodingAgentUsageMonitor(
        codexSessionsURL: directory.appendingPathComponent("sessions"),
        claudeCacheURL: directory.appendingPathComponent("bridge.json"),
        pollers: CodingAgentUsagePollers(
          cswap: { await CswapUsage.read(runner: UsageFixtureRunner(executable: cswap), now: $0) },
          codexServer: {
            await CodexAppServerUsage.read(
              transport: CodexAppServerUsage.processTransport(executable: codex), now: $0)
          }), pollingEnabled: { true })
      let constructionCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - main) / 1e6
      let constructionMS = Self.milliseconds(start.duration(to: .now))
      // Controlled scene-creation gap, not a claim about production launch duration.
      try await Task.sleep(for: .milliseconds(250))
      let beforeDisplay = Self.processes(log)
      XCTAssertEqual(beforeDisplay.count, 0, "automatic usage reads must wait for window display")
      let hosting = NSHostingView(
        rootView: Text("Usage launch fixture").frame(width: 400, height: 200)
          .background(UsagePollingAfterDisplay(monitor: monitor)))
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = hosting
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      hosting.layoutSubtreeIfNeeded()
      hosting.displayIfNeeded()
      CATransaction.flush()
      NSApp.updateWindows()
      let displayMS = Self.milliseconds(start.duration(to: .now))
      let atDisplay = Self.processes(log)
      XCTAssertEqual(atDisplay.count, 0, "automatic usage reads must stay out of first display")
      for _ in 0..<300 where monitor.completedPollCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(monitor.completedPollCount, 1)
      XCTAssertEqual(monitor.snapshot(for: .codex)?.windows.first?.usedPercentage, 20)
      XCTAssertNotNil(monitor.claudeAccounts)
      let readyMS = Self.milliseconds(start.duration(to: .now))
      let processes = Self.processes(log)
      XCTAssertEqual(processes.count, 2, "one process per provider")
      let pids = processes.compactMap { Int32($0.split(separator: " ").last ?? "") }
      for _ in 0..<100 where pids.contains(where: { kill($0, 0) == 0 }) {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(pids.contains(where: { kill($0, 0) == 0 }), "usage children must exit")
      samples.append([
        "construction_elapsed_ms": constructionMS, "construction_main_cpu_ms": constructionCPU,
        "processes_before_display": beforeDisplay.count, "processes_total": processes.count,
        "processes_at_display": atDisplay.count, "display_submitted_ms": displayMS,
        "usage_ready_ms": readyMS,
      ])
    }
    try BenchmarkFixtures.write(["configuration": "Debug", "samples": samples], to: output)
  }

  private static func processes(_ log: URL) -> [String] {
    (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
}
