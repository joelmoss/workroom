import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain

/// The daemon bootstrap (HostDrivers' `DaemonBootstrap`) with what this app bundles: its Linux
/// daemons, its Ghostty resource set and the far-side scripts. Every connect in the app goes
/// through these; a test passes its own `daemon` or `resources` and still gets the bundle's scripts.
extension DaemonBootstrap {
  /// The bootstrap, then the connection: the one way to a remote host's services. Once connected,
  /// the host gets Settings ▸ AI Agents' Workroom skill setting (`WorkroomSkill.hostPolicy`),
  /// unless `workroomSkill` says otherwise, and the setting hears how it went; so does Settings ▸
  /// Terminal's Claude Code resume hook (`ClaudeResumeHook.hostPolicy`, #828), unless
  /// `resumeHook` says otherwise.
  static func connect(
    host: HostID, driver: any HostDriver, socket: String,
    daemon: (String) -> URL? = PersistentSessionPaths.linuxDaemonURL(architecture:),
    handOff: Bool = true, resources: URL? = GhosttyResources.bundledURL,
    workroomSkill: WorkroomSkillPolicy? = nil, resumeHook: WorkroomSkillPolicy? = nil
  ) async throws -> DaemonClient {
    try await connect(
      host: host, driver: driver, socket: socket, daemon: daemon, handOff: handOff,
      resources: resources, scripts: scripts,
      workroomSkill: workroomSkill ?? WorkroomSkill.beginHostSync(for: host),
      onWorkroomSkill: { policy, result in
        WorkroomSkill.hostSynced(host, policy: policy, result: result)
      },
      resumeHook: resumeHook ?? ClaudeResumeHook.beginHostSync(for: host),
      onResumeHook: { policy, result in
        ClaudeResumeHook.hostSynced(host, policy: policy, result: result)
      })
  }

  /// Makes sure the host runs this app's daemon, as far as the bootstrap's policy allows. The
  /// Workroom skill only when `workroomSkill` asks: a connect syncs it, after connecting.
  static func ensure(
    host: HostID, driver: any HostDriver, socket: String,
    daemon: (String) -> URL? = PersistentSessionPaths.linuxDaemonURL(architecture:),
    handOff: Bool = true, resources: URL? = GhosttyResources.bundledURL,
    workroomSkill: WorkroomSkillPolicy = .leave
  ) async throws -> Outcome {
    try await ensure(
      host: host, driver: driver, socket: socket, daemon: daemon, handOff: handOff,
      resources: resources, scripts: scripts, workroomSkill: workroomSkill)
  }

  /// The bundled far-side script `name`.
  static func script(named name: String) throws -> String {
    try script(named: name, in: scripts)
  }

  /// The far-side scripts, in `Contents/Resources/daemon-bootstrap`.
  static let scripts = bundledScripts(in: "daemon-bootstrap")
}
