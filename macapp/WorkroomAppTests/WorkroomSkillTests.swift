import Defaults
import HostDrivers
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Workroom skill for Claude Code and Codex (#697): Settings ▸ AI Agents' toggle installs it
/// and removes it again through the bundled CLI, in a throwaway home only, and each host's connect
/// is told what to do with it.
@MainActor
final class WorkroomSkillTests: XCTestCase {
  /// Calls the runner was given, in order.
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(install: Bool, home: String, variables: [String: String])] = []
    func record(_ install: Bool, _ home: String, _ variables: [String: String]) {
      lock.withLock { calls.append((install, home, variables)) }
    }
    var installs: [Bool] { lock.withLock { calls.map(\.install) } }
    var homes: [String] { lock.withLock { calls.map(\.home) } }
    var variables: [[String: String]] { lock.withLock { calls.map(\.variables) } }
  }

  private func throwawayHome(agents: [String] = [".claude", ".codex"]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "skill-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    for agent in agents {
      try FileManager.default.createDirectory(
        at: home.appendingPathComponent(agent), withIntermediateDirectories: true)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    return home
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  nonisolated private static func resetSettings() {
    Defaults.reset(
      .installWorkroomSkill, .workroomSkillHosts, .workroomSkillPendingRemoval,
      .workroomSkillMacRemovalPending)
  }

  override func setUp() {
    super.setUp()
    Self.resetSettings()
  }

  override func tearDown() {
    Self.resetSettings()
    super.tearDown()
  }

  /// A host's install that finishes after the setting was turned off, before the host was
  /// counted, makes that host due its removal, not one Workroom leaves for good.
  func testAnInstallThatFinishesAfterTheSettingIsOffIsDueItsRemoval() {
    let late = HostID.remote(UUID())
    let skill = WorkroomSkill(home: nil) { _, _, _ in WorkroomSkillReport(skills: []) }
    Defaults[.installWorkroomSkill] = true
    skill.settingChanged(to: true)
    Defaults[.installWorkroomSkill] = false
    skill.settingChanged(to: false)
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: late), .leave, "not heard from yet")
    skill.recordHost(
      late, policy: .install,
      result: .done([.init(agent: "claude", path: "/h/.claude/skills/workroom", state: "installed")]
      ))
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: late), .remove)
    XCTAssertEqual(Defaults[.workroomSkillHosts], [])
  }

  /// A removal whose envelope went through but one of whose folders failed (a read-only disk)
  /// leaves the host due, so the next connect retries; only every folder removed or absent ends it.
  func testAHostRemovalWithAFailedFolderStaysDue() {
    let host = HostID.remote(UUID())
    let skill = WorkroomSkill(home: nil) { _, _, _ in WorkroomSkillReport(skills: []) }
    Defaults[.workroomSkillPendingRemoval] = [WorkroomSkill.key(host)]
    skill.recordHost(
      host, policy: .remove,
      result: .done([
        .init(agent: "claude", path: "/h/.claude/skills/workroom", state: "removed"),
        .init(
          agent: "codex", path: "/h/.agents/skills/workroom", state: "failed",
          message: "Read-only file system"),
      ]))
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: host), .remove, "kept for the next connect")
    XCTAssertEqual(
      skill.notice,
      "On a remote host: Codex's skill at /h/.agents/skills/workroom failed: Read-only file system")
    skill.recordHost(
      host, policy: .remove,
      result: .done([
        .init(agent: "claude", path: "/h/.claude/skills/workroom", state: "absent"),
        .init(agent: "codex", path: "/h/.agents/skills/workroom", state: "removed"),
      ]))
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: host), .leave)
  }

  /// The Mac's own removal that failed for a folder is tried again at the next launch with the
  /// setting off, until it goes through.
  func testTheMacsFailedRemovalIsRetriedAtLaunch() async {
    let calls = Calls()
    let failing = WorkroomSkillReport(skills: [
      .init(agent: "claude", path: "/h/.claude/skills/workroom", state: "failed", message: "EROFS")
    ])
    let skill = WorkroomSkill(home: "/tmp/skill-home") { install, home, variables in
      calls.record(install, home, variables)
      return calls.installs.count == 1 ? failing : WorkroomSkillReport(skills: [])
    }
    await skill.apply(install: false).value
    XCTAssertTrue(Defaults[.workroomSkillMacRemovalPending])
    skill.launched()
    await skill.apply(install: false).value
    XCTAssertEqual(calls.installs, [false, false, false], "launch tried the removal again")
    XCTAssertFalse(Defaults[.workroomSkillMacRemovalPending])
    skill.launched()
    await skill.apply(install: true).value
    XCTAssertEqual(calls.installs.count, 4, "nothing more to retry at launch")
  }

  /// The real bundled CLI, in a throwaway home: on writes Claude Code's skill in `~/.claude` and
  /// Codex's in `~/.agents`, each with Workroom's marker; off takes away exactly that, leaving
  /// the agents' folders and a skill of the user's. Whatever `CLAUDE_CONFIG_DIR` or `CODEX_HOME`
  /// this process has (a developer's may name their real config) never reaches the CLI.
  func testTheBundledCLIInstallsAndRemovesTheSkillInTheHomeItIsGiven() async throws {
    let home = try throwawayHome()
    let theirs = home.appendingPathComponent(".agents/skills/mine/SKILL.md")
    try FileManager.default.createDirectory(
      at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("the user's own".utf8).write(to: theirs)
    let skill = WorkroomSkill(home: home.path)

    await skill.apply(install: true).value
    XCTAssertNil(skill.notice)
    for folder in [".claude/skills/workroom", ".agents/skills/workroom"].map({
      home.appendingPathComponent($0)
    }) {
      let text = try String(
        contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
      XCTAssertTrue(text.hasPrefix("---\nname: workroom\ndescription: "), text)
      XCTAssertTrue(text.contains("workroom wait"), text)
      XCTAssertTrue(exists(folder.appendingPathComponent(".workroom-skill")))
    }
    XCTAssertFalse(exists(home.appendingPathComponent(".codex/skills")))

    await skill.apply(install: false).value
    XCTAssertNil(skill.notice)
    XCTAssertFalse(exists(home.appendingPathComponent(".claude/skills")))
    XCTAssertFalse(exists(home.appendingPathComponent(".agents/skills/workroom")))
    XCTAssertTrue(exists(home.appendingPathComponent(".claude")))
    XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "the user's own")
  }

  /// The variables given are the ones the CLI uses: `CLAUDE_CONFIG_DIR` moves Claude Code's skill.
  func testTheBundledCLIUsesTheVariablesItIsGiven() async throws {
    let home = try throwawayHome(agents: [])
    let config = home.appendingPathComponent("claude-config")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let report = try await WorkroomCLI.shared.workroomSkill(
      install: true, home: home.path, variables: ["CLAUDE_CONFIG_DIR": config.path])
    XCTAssertEqual(report.skills.map(\.state), ["installed", "no-agent"])
    XCTAssertTrue(exists(config.appendingPathComponent("skills/workroom/SKILL.md")))
    XCTAssertFalse(exists(home.appendingPathComponent(".claude")))
    _ = try await WorkroomCLI.shared.workroomSkill(install: false, home: home.path, variables: [:])
    XCTAssertFalse(exists(config.appendingPathComponent("skills")), "found from the record")
  }

  /// A skill of that name the user made is left alone, and the section says so.
  func testASkillWorkroomDidNotMakeIsLeftAndSaidSo() async throws {
    let home = try throwawayHome(agents: [".claude"])
    let folder = home.appendingPathComponent(".claude/skills/workroom")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    let skill = WorkroomSkill(home: home.path)

    await skill.apply(install: true).value
    XCTAssertEqual(
      skill.notice,
      "\(folder.path) is a skill Workroom didn't install, so Claude Code's was left alone."
    )
    await skill.apply(install: false).value
    XCTAssertEqual(
      try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), "mine")
  }

  /// The toggle installs and removes, in the order asked; launch installs only while it is on; a
  /// home that isn't the user's is given no variables.
  func testTheSettingInstallsRemovesAndLaunchInstallsOnlyWhileOn() async {
    let calls = Calls()
    let skill = WorkroomSkill(home: "/tmp/skill-home") { install, home, variables in
      calls.record(install, home, variables)
      return WorkroomSkillReport(skills: [])
    }
    skill.launched()
    await skill.apply(install: true).value
    XCTAssertEqual(calls.installs, [true], "launch with the setting off installs nothing")

    Defaults[.installWorkroomSkill] = true
    skill.settingChanged(to: true)
    skill.settingChanged(to: false)
    // The last one asked wins, after the ones before it.
    await skill.apply(install: false).value
    XCTAssertEqual(calls.installs, [true, true, false, false])
    XCTAssertEqual(Set(calls.homes), ["/tmp/skill-home"])
    XCTAssertEqual(Set(calls.variables), [[:]])
    XCTAssertFalse(skill.isApplying)

    skill.launched()
    await skill.apply(install: true).value
    XCTAssertEqual(calls.installs.suffix(2), [true, true], "launch with it on installs")
  }

  /// A runner that fails says so, and a process with no home touches nothing.
  func testAFailureIsSaidAndNoHomeRunsNothing() async {
    struct Failed: LocalizedError { var errorDescription: String? { "no binary" } }
    let failing = WorkroomSkill(home: "/tmp/skill-home") { _, _, _ in throw Failed() }
    await failing.apply(install: true).value
    XCTAssertEqual(failing.notice, "The skill couldn't be installed: no binary")

    let calls = Calls()
    let homeless = WorkroomSkill(home: nil) { install, home, variables in
      calls.record(install, home, variables)
      return WorkroomSkillReport(skills: [])
    }
    await homeless.apply(install: true).value
    XCTAssertEqual(calls.installs, [])
    XCTAssertNil(homeless.notice)
  }

  /// A hosted unit run never reaches the developer's home.
  func testAHostedUnitRunHasNoHomeOfItsOwn() {
    XCTAssertNil(WorkroomSkill.defaultHome())
  }

  /// Only the coding agents' two variables, and only set ones, are taken from an environment.
  func testOnlyTheAgentsVariablesAreTaken() {
    XCTAssertEqual(
      WorkroomSkill.agentVariables(from: [
        "CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "", "HOME": "/h", "PATH": "/bin",
      ]), ["CLAUDE_CONFIG_DIR": "/c"])
  }

  /// What each host's connect is told: install while on; once turned off, remove on each host it
  /// went onto, once, until a removal there finished or found nothing, and kept while one fails
  /// (a host whose binary predates `workroom skill`); a host it never went onto is left alone.
  func testEachHostGetsItsRemovalOnceAfterTheSettingIsTurnedOff() {
    let a = HostID.remote(UUID())
    let b = HostID.remote(UUID())
    let never = HostID.remote(UUID())
    let skill = WorkroomSkill(home: nil) { _, _, _ in WorkroomSkillReport(skills: []) }
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: a), .leave, "off by default")

    Defaults[.installWorkroomSkill] = true
    skill.settingChanged(to: true)
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: a), .install)
    let installed = DaemonBootstrap.Outcome.WorkroomSkill.done([
      .init(agent: "claude", path: "/h/.claude/skills/workroom", state: "installed"),
      .init(agent: "codex", path: "/h/.agents/skills/workroom", state: "no-agent"),
    ])
    skill.recordHost(a, policy: .install, result: installed)
    skill.recordHost(b, policy: .install, result: installed)
    skill.recordHost(never, policy: .install, result: .failed("unknown command \"skill\""))
    XCTAssertEqual(
      Set(Defaults[.workroomSkillHosts]), [WorkroomSkill.key(a), WorkroomSkill.key(b)])
    XCTAssertEqual(
      skill.notice, "On a remote host, the skill couldn't be installed: unknown command \"skill\"")

    Defaults[.installWorkroomSkill] = false
    skill.settingChanged(to: false)
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: a), .remove)
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: b), .remove)
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: never), .leave)

    skill.recordHost(
      a, policy: .remove,
      result: .done([.init(agent: "claude", path: "/h/.claude/skills/workroom", state: "removed")]))
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: a), .leave, "removed once")
    skill.recordHost(b, policy: .remove, result: .failed("unknown command \"skill\""))
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: b), .remove, "kept until it goes through")
    XCTAssertEqual(
      skill.notice, "On a remote host, the skill couldn't be removed yet: unknown command \"skill\""
    )
    skill.recordHost(b, policy: .remove, result: nil)
    XCTAssertEqual(WorkroomSkill.hostPolicy(for: b), .leave, "the probe found nothing to remove")
    XCTAssertNil(skill.notice)
  }

  /// A host whose skill was left alone or edited says so in the setting.
  func testAHostsSkillLeftAloneIsSaid() {
    let skill = WorkroomSkill(home: nil) { _, _, _ in WorkroomSkillReport(skills: []) }
    skill.recordHost(
      .remote(UUID()), policy: .install,
      result: .done([
        .init(agent: "codex", path: "/home/u/.agents/skills/workroom", state: "not-ours")
      ]))
    XCTAssertEqual(
      skill.notice,
      "On a remote host: /home/u/.agents/skills/workroom is a skill Workroom didn't install, "
        + "so Codex's was left alone.")
  }

  func testTheNoticeNamesWhatWasLeftOrFailedAndNothingElse() {
    func report(_ states: [(String, String)]) -> WorkroomSkillReport {
      WorkroomSkillReport(
        skills: states.map {
          .init(agent: $0.0, path: "/h/.\($0.0)/skills/workroom", state: $0.1, message: "denied")
        })
    }
    XCTAssertNil(
      WorkroomSkill.notice(
        for: report([("claude", "installed"), ("codex", "no-agent")]), install: true))
    XCTAssertNil(
      WorkroomSkill.notice(
        for: report([("claude", "removed"), ("codex", "absent")]), install: false))
    XCTAssertEqual(
      WorkroomSkill.notice(
        for: report([("claude", "edited"), ("codex", "failed")]), install: false),
      "You edited /h/.claude/skills/workroom/SKILL.md, so Workroom kept it.\n"
        + "Codex's skill at /h/.codex/skills/workroom failed: denied")
  }
}
