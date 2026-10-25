import XCTest

@testable import Workroom

@MainActor
final class StartupReadBenchmarkTests: XCTestCase {
  func testOwnedSettingsAndSessionReads() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-startup-reads")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "startup-reads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = directory.appendingPathComponent("settings.json")
    try JSONSerialization.data(withJSONObject: [
      "fixturePadding": String(repeating: "x", count: 65_536)
    ])
    .write(to: settings)
    let bridgeDirectory = directory.appendingPathComponent("bridge")
    let bridge = ClaudeUsageBridge(settingsURL: settings, directoryURL: bridgeDirectory)
    try bridge.enable()
    XCTAssertEqual(bridge.state, .enabled)
    let targets = (0..<16).map { index in
      TargetSession(
        targetID: "root|\(directory.path)/\(index)",
        tabs: (0..<4).map { pane in
          TabSession(
            key: "pane-\(pane)", kind: TabSession.terminalKind,
            terminal: TerminalPayload(
              defaultTitle: "Terminal \(pane + 1)", cwd: directory.path,
              sessionID: UUID().uuidString))
        })
    }
    let sessionURL = directory.appendingPathComponent("session.json")
    let store = SessionStore(url: sessionURL)
    XCTAssertTrue(
      store.writeSynchronously(
        SessionFile(
          savedAt: Date(), windows: [WindowSession(windowKey: UUID().uuidString, targets: targets)])
      ))
    var settingsMS: [Double] = []
    var sessionMS: [Double] = []
    for _ in 0..<10 {
      var start = DispatchTime.now().uptimeNanoseconds
      let reader = ClaudeUsageBridge(settingsURL: settings, directoryURL: bridgeDirectory)
      settingsMS.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
      XCTAssertEqual(reader.state, .enabled)
      start = DispatchTime.now().uptimeNanoseconds
      let result = SessionStore(url: sessionURL).read()
      sessionMS.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
      guard case .restored(let file, let report) = result else {
        return XCTFail("the fixture session must decode")
      }
      XCTAssertTrue(report.isEmpty)
      XCTAssertEqual(file.windows.first?.targets.flatMap(\.tabs).count, 64)
    }
    try BenchmarkFixtures.write(
      [
        "configuration": "Debug", "cache": "warm filesystem after owned fixture writes",
        "settings_bytes": try Data(contentsOf: settings).count,
        "session_bytes": try Data(contentsOf: sessionURL).count,
        "bridge_initialization_ms": settingsMS, "session_read_ms": sessionMS,
      ], to: BenchmarkFixtures.reportURL(named: "startup-reads"))
  }
}
