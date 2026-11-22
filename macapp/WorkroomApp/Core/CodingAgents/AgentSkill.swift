import Defaults
import Foundation
import HostDrivers
import os

/// What `workroom agent-skill install|remove` said of each coding agent's Workroom skill.
struct AgentSkillReport: Decodable, Equatable, Sendable {
  struct Skill: Decodable, Equatable, Sendable {
    /// `claude` or `codex`.
    let agent: String
    /// The skill's folder.
    let path: String
    /// `installed`, `updated`, `current`, `removed`, `absent`, `no-agent`, `not-ours`, `edited`
    /// or `failed`.
    let state: String
    /// Why, for `failed`.
    let message: String?
  }
  let skills: [Skill]
}

/// The Workroom skill for Claude Code and Codex (#697), on this Mac: Settings ▸ AI Agents' toggle
/// (`installAgentSkill`) installs it into `~/.claude` and `~/.codex` and removes it again, through
/// the bundled CLI's `agent-skill`, which alone decides what is Workroom's to write or delete. Each
/// host's bootstrap does the same on that host (`hostPolicy`).
///
/// It is installed again at every launch while the setting is on, so an app update brings the
/// skill's text up to date, and an agent installed since gets it too.
@MainActor
final class AgentSkill: ObservableObject {
  static let shared = AgentSkill()

  /// Installs (`true`) or removes the skill in a home folder, saying what became of each agent's.
  typealias Runner = @Sendable (_ install: Bool, _ home: String) async throws -> AgentSkillReport

  /// What a person needs to know about the last install or removal: a skill left alone, or one
  /// that failed. Nil when it went as asked.
  @Published private(set) var notice: String?
  /// Whether an install or removal is under way.
  @Published private(set) var isApplying = false

  /// The home folder whose agents' folders get the skill, or nil for a process that must not
  /// touch one (a hosted unit test, unless it passes its own).
  let home: String?
  private let runner: Runner
  /// The install or removal under way; the next waits for it, so the last one asked wins.
  private var last: Task<Void, Never>?
  private var applied = 0

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "AgentSkill")

  init(
    home: String? = AgentSkill.defaultHome(),
    runner: @escaping Runner = { install, home in
      try await WorkroomCLI.shared.agentSkill(install: install, home: home)
    }
  ) {
    self.home = home
    self.runner = runner
  }

  /// The user's home, or in a test process never it: a fixture launch's throwaway home, and none
  /// in a hosted unit run or a UI launch with live services.
  nonisolated static func defaultHome() -> String? {
    #if DEBUG
      let environment = AppEnvironment.current
      if environment.isFixture { return UITestFixture.agentSkillHome.path }
      if environment.isTestProcess { return nil }
    #endif
    return NSHomeDirectory()
  }

  /// What each host's bootstrap does with the skill: install it while the setting is on, remove
  /// it once the user turned it off, and otherwise leave whatever is there alone.
  nonisolated static func hostPolicy(
    on: Bool = Defaults[.installAgentSkill], turnedOff: Bool = Defaults[.agentSkillTurnedOff]
  ) -> DaemonBootstrap.AgentSkillPolicy {
    on ? .install : turnedOff ? .remove : .leave
  }

  /// The setting changed to `on`: remember a turn-off for the hosts, then install or remove here.
  func settingChanged(to on: Bool) {
    Defaults[.agentSkillTurnedOff] = !on
    apply(install: on)
  }

  /// At launch: brings the skill up to date while the setting is on. Off, nothing is touched.
  func launched() {
    if Defaults[.installAgentSkill] { apply(install: true) }
  }

  /// Installs or removes the skill, after whatever is under way.
  @discardableResult
  func apply(install: Bool) -> Task<Void, Never> {
    let previous = last
    applied += 1
    let turn = applied
    isApplying = true
    let task = Task { [runner, home] in
      await previous?.value
      let said: String?
      if let home {
        do {
          let report = try await runner(install, home)
          Self.logger.notice(
            "agent skill \(install ? "install" : "remove", privacy: .public): \(report.skills.map { "\($0.agent) \($0.state)" }.joined(separator: ", "), privacy: .public)"
          )
          said = Self.notice(for: report, install: install)
        } catch {
          Self.logger.error(
            "agent skill: \(error.localizedDescription, privacy: .public)")
          said =
            install
            ? "The skill couldn't be installed: \(error.localizedDescription)"
            : "The skill couldn't be removed: \(error.localizedDescription)"
        }
      } else {
        said = nil
      }
      // Only the last one asked says what happened.
      guard turn == self.applied else { return }
      self.notice = said
      self.isApplying = false
    }
    last = task
    return task
  }

  /// What a person needs to know of `report`, in the app's voice; nil when every agent's skill went
  /// as asked, or the agent isn't on this Mac.
  nonisolated static func notice(for report: AgentSkillReport, install: Bool) -> String? {
    let lines = report.skills.compactMap { skill -> String? in
      let name = skill.agent == "codex" ? "Codex" : "Claude Code"
      let path = (skill.path as NSString).abbreviatingWithTildeInPath
      switch skill.state {
      case "not-ours":
        return "\(path) is a skill Workroom didn't install, so \(name)'s was left alone."
      case "edited":
        return install
          ? "You edited \(path)/SKILL.md, so Workroom left it as it is."
          : "You edited \(path)/SKILL.md, so Workroom kept it."
      case "failed":
        return "\(name)'s skill at \(path) failed: \(skill.message ?? "unknown error")"
      default:
        return nil
      }
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
