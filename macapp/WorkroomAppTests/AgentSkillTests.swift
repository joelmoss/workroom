import Defaults
import HostDrivers
import XCTest

@testable import Workroom

/// The Workroom skill for Claude Code and Codex on this Mac (#697): Settings ▸ AI Agents' toggle
/// installs it and removes it again through the bundled CLI, in a throwaway home only.
@MainActor
final class AgentSkillTests: XCTestCase {
  /// Calls the runner was given, in order.
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(install: Bool, home: String)] = []
    func record(_ install: Bool, _ home: String) { lock.withLock { calls.append((install, home)) } }
    var installs: [Bool] { lock.withLock { calls.map(\.install) } }
    var homes: [String] { lock.withLock { calls.map(\.home) } }
  }

  private func throwawayHome(agents: [String] = [".claude", ".codex"]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agent-skill-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    for agent in agents {
      try FileManager.default.createDirectory(
        at: home.appendingPathComponent(agent), withIntermediateDirectories: true)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    return home
  }

  override func setUp() {
    super.setUp()
    Defaults.reset(.installAgentSkill, .agentSkillTurnedOff)
  }

  override func tearDown() {
    Defaults.reset(.installAgentSkill, .agentSkillTurnedOff)
    super.tearDown()
  }

  /// The real bundled CLI, in a throwaway home: on writes each agent's skill, with Workroom's
  /// marker; off takes away exactly that, leaving the agents' folders and a skill of the user's.
  func testTheBundledCLIInstallsAndRemovesTheSkillInTheHomeItIsGiven() async throws {
    let home = try throwawayHome()
    let theirs = home.appendingPathComponent(".codex/skills/mine/SKILL.md")
    try FileManager.default.createDirectory(
      at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("the user's own".utf8).write(to: theirs)
    let skill = AgentSkill(home: home.path)

    await skill.apply(install: true).value
    XCTAssertNil(skill.notice)
    for agent in [".claude", ".codex"] {
      let folder = home.appendingPathComponent("\(agent)/skills/workroom")
      let text = try String(
        contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
      XCTAssertTrue(text.hasPrefix("---\nname: workroom\ndescription: "), text)
      XCTAssertTrue(text.contains("workroom wait"), text)
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: folder.appendingPathComponent(".workroom-skill").path)
      )
    }

    await skill.apply(install: false).value
    XCTAssertNil(skill.notice)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: home.appendingPathComponent(".claude/skills/workroom").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: home.appendingPathComponent(".codex/skills/workroom").path))
    // Claude's skills folder was Workroom's to make, Codex's wasn't.
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "the user's own")
  }

  /// A skill of that name the user made is left alone, and the section says so.
  func testASkillWorkroomDidNotMakeIsLeftAndSaidSo() async throws {
    let home = try throwawayHome(agents: [".claude"])
    let folder = home.appendingPathComponent(".claude/skills/workroom")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    let skill = AgentSkill(home: home.path)

    await skill.apply(install: true).value
    XCTAssertEqual(
      skill.notice,
      "\(folder.path) is a skill Workroom didn't install, so Claude Code's was left alone."
    )
    await skill.apply(install: false).value
    XCTAssertEqual(
      try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), "mine")
  }

  /// The toggle installs, then removes and remembers the turn-off for the hosts; launch installs
  /// only while it is on.
  func testTheSettingInstallsRemovesAndLaunchInstallsOnlyWhileOn() async {
    let calls = Calls()
    let skill = AgentSkill(home: "/tmp/skill-home") { install, home in
      calls.record(install, home)
      return AgentSkillReport(skills: [])
    }
    skill.launched()
    await skill.apply(install: true).value
    XCTAssertEqual(calls.installs, [true], "launch with the setting off installs nothing")

    Defaults[.installAgentSkill] = true
    skill.settingChanged(to: true)
    XCTAssertFalse(Defaults[.agentSkillTurnedOff])
    skill.settingChanged(to: false)
    XCTAssertTrue(Defaults[.agentSkillTurnedOff])
    // The last one asked wins, after the ones before it.
    await skill.apply(install: false).value
    XCTAssertEqual(calls.installs, [true, true, false, false])
    XCTAssertEqual(Set(calls.homes), ["/tmp/skill-home"])
    XCTAssertFalse(skill.isApplying)

    skill.launched()
    await skill.apply(install: true).value
    XCTAssertEqual(calls.installs.suffix(2), [true, true], "launch with it on installs")
  }

  /// A runner that fails says so, and a process with no home touches nothing.
  func testAFailureIsSaidAndNoHomeRunsNothing() async {
    struct Failed: LocalizedError { var errorDescription: String? { "no binary" } }
    let failing = AgentSkill(home: "/tmp/skill-home") { _, _ in throw Failed() }
    await failing.apply(install: true).value
    XCTAssertEqual(failing.notice, "The skill couldn't be installed: no binary")

    let calls = Calls()
    let homeless = AgentSkill(home: nil) { install, home in
      calls.record(install, home)
      return AgentSkillReport(skills: [])
    }
    await homeless.apply(install: true).value
    XCTAssertEqual(calls.installs, [])
    XCTAssertNil(homeless.notice)
  }

  /// A hosted unit run never reaches the developer's home.
  func testAHostedUnitRunHasNoHomeOfItsOwn() {
    XCTAssertNil(AgentSkill.defaultHome())
  }

  /// What each host's bootstrap is told: install while on, remove once turned off, else nothing.
  func testTheHostPolicyFollowsTheSetting() {
    XCTAssertEqual(AgentSkill.hostPolicy(on: true, turnedOff: false), .install)
    XCTAssertEqual(AgentSkill.hostPolicy(on: true, turnedOff: true), .install)
    XCTAssertEqual(AgentSkill.hostPolicy(on: false, turnedOff: true), .remove)
    XCTAssertEqual(AgentSkill.hostPolicy(on: false, turnedOff: false), .leave)
    XCTAssertEqual(AgentSkill.hostPolicy(), .leave, "off by default")
  }

  func testTheNoticeNamesWhatWasLeftOrFailedAndNothingElse() {
    func report(_ states: [(String, String)]) -> AgentSkillReport {
      AgentSkillReport(
        skills: states.map {
          .init(agent: $0.0, path: "/h/.\($0.0)/skills/workroom", state: $0.1, message: "denied")
        })
    }
    XCTAssertNil(
      AgentSkill.notice(
        for: report([("claude", "installed"), ("codex", "no-agent")]), install: true))
    XCTAssertNil(
      AgentSkill.notice(for: report([("claude", "removed"), ("codex", "absent")]), install: false))
    XCTAssertEqual(
      AgentSkill.notice(for: report([("claude", "edited"), ("codex", "failed")]), install: false),
      "You edited /h/.claude/skills/workroom/SKILL.md, so Workroom kept it.\n"
        + "Codex's skill at /h/.codex/skills/workroom failed: denied")
  }
}
