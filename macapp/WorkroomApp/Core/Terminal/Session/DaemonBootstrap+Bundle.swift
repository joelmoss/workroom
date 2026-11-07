import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain

/// The daemon bootstrap (HostDrivers' `DaemonBootstrap`) with what this app bundles: its Linux
/// daemons, its Ghostty resource set and the far-side scripts. Every connect in the app goes
/// through these; a test passes its own `daemon` or `resources` and still gets the bundle's scripts.
extension DaemonBootstrap {
  /// The bootstrap, then the connection: the one way to a remote host's services.
  static func connect(
    host: HostID, driver: any HostDriver, socket: String,
    daemon: (String) -> URL? = PersistentSessionPaths.linuxDaemonURL(architecture:),
    handOff: Bool = true, resources: URL? = GhosttyResources.bundledURL
  ) async throws -> DaemonClient {
    try await connect(
      host: host, driver: driver, socket: socket, daemon: daemon, handOff: handOff,
      resources: resources, scripts: bundledScript(named:))
  }

  /// Makes sure the host runs this app's daemon, as far as the bootstrap's policy allows.
  static func ensure(
    host: HostID, driver: any HostDriver, socket: String,
    daemon: (String) -> URL? = PersistentSessionPaths.linuxDaemonURL(architecture:),
    handOff: Bool = true, resources: URL? = GhosttyResources.bundledURL
  ) async throws -> Outcome {
    try await ensure(
      host: host, driver: driver, socket: socket, daemon: daemon, handOff: handOff,
      resources: resources, scripts: bundledScript(named:))
  }

  /// The bundled far-side script `name`.
  static func script(named name: String) throws -> String {
    try script(named: name, in: bundledScript(named:))
  }

  /// Where the build phase put the scripts: `Contents/Resources/daemon-bootstrap`.
  static func bundledScript(named name: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: "sh", subdirectory: "daemon-bootstrap")
  }
}
