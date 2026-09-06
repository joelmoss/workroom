import Foundation
import XCTest

@testable import Workroom

final class AgentUsageTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  func testRecognizesOnlyDirectAgentCommandsAndKnownTitles() {
    XCTAssertEqual(AgentTitleRecognition.backend(for: "claude"), .claude)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "claude --resume abc"), .claude)
    XCTAssertEqual(
      AgentTitleRecognition.backend(for: "/opt/homebrew/bin/claude --model opus"), .claude)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "Claude Code"), .claude)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "codex --full-auto"), .codex)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "/usr/local/bin/codex"), .codex)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "Codex"), .codex)

    for title in ["echo claude", "myclaude", "codex-helper", "Claude Code setup", "", "pwd"] {
      XCTAssertNil(AgentTitleRecognition.backend(for: title), "false positive for \(title)")
    }
    XCTAssertNil(AgentTitleRecognition.backend(for: nil))
  }

  func testRecognizesOnlyDirectAgentProcessNames() {
    XCTAssertEqual(AgentProcessRecognition.backend(forProcessName: "claude"), .claude)
    XCTAssertEqual(
      AgentProcessRecognition.backend(forProcessName: "/opt/homebrew/bin/codex"), .codex)
    for name in ["node", "claude-helper", "codex-agent", "Claude Code", ""] {
      XCTAssertNil(AgentProcessRecognition.backend(forProcessName: name))
    }
    XCTAssertNil(AgentProcessRecognition.backend(forProcessName: nil))
  }

  func testPaceAtStartMidpointAndEnd() {
    let duration: TimeInterval = 300
    let reset = now.addingTimeInterval(duration)
    let window = AgentQuotaWindow(
      kind: .fiveHour, usedPercentage: 40, duration: duration, resetsAt: reset)
    XCTAssertEqual(window.pace(at: now).percentagePoints, 40, accuracy: 0.001)
    XCTAssertEqual(
      window.pace(at: now.addingTimeInterval(150)).percentagePoints, -10, accuracy: 0.001)
    XCTAssertEqual(window.pace(at: reset).percentagePoints, -60, accuracy: 0.001)
    XCTAssertEqual(
      window.pace(at: now.addingTimeInterval(-100)).percentagePoints, 40, accuracy: 0.001)
  }

  func testPaceDescriptionsAndPercentageClamping() {
    XCTAssertEqual(AgentPace(percentagePoints: 6.4).compactDescription, "+6%")
    XCTAssertEqual(AgentPace(percentagePoints: -3.2).compactDescription, "−3%")
    XCTAssertEqual(AgentPace(percentagePoints: 0.2).compactDescription, "0%")
    XCTAssertEqual(
      AgentPace(percentagePoints: 6.4).accessibilityDescription, "6% in deficit")
    XCTAssertEqual(AgentPace(percentagePoints: -3.2).accessibilityDescription, "3% in reserve")
    XCTAssertEqual(
      AgentQuotaWindow(kind: .weekly, usedPercentage: 130, duration: 10, resetsAt: now)
        .usedPercentage, 100)
    XCTAssertEqual(
      AgentQuotaWindow(kind: .weekly, usedPercentage: -4, duration: 10, resetsAt: now)
        .usedPercentage, 0)
  }

  func testRelativeResetDescriptionCapsAtTwoUnits() {
    let window = AgentQuotaWindow(
      kind: .weekly, usedPercentage: 10, duration: 10, resetsAt: now.addingTimeInterval(93_000))
    XCTAssertEqual(window.resetDescription(at: now), "resets in 1d 1h")
    XCTAssertEqual(window.resetDescription(at: now.addingTimeInterval(92_999)), "resets in 1m")
    XCTAssertEqual(window.resetDescription(at: window.resetsAt), "resets now")
  }

  func testClaudeDecodesBothWindowsUnknownFieldsAndMissingWindow() throws {
    let both = Data(
      """
      {"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":2000003600,"future":1},"seven_day":{"used_percentage":41.2,"resets_at":2000604800}},"ignored":true}
      """.utf8)
    let snapshot = try XCTUnwrap(AgentUsageDecoding.claude(data: both, capturedAt: now, now: now))
    XCTAssertEqual(snapshot.backend, .claude)
    XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
    XCTAssertEqual(snapshot.windows.map(\.usedPercentage), [23.5, 41.2])

    let one = Data(#"{"five_hour":{"used_percentage":17,"resets_at":2000003600}}"#.utf8)
    XCTAssertEqual(
      AgentUsageDecoding.claude(data: one, capturedAt: now, now: now)?.windows.count, 1)
  }

  func testClaudeRejectsMalformedPartialAndExpiredData() {
    XCTAssertNil(AgentUsageDecoding.claude(data: Data("{".utf8), capturedAt: now, now: now))
    let expired = Data(#"{"five_hour":{"used_percentage":10,"resets_at":1999999999}}"#.utf8)
    XCTAssertNil(AgentUsageDecoding.claude(data: expired, capturedAt: now, now: now))
    let partial = Data(#"{"five_hour":{"used_percentage":10}}"#.utf8)
    XCTAssertNil(AgentUsageDecoding.claude(data: partial, capturedAt: now, now: now))
  }

  /// Every empty-quota footer has to be able to say WHY, so each way the Claude cache comes up empty
  /// gets its own sentence.
  func testClaudeReadDistinguishesMissingUnreadableAndResetCaches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cacheURL = root.appendingPathComponent("claude-rate-limits.json")

    func reason() -> String {
      guard
        case .failure(let value) = AgentUsageDecoding.readClaudeSnapshot(
          cacheURL: cacheURL, now: now)
      else { return "" }
      return value
    }

    XCTAssertTrue(reason().contains("hasn't received"), reason())
    try Data("{".utf8).write(to: cacheURL)
    XCTAssertTrue(reason().contains("couldn't be read"), reason())
    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":1999999999}}"#.utf8).write(
      to: cacheURL)
    XCTAssertTrue(reason().contains("since reset"), reason())

    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":2000003600}}"#.utf8).write(
      to: cacheURL)
    let read = AgentUsageDecoding.readClaudeSnapshot(cacheURL: cacheURL, now: now)
    XCTAssertEqual(read.snapshot?.windows.first?.usedPercentage, 10)
  }

  /// A stored snapshot expires where it sits, with no refresh running to record why — so the reason
  /// has to be derived when the footer reads it, not when the file was read.
  @MainActor func testStoredSnapshotThatExpiresExplainsItselfWithoutARefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cacheURL = root.appendingPathComponent("claude-rate-limits.json")
    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":2000003600}}"#.utf8).write(
      to: cacheURL)

    let clock = Clock(value: now)
    let monitor = AgentUsageMonitor(
      codexSessionsURL: root.appendingPathComponent("sessions"), claudeCacheURL: cacheURL,
      now: { clock.value }, startAutomatically: false)
    XCTAssertTrue(monitor.unavailableReason(for: .claude).contains("has been read yet"))

    monitor.refresh()
    for _ in 0..<200 where monitor.loading.contains(.claude) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNotNil(monitor.snapshot(for: .claude))

    clock.value = now.addingTimeInterval(4_000)
    XCTAssertNil(monitor.snapshot(for: .claude))
    XCTAssertTrue(
      monitor.unavailableReason(for: .claude).contains("since reset"),
      monitor.unavailableReason(for: .claude))
  }

  private final class Clock: @unchecked Sendable {
    var value: Date
    init(value: Date) { self.value = value }
  }

  func testCodexDecodesAdvertisedWindowsAndNewestCumulativeSnapshot() throws {
    let older = rollout(
      timestamp: "2033-05-18T03:33:20.000Z", primary: (5, 300, 2_000_003_600), secondary: nil)
    let newer = rollout(
      timestamp: "2033-05-18T03:34:20.000Z", primary: (42, 300, 2_000_003_600),
      secondary: (61, 10080, 2_000_604_800))
    let data = Data((older + "\n" + newer + "\n").utf8)
    let snapshot = try XCTUnwrap(
      AgentUsageDecoding.codexRollout(
        data: data, fileSize: UInt64(data.count), modifiedAt: now, now: now))
    XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
    XCTAssertEqual(snapshot.windows.map(\.usedPercentage), [42, 61])
  }

  func testCodexSupportsOneOrNonstandardAdvertisedWindowAndSkipsMalformedTail() throws {
    let valid = rollout(
      timestamp: "2033-05-18T03:33:20Z", primary: (12, 60, 2_000_003_600), secondary: nil)
    let data = Data((valid + "\n{partial").utf8)
    let snapshot = try XCTUnwrap(
      AgentUsageDecoding.codexRollout(
        data: data, fileSize: UInt64(data.count), modifiedAt: now, now: now))
    XCTAssertEqual(snapshot.windows.count, 1)
    XCTAssertEqual(snapshot.windows[0].kind, .duration(minutes: 60))
  }

  func testCodexReadUsesBoundedTailAndFallsBackFromMalformedNewestFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let validURL = root.appendingPathComponent("valid.jsonl")
    let valid =
      String(repeating: "x", count: 8_000) + "\n"
      + rollout(
        timestamp: "2033-05-18T03:33:20Z", primary: (33, 300, 2_000_003_600), secondary: nil)
      + "\n"
    try Data(valid.utf8).write(to: validURL)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: validURL.path)
    let malformedURL = root.appendingPathComponent("newest.jsonl")
    try Data("{partial".utf8).write(to: malformedURL)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: malformedURL.path)

    let snapshot = try XCTUnwrap(
      AgentUsageDecoding.readCodexSnapshot(
        sessionsRoot: root, now: now, maximumTailBytes: 1024))
    XCTAssertEqual(snapshot.windows[0].usedPercentage, 33)
  }

  private func rollout(
    timestamp: String, primary: (Double, Int, Int)?, secondary: (Double, Int, Int)?
  ) -> String {
    func window(_ value: (Double, Int, Int)?) -> String {
      guard let value else { return "null" }
      return
        "{\"used_percent\":\(value.0),\"window_minutes\":\(value.1),\"resets_at\":\(value.2),\"future\":true}"
    }
    return
      "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{"
      + "\"type\":\"token_count\",\"info\":{},\"rate_limits\":{"
      + "\"primary\":\(window(primary)),\"secondary\":\(window(secondary)),\"future\":1}}}"
  }
}
