import Foundation
import XCTest

@testable import Workroom

@MainActor
final class ClaudeUsageBridgeTests: XCTestCase {
  private var root: URL!
  private var settings: URL!
  private var support: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    settings = root.appendingPathComponent(".claude/settings.json")
    support = root.appendingPathComponent("Application Support/Workroom/Agent Usage")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testEnableWithNoPriorStatusLineAndDisableRestoresAbsence() throws {
    try writeSettings(["theme": "dark"])
    let bridge = makeBridge()
    try bridge.enable()
    XCTAssertEqual(bridge.state, .enabled)
    XCTAssertEqual(try statusLine()["type"] as? String, "command")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bridge.wrapperURL.path))
    XCTAssertEqual(permissions(bridge.wrapperURL), 0o700)
    XCTAssertEqual(permissions(bridge.metadataURL), 0o600)

    try bridge.disable()
    XCTAssertEqual(bridge.state, .disabled)
    XCTAssertNil(try readSettings()["statusLine"])
  }

  func testArbitraryPriorObjectIsRestoredExactlyAndRepeatedEnableDoesNotReplaceIt() throws {
    let prior: [String: Any] = [
      "type": "command", "command": "printf 'hello'", "padding": 7, "future": ["x": true],
    ]
    try writeSettings(["statusLine": prior, "other": 3])
    let bridge = makeBridge()
    try bridge.enable()
    try bridge.enable()
    try bridge.disable()
    XCTAssertEqual(try canonical(readSettings()["statusLine"]!), try canonical(prior))
    XCTAssertEqual(try readSettings()["other"] as? Int, 3)
  }

  func testWrapperCachesOnlyRateLimitsAndForwardsOriginalJSONToPriorCommand() throws {
    try writeSettings(["statusLine": ["type": "command", "command": "/bin/cat"]])
    let bridge = makeBridge()
    try bridge.enable()
    let input =
      #"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":2000003600}},"secret":"not cached"}"#
    let result = try run(bridge.wrapperURL, stdin: input)
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.stdout, input)
    let cache = try String(contentsOf: bridge.cacheURL, encoding: .utf8)
    XCTAssertTrue(cache.contains("five_hour"))
    XCTAssertFalse(cache.contains("model"))
    XCTAssertFalse(cache.contains("secret"))
    XCTAssertEqual(permissions(bridge.cacheURL), 0o600)
  }

  func testUserEditedSettingsAreNeverOverwrittenAndWrapperStaysInPlace() throws {
    try writeSettings(["statusLine": ["type": "command", "command": "echo prior"]])
    let bridge = makeBridge()
    try bridge.enable()
    let edited: [String: Any] = ["type": "command", "command": "echo mine"]
    var object = try readSettings()
    object["statusLine"] = edited
    try writeSettings(object)

    XCTAssertThrowsError(try bridge.disable()) { error in
      XCTAssertEqual(error as? ClaudeUsageBridge.BridgeError, .settingChanged)
    }
    XCTAssertEqual(try canonical(readSettings()["statusLine"]!), try canonical(edited))
    XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.wrapperURL.path))
  }

  func testMissingWrapperReportsRepairAndRepairRecreatesIt() throws {
    try writeSettings([:])
    let bridge = makeBridge()
    try bridge.enable()
    try FileManager.default.removeItem(at: bridge.wrapperURL)
    bridge.refreshState()
    XCTAssertEqual(bridge.state, .needsRepair)
    try bridge.repair()
    XCTAssertEqual(bridge.state, .enabled)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bridge.wrapperURL.path))
  }

  func testRestorationFailureKeepsWrapperAndMetadata() throws {
    try writeSettings(["statusLine": ["type": "command", "command": "echo prior"]])
    var failSettingsWrite = false
    let bridge = ClaudeUsageBridge(
      settingsURL: settings, directoryURL: support,
      writer: { [settings] data, url, permissions in
        if failSettingsWrite, url == settings { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: permissions], ofItemAtPath: url.path)
      })
    try bridge.enable()
    failSettingsWrite = true
    XCTAssertThrowsError(try bridge.disable())
    XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.wrapperURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.metadataURL.path))
  }

  private func makeBridge() -> ClaudeUsageBridge {
    ClaudeUsageBridge(settingsURL: settings, directoryURL: support)
  }

  private func writeSettings(_ object: [String: Any]) throws {
    try FileManager.default.createDirectory(
      at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: settings, options: .atomic)
  }

  private func readSettings() throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
  }

  private func statusLine() throws -> [String: Any] {
    try XCTUnwrap(readSettings()["statusLine"] as? [String: Any])
  }

  private func canonical(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private func permissions(_ url: URL) -> Int {
    let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    return (value as? NSNumber)?.intValue ?? -1
  }

  private func run(_ executable: URL, stdin: String) throws -> (stdout: String, code: Int32) {
    let process = Process()
    process.executableURL = executable
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
  }
}
