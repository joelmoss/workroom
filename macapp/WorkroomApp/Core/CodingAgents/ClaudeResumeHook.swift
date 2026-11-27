import Defaults
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import os

/// What `workroom resume-hook install|remove` said of each Claude profile's `settings.json`.
struct ClaudeResumeHookReport: Decodable, Equatable, Sendable {
  typealias Profile = DaemonBootstrap.Outcome.WorkroomSkill.Entry
  let profiles: [Profile]
}

/// Claude Code's resume hook (#828, ADR 0082): while Settings ▸ Terminal's "Resume programs after
/// a restart" is on (`ProgramResume`), a `SessionStart` hook in each Claude profile's
/// `settings.json` reports how to resume Claude's conversation, since Claude doesn't report it
/// itself yet; turned off, the hook is removed. The bundled CLI's `workroom resume-hook` alone
/// decides what in a `settings.json` is Workroom's and where each profile is (`CLAUDE_CONFIG_DIR`
/// from the user's login shell, which this passes it). Codex gets no hook (ADR 0082).
///
/// The same state machine as the Workroom skill's (`WorkroomSkill`): one wanted state, the
/// setting; per target, persisted, whether Workroom's hook may be there (`claudeResumeHookOnMac`,
/// `claudeResumeHookHosts`), marked the moment an install is about to start and unmarked only
/// once a removal there went through while the setting is still off. Launch and every change of
/// the setting reconcile this Mac (`follow`); each connect reconciles its host
/// (`beginHostSync`, `hostSynced`).
@MainActor
final class ClaudeResumeHook: ObservableObject {
  static let shared = ClaudeResumeHook()

  /// Installs (`true`) or removes the hook in a home folder, with the `CLAUDE_CONFIG_DIR` the CLI
  /// is to use; it is given no other variable.
  typealias Runner =
    @Sendable (_ install: Bool, _ home: String, _ variables: [String: String]) async throws ->
    ClaudeResumeHookReport

  /// What a person needs to know: a profile whose `settings.json` was left alone because it
  /// couldn't be read or written, on this Mac or a host. Nil when everything went as asked.
  @Published private(set) var notice: String?

  /// The home folder whose Claude profiles get the hook, or nil for a process that must not touch
  /// one (`WorkroomSkill.defaultHome`: a hosted unit test, unless it passes its own).
  let home: String?
  private let homeIsTheUsers: Bool
  private let isOn: @MainActor () -> Bool
  private let runner: Runner
  /// The install or removal under way; the next waits for it, so the last one asked wins.
  private var last: Task<Void, Never>?
  private var applied = 0
  private var macNotice: String?
  private var hostNotices: [String: String] = [:]
  private var following: Task<Void, Never>?

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "ClaudeResumeHook")

  init(
    home: String? = WorkroomSkill.defaultHome(),
    isOn: @escaping @MainActor () -> Bool = { ProgramResume.isOn },
    runner: @escaping Runner = { install, home, variables in
      try await WorkroomCLI.shared.claudeResumeHook(
        install: install, home: home, variables: variables)
    }
  ) {
    self.home = home
    self.homeIsTheUsers = home == NSHomeDirectory() && WorkroomSkill.defaultHome() == home
    self.isOn = isOn
    self.runner = runner
  }

  // MARK: - Hosts

  /// What reconciling `host` does, from the wanted state and whether its hook may be there.
  nonisolated static func hostPolicy(
    for host: HostID, on: Bool = Defaults[.resumePrograms],
    marked: [String] = Defaults[.claudeResumeHookHosts]
  ) -> DaemonBootstrap.WorkroomSkillPolicy {
    on ? .install : marked.contains(WorkroomSkill.key(host)) ? .remove : .leave
  }

  /// A connect to `host` is about to reconcile it: an install marks the host first, so however it
  /// ends, the host stays due its removal once the setting is off.
  ///
  /// A test process leaves every host alone: the setting is on by default, and a live host test's
  /// host is a real one, whose Claude config is not a test's to write.
  nonisolated static func beginHostSync(for host: HostID) -> DaemonBootstrap.WorkroomSkillPolicy {
    #if DEBUG
      if AppEnvironment.current.isTestProcess || AppEnvironment.current.isFixture { return .leave }
    #endif
    let policy = hostPolicy(for: host)
    let key = WorkroomSkill.key(host)
    if policy == .install, !Defaults[.claudeResumeHookHosts].contains(key) {
      Defaults[.claudeResumeHookHosts].append(key)
    }
    return policy
  }

  /// A host's connect synced the hook: reconciled against the wanted state as it is now.
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
    let key = WorkroomSkill.key(host)
    var removedAll = false
    switch (policy, result) {
    case (.install, .done(let profiles)), (.remove, .done(let profiles)):
      removedAll = policy == .remove && !Self.anyFailed(profiles)
      hostNotices[key] = Self.notice(for: profiles).map { "On a remote host: \($0)" }
    case (.install, .failed(let why)):
      hostNotices[key] = "On a remote host, Claude Code's resume hook couldn't be added: \(why)"
    case (.remove, .failed(let why)):
      // A host whose daemon predates `resume-hook` has none to remove; it is tried again at
      // each connect until it goes through.
      hostNotices[key] = "On a remote host, Claude Code's resume hook couldn't be removed: \(why)"
    case (_, nil), (.leave, _):
      break
    }
    if removedAll, !isOn() {
      Defaults[.claudeResumeHookHosts].removeAll { $0 == key }
    }
    publishNotice()
  }

  // MARK: - This Mac

  /// At launch: reconcile this Mac now and at every change of the setting.
  func follow() {
    guard following == nil else { return }
    following = Task { [weak self] in
      for await _ in ProgramResume.updates() {
        guard let self else { return }
        self.hostNotices = [:]
        await self.reconcile()?.value
      }
    }
  }

  /// This Mac, by the rule above: the work it started, or nil when there is none to do.
  @discardableResult
  func reconcile() -> Task<Void, Never>? {
    if isOn() { return apply(install: true) }
    if Defaults[.claudeResumeHookOnMac] { return apply(install: false) }
    return nil
  }

  nonisolated static func anyFailed(_ profiles: [ClaudeResumeHookReport.Profile]) -> Bool {
    profiles.contains { $0.state == "failed" }
  }

  /// Installs or removes the hook on this Mac, after whatever is under way. An install marks this
  /// Mac first; a removal unmarks it only once it went through for every profile and the setting
  /// is still off when it lands.
  @discardableResult
  func apply(install: Bool) -> Task<Void, Never> {
    if install { Defaults[.claudeResumeHookOnMac] = true }
    let previous = last
    applied += 1
    let turn = applied
    let task = Task { [runner, home, homeIsTheUsers] in
      await previous?.value
      let said: String?
      if let home {
        do {
          // The user's own home goes where their login shell says the profile is; any other
          // home, a test's, where it alone says.
          let variables =
            homeIsTheUsers
            ? WorkroomSkill.agentVariables(from: await ShellEnvironment.refresh())
              .filter { $0.key == "CLAUDE_CONFIG_DIR" } : [:]
          let report = try await runner(install, home, variables)
          Self.logger.notice(
            "Claude resume hook \(install ? "install" : "remove", privacy: .public): \(report.profiles.map(\.state).joined(separator: ", "), privacy: .public)"
          )
          said = Self.notice(for: report.profiles)
          if !install, !Self.anyFailed(report.profiles), !self.isOn() {
            Defaults[.claudeResumeHookOnMac] = false
          }
        } catch {
          Self.logger.error(
            "Claude resume hook: \(error.localizedDescription, privacy: .public)")
          said =
            install
            ? "Claude Code's resume hook couldn't be added: \(error.localizedDescription)"
            : "Claude Code's resume hook couldn't be removed: \(error.localizedDescription)"
        }
      } else {
        said = nil
      }
      guard turn == self.applied else { return }
      self.macNotice = said
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

  /// What a person needs to know of `profiles`, in the app's voice: each `settings.json` Workroom
  /// left alone because it couldn't be read, parsed or written. Nil when every profile went as
  /// asked, or isn't set up.
  nonisolated static func notice(for profiles: [ClaudeResumeHookReport.Profile]) -> String? {
    let lines = profiles.filter { $0.state == "failed" }.map { profile -> String in
      let path = (profile.path as NSString).abbreviatingWithTildeInPath
      return "Claude Code's resume hook isn't in \(path): \(profile.message ?? "unknown error")"
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
