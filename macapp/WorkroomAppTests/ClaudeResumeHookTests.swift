import Defaults
import HostDrivers
import WorkroomDomain
import XCTest

@testable import Workroom

/// Claude Code's resume hook (#828): while "Resume programs after a restart" is on, the bundled
/// CLI puts it in each Claude profile's `settings.json`, in a throwaway home only, and takes it
/// out again once it's off; each host's connect is told what to do with it.
@MainActor
final class ClaudeResumeHookTests: XCTestCase {
  /// Calls the runner was given, in order.
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(install: Bool, variables: [String: String])] = []
    func record(_ install: Bool, _ variables: [String: String]) {
      lock.withLock { calls.append((install, variables)) }
    }
    var installs: [Bool] { lock.withLock { calls.map(\.install) } }
  }

  /// The setting as a test sets it, never the app's own key.
  private final class Setting {
    var on = true
  }

  private func throwawayHome(profile: Bool = true) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "resume-hook-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    if profile {
      try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    return home
  }

  private func settings(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
  }

  private func sessionStart(_ url: URL) throws -> [[String: Any]] {
    let hooks = try settings(url)["hooks"] as? [String: Any]
    return hooks?["SessionStart"] as? [[String: Any]] ?? []
  }

  nonisolated private static func resetSettings() {
    Defaults.reset(.claudeResumeHookHosts, .claudeResumeHookOnMac)
  }

  override func setUp() {
    super.setUp()
    Self.resetSettings()
  }

  override func tearDown() {
    Self.resetSettings()
    super.tearDown()
  }

  /// The real bundled CLI, in a throwaway home: on adds Workroom's `SessionStart` hook beside the
  /// user's own and keeps their other settings; off takes out exactly that. Whatever
  /// `CLAUDE_CONFIG_DIR` this process has (a developer's may name their real config) never
  /// reaches the CLI.
  func testTheBundledCLIAddsAndRemovesTheHookBesideTheUsersOwn() async throws {
    let home = try throwawayHome()
    let file = home.appendingPathComponent(".claude/settings.json")
    let theirs: [String: Any] = [
      "model": "opus",
      "hooks": [
        "SessionStart": [["hooks": [["type": "command", "command": "echo mine"]]]]
      ],
    ]
    try JSONSerialization.data(withJSONObject: theirs).write(to: file)
    let setting = Setting()
    let hook = ClaudeResumeHook(home: home.path, isOn: { setting.on })

    await hook.reconcile()?.value
    XCTAssertNil(hook.notice)
    XCTAssertTrue(Defaults[.claudeResumeHookOnMac])
    let start = try sessionStart(file)
    XCTAssertEqual(start.count, 2, "\(start)")
    let handlers = start.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    XCTAssertEqual(handlers.first?["command"] as? String, "echo mine")
    let ours = try XCTUnwrap(handlers.last?["command"] as? String)
    XCTAssertTrue(ours.hasSuffix("# workroom-resume-hook"), ours)
    XCTAssertTrue(ours.contains("resume-hook report"), ours)
    XCTAssertEqual(try settings(file)["model"] as? String, "opus")

    setting.on = false
    await hook.reconcile()?.value
    XCTAssertNil(hook.notice)
    XCTAssertFalse(Defaults[.claudeResumeHookOnMac], "the removal went through")
    let left = try sessionStart(file)
    XCTAssertEqual(left.count, 1)
    XCTAssertEqual(
      (left.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String, "echo mine")
    XCTAssertNil(hook.reconcile(), "off and nothing of Workroom's left: nothing to do")
  }

  /// The variable given is the one the CLI uses: `CLAUDE_CONFIG_DIR` names another profile, and
  /// a removal once it no longer does still finds it.
  func testTheBundledCLIUsesTheProfileItIsGiven() async throws {
    let home = try throwawayHome(profile: false)
    let config = home.appendingPathComponent("claude-config")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let report = try await WorkroomCLI.shared.claudeResumeHook(
      install: true, home: home.path, variables: ["CLAUDE_CONFIG_DIR": config.path])
    XCTAssertEqual(report.profiles.map(\.state), ["installed", "no-agent"])
    XCTAssertEqual(try sessionStart(config.appendingPathComponent("settings.json")).count, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    let removed = try await WorkroomCLI.shared.claudeResumeHook(
      install: false, home: home.path, variables: [:])
    XCTAssertTrue(removed.profiles.contains { $0.state == "removed" }, "\(removed)")
    XCTAssertEqual(try settings(config.appendingPathComponent("settings.json")).count, 0)
  }

  /// A `settings.json` that doesn't parse is never overwritten, and Settings says so.
  func testASettingsFileThatDoesntParseIsLeftAndSaidSo() async throws {
    let home = try throwawayHome()
    let file = home.appendingPathComponent(".claude/settings.json")
    try Data("{\"model\": \"opus\",}".utf8).write(to: file)
    let hook = ClaudeResumeHook(home: home.path, isOn: { true })
    await hook.reconcile()?.value
    let notice = try XCTUnwrap(hook.notice)
    XCTAssertTrue(notice.contains("isn't valid JSON"), notice)
    XCTAssertTrue(notice.contains("left it as it is"), notice)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"model\": \"opus\",}")
  }

  /// This Mac's removal that failed for a profile keeps it marked, so the next reconcile tries
  /// again until it goes through; never on, nothing runs.
  func testAFailedRemovalStaysDueAndNeverOnRunsNothing() async {
    let calls = Calls()
    let failing = ClaudeResumeHookReport(profiles: [
      .init(agent: "claude", path: "/h/.claude/settings.json", state: "failed", message: "EROFS")
    ])
    let setting = Setting()
    setting.on = false
    let hook = ClaudeResumeHook(home: "/tmp/resume-hook-home", isOn: { setting.on }) {
      install, _, variables in
      calls.record(install, variables)
      return calls.installs.count == 2 ? failing : ClaudeResumeHookReport(profiles: [])
    }
    XCTAssertNil(hook.reconcile(), "never on: nothing of Workroom's to remove")
    setting.on = true
    await hook.reconcile()?.value
    setting.on = false
    await hook.reconcile()?.value
    XCTAssertTrue(Defaults[.claudeResumeHookOnMac], "the failed profile keeps this Mac marked")
    XCTAssertNotNil(hook.notice)
    await hook.reconcile()?.value
    XCTAssertEqual(calls.installs, [true, false, false])
    XCTAssertFalse(Defaults[.claudeResumeHookOnMac])
    XCTAssertNil(hook.notice)
  }

  /// A host is due its install while the setting is on, and its removal after it's off only once
  /// an install was started there; a removal that went through for every profile unmarks it.
  func testEachHostIsReconciledByTheSameRule() {
    let host = HostID.remote(UUID())
    let key = WorkroomSkill.key(host)
    XCTAssertEqual(ClaudeResumeHook.hostPolicy(for: host, on: true, marked: []), .install)
    XCTAssertEqual(ClaudeResumeHook.hostPolicy(for: host, on: false, marked: []), .leave)
    XCTAssertEqual(ClaudeResumeHook.hostPolicy(for: host, on: false, marked: [key]), .remove)

    let setting = Setting()
    setting.on = false
    let hook = ClaudeResumeHook(home: nil, isOn: { setting.on }) { _, _, _ in
      ClaudeResumeHookReport(profiles: [])
    }
    Defaults[.claudeResumeHookHosts] = [key]
    hook.recordHost(
      host, policy: .remove,
      result: .done([.init(agent: "claude", path: "/h", state: "failed", message: "EROFS")]))
    XCTAssertEqual(Defaults[.claudeResumeHookHosts], [key], "a failed profile stays due")
    XCTAssertTrue(hook.notice?.hasPrefix("On a remote host: ") == true, hook.notice ?? "")
    hook.recordHost(host, policy: .remove, result: .failed("unknown command"))
    XCTAssertEqual(Defaults[.claudeResumeHookHosts], [key], "an old daemon stays due")
    hook.recordHost(
      host, policy: .remove, result: .done([.init(agent: "claude", path: "/h", state: "removed")]))
    XCTAssertEqual(Defaults[.claudeResumeHookHosts], [], "removed everywhere")
    XCTAssertNil(hook.notice)
  }

  /// A test process leaves every host alone, since the setting is on by default and a live host
  /// test's host is a real one.
  func testATestProcessLeavesEveryHostAlone() {
    XCTAssertEqual(ClaudeResumeHook.beginHostSync(for: .remote(UUID())), .leave)
    XCTAssertEqual(Defaults[.claudeResumeHookHosts], [])
  }

  func testTheNoticeNamesOnlyAProfileThatFailed() {
    XCTAssertNil(
      ClaudeResumeHook.notice(for: [
        .init(agent: "claude", path: "/h/.claude/settings.json", state: "installed"),
        .init(agent: "claude", path: "/h/c/settings.json", state: "no-agent"),
      ]))
    XCTAssertEqual(
      ClaudeResumeHook.notice(for: [
        .init(agent: "claude", path: "/x/settings.json", state: "failed", message: "why")
      ]),
      "Claude Code's resume hook isn't in /x/settings.json: why")
  }
}
