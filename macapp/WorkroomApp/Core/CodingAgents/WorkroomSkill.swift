import Defaults
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import os

/// What `workroom skill install|remove` said of each coding agent's Workroom skill.
struct WorkroomSkillReport: Decodable, Equatable, Sendable {
  typealias Skill = DaemonBootstrap.Outcome.WorkroomSkill.Entry
  let skills: [Skill]
}

/// The Workroom skill for Claude Code and Codex (#697): Settings ▸ AI Agents' toggle
/// (`installWorkroomSkill`) installs it into each coding agent's skills folder on this Mac, and
/// removes it again, through the bundled CLI's `workroom skill`, which alone decides what is
/// Workroom's to write or delete and where each agent reads its skills (`CLAUDE_CONFIG_DIR` and
/// `CODEX_HOME` from the user's login shell, which this passes it).
///
/// Each host's bootstrap does the same on that host once connected (`hostPolicy`, `hostSynced`):
/// installed on every connect while the setting is on; removed once after it is turned off, from
/// each host it was installed on, the next time Workroom connects to it.
///
/// It is installed again at every launch while the setting is on, so an app update brings the
/// skill's text up to date, and a coding agent installed since gets it too.
@MainActor
final class WorkroomSkill: ObservableObject {
  static let shared = WorkroomSkill()

  /// Installs (`true`) or removes the skill in a home folder, with the coding agents' variables
  /// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) the CLI is to use; it is given no others.
  typealias Runner =
    @Sendable (_ install: Bool, _ home: String, _ variables: [String: String]) async throws ->
    WorkroomSkillReport

  /// What a person needs to know: a skill left alone, or one that failed, on this Mac or a host.
  /// Nil when everything went as asked.
  @Published private(set) var notice: String?
  /// Whether an install or removal on this Mac is under way.
  @Published private(set) var isApplying = false

  /// The home folder whose coding agents get the skill, or nil for a process that must not touch
  /// one (a hosted unit test, unless it passes its own).
  let home: String?
  /// Whether `home` is the user's own, whose login shell's variables say where the agents' skill
  /// folders are. A throwaway home gets none, so a test never reaches the developer's config.
  private let homeIsTheUsers: Bool
  private let runner: Runner
  /// The install or removal under way; the next waits for it, so the last one asked wins.
  private var last: Task<Void, Never>?
  private var applied = 0
  private var macNotice: String?
  private var hostNotices: [String: String] = [:]

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "WorkroomSkill")

  init(
    home: String? = WorkroomSkill.defaultHome(),
    runner: @escaping Runner = { install, home, variables in
      try await WorkroomCLI.shared.workroomSkill(
        install: install, home: home, variables: variables)
    }
  ) {
    self.home = home
    self.homeIsTheUsers = home == NSHomeDirectory() && WorkroomSkill.defaultHome() == home
    self.runner = runner
  }

  /// The user's home, or in a test process never it: a fixture launch's throwaway home, and none
  /// in a hosted unit run or a UI launch with live services.
  nonisolated static func defaultHome() -> String? {
    #if DEBUG
      let environment = AppEnvironment.current
      if environment.isFixture { return UITestFixture.workroomSkillHome.path }
      if environment.isTestProcess { return nil }
    #endif
    return NSHomeDirectory()
  }

  /// The variables that say where each coding agent reads its skills, from `environment`.
  nonisolated static let variableNames = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"]

  nonisolated static func agentVariables(from environment: [String: String]) -> [String: String] {
    environment.filter { variableNames.contains($0.key) && !$0.value.isEmpty }
  }

  /// A host as the settings keep it.
  nonisolated static func key(_ host: HostID) -> String {
    switch host {
    case .local: "local"
    case .remote(let id): id.uuidString
    }
  }

  /// What a connect does with the skill on `host`: install it while the setting is on; remove it
  /// once, after the setting was turned off, on a host it was installed on; otherwise leave the
  /// host alone, so a build that never had it on never takes away another build's skill.
  nonisolated static func hostPolicy(
    for host: HostID, on: Bool = Defaults[.installWorkroomSkill],
    pending: [String] = Defaults[.workroomSkillPendingRemoval]
  ) -> DaemonBootstrap.WorkroomSkillPolicy {
    on ? .install : pending.contains(key(host)) ? .remove : .leave
  }

  /// A host's connect synced the skill (`DaemonBootstrap.connect`): a host it went onto is
  /// remembered for the removal, a removal that finished (or found nothing to remove) is done,
  /// and anything left alone or failed is said in the setting.
  nonisolated static func hostSynced(
    _ host: HostID, policy: DaemonBootstrap.WorkroomSkillPolicy,
    result: DaemonBootstrap.Outcome.WorkroomSkill?
  ) {
    Task { @MainActor in shared.recordHost(host, policy: policy, result: result) }
  }

  func recordHost(
    _ host: HostID, policy: DaemonBootstrap.WorkroomSkillPolicy,
    result: DaemonBootstrap.Outcome.WorkroomSkill?
  ) {
    let key = Self.key(host)
    switch (policy, result) {
    case (.install, .done(let skills)):
      if skills.contains(where: { ["installed", "updated", "current"].contains($0.state) }),
        !Defaults[.workroomSkillHosts].contains(key)
      {
        Defaults[.workroomSkillHosts].append(key)
      }
      hostNotices[key] = Self.notice(for: WorkroomSkillReport(skills: skills), install: true)
        .map { "On a remote host: \($0)" }
    case (.install, .failed(let why)):
      hostNotices[key] = "On a remote host, the skill couldn't be installed: \(why)"
    case (.remove, .done(let skills)):
      Defaults[.workroomSkillPendingRemoval].removeAll { $0 == key }
      hostNotices[key] = Self.notice(for: WorkroomSkillReport(skills: skills), install: false)
        .map { "On a remote host: \($0)" }
    case (.remove, nil):
      // The probe found no Workroom skill there: nothing left to remove.
      Defaults[.workroomSkillPendingRemoval].removeAll { $0 == key }
      hostNotices[key] = nil
    case (.remove, .failed(let why)):
      // Kept, so the next connect tries again: a host whose daemon predates `workroom skill`
      // removes it once it is updated.
      hostNotices[key] = "On a remote host, the skill couldn't be removed yet: \(why)"
    case (.install, nil), (.leave, _):
      break
    }
    publishNotice()
  }

  /// The setting changed to `on`. Off, every host the skill went onto is due its removal at its
  /// next connect; on, none is. Then installs or removes it on this Mac.
  func settingChanged(to on: Bool) {
    if on {
      Defaults[.workroomSkillPendingRemoval] = []
    } else {
      let due = Defaults[.workroomSkillPendingRemoval] + Defaults[.workroomSkillHosts]
      Defaults[.workroomSkillPendingRemoval] = Array(Set(due)).sorted()
      Defaults[.workroomSkillHosts] = []
    }
    hostNotices = [:]
    apply(install: on)
  }

  /// At launch: brings the skill up to date while the setting is on. Off, nothing is touched.
  func launched() {
    if Defaults[.installWorkroomSkill] { apply(install: true) }
  }

  /// Installs or removes the skill on this Mac, after whatever is under way.
  @discardableResult
  func apply(install: Bool) -> Task<Void, Never> {
    let previous = last
    applied += 1
    let turn = applied
    isApplying = true
    let task = Task { [runner, home, homeIsTheUsers] in
      await previous?.value
      let said: String?
      if let home {
        do {
          // The user's own home goes where the user's login shell says the agents read their
          // skills; any other home, a test's, where it alone says.
          let variables =
            homeIsTheUsers ? Self.agentVariables(from: await ShellEnvironment.refresh()) : [:]
          let report = try await runner(install, home, variables)
          Self.logger.notice(
            "Workroom skill \(install ? "install" : "remove", privacy: .public): \(report.skills.map { "\($0.agent) \($0.state)" }.joined(separator: ", "), privacy: .public)"
          )
          said = Self.notice(for: report, install: install)
        } catch {
          Self.logger.error(
            "Workroom skill: \(error.localizedDescription, privacy: .public)")
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
      self.macNotice = said
      self.isApplying = false
      self.publishNotice()
    }
    last = task
    return task
  }

  private func publishNotice() {
    let lines =
      [macNotice].compactMap { $0 } + hostNotices.keys.sorted().compactMap { hostNotices[$0] }
    notice = lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  /// What a person needs to know of `report`, in the app's voice; nil when every coding agent's
  /// skill went as asked, or the agent isn't set up.
  nonisolated static func notice(for report: WorkroomSkillReport, install: Bool) -> String? {
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
