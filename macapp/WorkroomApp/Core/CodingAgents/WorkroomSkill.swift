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

  // MARK: - The state, by construction
  //
  // One wanted state for every target, `installWorkroomSkill`, which the setting writes the
  // moment it changes; and per target, persisted, whether Workroom's skill may be there: this
  // Mac's `workroomSkillOnMac`, and each host in `workroomSkillHosts`. A target is marked the
  // moment an install is about to start (intent first, work second), and unmarked only once a
  // removal there went through for every folder, or found nothing, while the setting is still
  // off. Reconciling a target is then one rule: wanted on, install; wanted off and marked,
  // remove; otherwise leave it, so a build that never had it on touches nothing. Launch and each
  // connect reconcile, and so does every change of the setting, so neither a quit in the middle
  // nor a result that lands after the setting changed can leave the skill behind.

  /// What reconciling `host` does, from the wanted state and whether its skill may be there.
  nonisolated static func hostPolicy(
    for host: HostID, on: Bool = Defaults[.installWorkroomSkill],
    marked: [String] = Defaults[.workroomSkillHosts]
  ) -> DaemonBootstrap.WorkroomSkillPolicy {
    on ? .install : marked.contains(key(host)) ? .remove : .leave
  }

  /// A connect to `host` is about to reconcile it (`DaemonBootstrap.connect`): an install marks
  /// the host first, so however it ends (a quit, a lost link, a late result), the host stays due
  /// its removal once the setting is off.
  nonisolated static func beginHostSync(for host: HostID) -> DaemonBootstrap.WorkroomSkillPolicy {
    let policy = hostPolicy(for: host)
    if policy == .install, !Defaults[.workroomSkillHosts].contains(key(host)) {
      Defaults[.workroomSkillHosts].append(key(host))
    }
    return policy
  }

  /// A host's connect synced the skill (`DaemonBootstrap.connect`): reconciled against the wanted
  /// state as it is now, and anything left alone or failed said in the setting.
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
    // A removal that went through for every folder, or that the probe found nothing for, is the
    // only result that unmarks a host, and only while the setting is still off. An install, late
    // or not, leaves the mark its start made.
    let removedAll: Bool
    switch (policy, result) {
    case (.install, .done(let skills)):
      removedAll = false
      hostNotices[key] = Self.notice(for: WorkroomSkillReport(skills: skills), install: true)
        .map { "On a remote host: \($0)" }
    case (.install, .failed(let why)):
      removedAll = false
      hostNotices[key] = "On a remote host, the skill couldn't be installed: \(why)"
    case (.remove, .done(let skills)):
      // One folder that failed (a read-only disk, say) stays in the host's own record, and the
      // host stays marked, so the next connect retries.
      removedAll = !Self.anyFailed(skills)
      hostNotices[key] = Self.notice(for: WorkroomSkillReport(skills: skills), install: false)
        .map { "On a remote host: \($0)" }
    case (.remove, nil):
      removedAll = true
      hostNotices[key] = nil
    case (.remove, .failed(let why)):
      // A host whose daemon predates `workroom skill` removes it once it is updated.
      removedAll = false
      hostNotices[key] = "On a remote host, the skill couldn't be removed yet: \(why)"
    case (.install, nil), (.leave, _):
      removedAll = false
    }
    if removedAll, !Defaults[.installWorkroomSkill] {
      Defaults[.workroomSkillHosts].removeAll { $0 == key }
    }
    publishNotice()
  }

  /// The setting changed (the binding has already stored it): reconcile this Mac. Each host is
  /// reconciled at its next connect.
  @discardableResult
  func settingChanged(to on: Bool) -> Task<Void, Never>? {
    hostNotices = [:]
    return reconcile()
  }

  /// At launch: reconcile this Mac. On, that brings the skill up to date; off, it finishes a
  /// removal that a quit or a failure left undone; never had it on, it touches nothing.
  @discardableResult
  func launched() -> Task<Void, Never>? {
    reconcile()
  }

  /// This Mac, by the rule above: the work it started, or nil when there is none to do.
  @discardableResult
  func reconcile() -> Task<Void, Never>? {
    if Defaults[.installWorkroomSkill] { return apply(install: true) }
    if Defaults[.workroomSkillOnMac] { return apply(install: false) }
    return nil
  }

  /// Whether a folder's install or removal failed.
  nonisolated static func anyFailed(_ skills: [WorkroomSkillReport.Skill]) -> Bool {
    skills.contains { $0.state == "failed" }
  }

  /// Installs or removes the skill on this Mac, after whatever is under way. An install marks
  /// this Mac first; a removal unmarks it only once it went through for every folder and the
  /// setting is still off when it lands.
  @discardableResult
  func apply(install: Bool) -> Task<Void, Never> {
    if install { Defaults[.workroomSkillOnMac] = true }
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
          // A folder that failed stays in the CLI's record and this Mac stays marked, so the
          // next launch tries again; a setting turned back on meanwhile keeps the mark too.
          if !install, !Self.anyFailed(report.skills), !Defaults[.installWorkroomSkill] {
            Defaults[.workroomSkillOnMac] = false
          }
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
