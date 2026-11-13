import DaemonConnection
import Defaults
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS

/// The app's remote hosts (#253), one set for the whole app (`shared`): `registry`, which makes
/// every driver and knows which one holds each host config records, and `reachability`, which
/// connects to them. The two are made together, over the one registry, so that a reload's
/// `reachability.adopt` tells both what config records. Also the folders and CLIs every driver is
/// made with.
final class RemoteHosts: Sendable {
  static let shared = RemoteHosts()

  /// Which driver a host is in (#309, #356): its kind (`HostKind`), and who that driver acts for.
  /// A container runtime on this Mac, and for Docker the context it names (nil names none); a boxd
  /// org (nil is the account's own) and account; an exe.dev account; or an SSH destination.
  enum DriverKey: Hashable, Sendable {
    case container(ContainerRuntime, context: String?)
    case boxd(org: String?, account: String?)
    /// An exe.dev account, `whoami`'s email (#259).
    case exeDev(account: String?)
    /// A Railway environment of this Mac's (#629): the one a host's record names, or the one a
    /// create makes its sandbox in.
    case railway(environment: String)
    case ssh(destination: String)

    /// The driver a recorded host is in, or nil for a descriptor of no driver this build knows, and
    /// for an SSH host whose destination doesn't check out.
    init?(_ descriptor: HostDescriptor) {
      switch descriptor.kind {
      case .ssh:
        guard let destination = descriptor.sshDestination,
          (try? SSHHostDriver.validateDestination(destination)) != nil
        else { return nil }
        self = .ssh(destination: destination)
      case .boxd: self = .boxd(org: descriptor.org, account: descriptor.account)
      case .exeDev: self = .exeDev(account: descriptor.account)
      case .railway:
        guard let environment = descriptor.railway?.environmentID else { return nil }
        self = .railway(environment: environment)
      case .container(let runtime):
        self.init(runtime: runtime, context: descriptor.container?.context)
      case nil: return nil
      }
    }

    init(runtime: ContainerRuntime = .docker, context: String? = nil) {
      // Apple's runtime has no contexts.
      self = .container(runtime, context: runtime == .docker ? context : nil)
    }

    /// The kind of host this driver makes and reaches.
    var kind: HostKind {
      switch self {
      case .container(let runtime, _): .container(runtime)
      case .boxd: .boxd
      case .exeDev: .exeDev
      case .railway: .railway
      case .ssh: .ssh
      }
    }

    /// Whether the key names a remote provider rather than a container runtime on this Mac
    /// (`HostKind.isRemoteProvider`).
    var isRemoteProvider: Bool { kind.isRemoteProvider }

    /// The user its driver's hosts log in as, whose home holds the clone.
    var loginUser: String {
      switch self {
      case .container: RemoteWorkrooms.user
      case .boxd: BoxdHostDriver.user
      case .exeDev: ExeDevHostDriver.user
      case .railway: RailwayHostDriver.user
      case .ssh: ""
      }
    }

    /// That user's home, which holds the clone: a Railway sandbox logs in as root.
    var loginHome: String {
      if case .railway = self { return "/root" }
      return "/home/\(loginUser)"
    }

    /// The container runtime, or nil for a remote provider.
    var runtime: ContainerRuntime? {
      if case .container(let runtime) = kind { return runtime }
      return nil
    }

    /// The Docker context a container key names; nil for none, and for boxd.
    var context: String? {
      if case .container(_, let context) = self { return context }
      return nil
    }

    /// A boxd key's org and account; nil for a container key.
    var org: String? {
      if case .boxd(let org, _) = self { return org }
      return nil
    }
    var account: String? {
      switch self {
      case .boxd(_, let account), .exeDev(let account): account
      case .container, .railway, .ssh: nil
      }
    }
  }

  /// Where every driver is made, and which one holds each recorded host (ADR 0067).
  let registry: HostDriverRegistry
  /// How each host is connected to, backed off and relayed.
  let reachability: HostReachability

  /// Seams, nil in the app: `HostReachability`'s connect, connected check, start, clock, relay,
  /// daemon connection and presence, and `HostDriverRegistry`'s driver making, sweep and pending
  /// folder.
  init(
    connectHost: (@Sendable (HostID) async throws -> Void)? = nil,
    isConnected: (@Sendable (HostID) async -> Bool)? = nil,
    startHost: (@Sendable (HostID) async throws -> Void)? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)? = nil,
    makeContainerDriver: (@Sendable (DriverKey) throws -> ContainerHostDriver)? = nil,
    sweepDriver: (
      @Sendable (ContainerHostDriver, Set<UUID>, Set<String>, Bool) async -> [String]
    )? =
      nil,
    relayHost: (@Sendable (HostID) async throws -> Void)? = nil,
    connectDaemon: (
      @Sendable (HostID, any HostTerminalDriver) async throws -> DaemonClient
    )? =
      nil,
    presence: (@Sendable (HostID) async -> HostPresence?)? = nil,
    pendingIn: URL? = RemoteHosts.pendingIn
  ) {
    registry = HostDriverRegistry(
      makeDriver: makeDriver, makeContainerDriver: makeContainerDriver, sweepDriver: sweepDriver,
      pendingIn: pendingIn)
    reachability = HostReachability(
      registry: registry, connectHost: connectHost, isConnected: isConnected,
      startHost: startHost, now: now, relayHost: relayHost, connectDaemon: connectDaemon,
      presence: presence)
  }

  /// Where every driver writes its hosts' files.
  static var hosts: URL { directory.appendingPathComponent("hosts", isDirectory: true) }

  static var sshStateDirectoryName: String {
    RemoteWorkrooms.sharedHostBuilds.contains(RemoteWorkrooms.provisioner)
      ? "workroom" : "workroom-dev"
  }

  /// `hosts`, except under test (a hosted unit run or a UI-test launch), which must never sweep
  /// the developer's own runtime.
  static var pendingIn: URL? { AppEnvironment.current.isTestProcess ? nil : hosts }

  /// `Application Support/Workroom/<bundle id>/remote`.
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
      .appendingPathComponent(
        Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom", isDirectory: true
      )
      .appendingPathComponent("remote", isDirectory: true)
  }

  /// Where `docker` usually is. A GUI app's PATH has none of them.
  static let runtimeCandidates = [
    "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker",
  ]
  /// Where Apple's `container` is: its installer's, or Homebrew's.
  static let appleCandidates = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

  /// Where the boxd CLI is (#356): its installer's (`~/.local/bin`), or Homebrew's. Under a
  /// stand-in home (`boxdHome`), only that home's, so a boxd the developer has installed doesn't
  /// skip the setup's Install step and the one it installs is the one found.
  static var boxdCandidates: [String] {
    let installed = boxdHome.appendingPathComponent(".local/bin/boxd").path
    guard boxdHome == FileManager.default.homeDirectoryForCurrentUser else { return [installed] }
    return [installed, "/opt/homebrew/bin/boxd", "/usr/local/bin/boxd"]
  }

  /// The home the boxd CLI runs with, which holds its sign-in and the ssh files it writes: the
  /// user's own. Debug builds only: `$WR_BOXD_HOME` instead, a stand-in home, so a developer can be a
  /// user boxd has never seen without signing their own boxd out (`Scripts/boxd-fresh-user.sh`).
  static let boxdHome: URL = {
    #if DEBUG
      if let path = ProcessInfo.processInfo.environment["WR_BOXD_HOME"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif
    return FileManager.default.homeDirectoryForCurrentUser
  }()

  /// The boxd CLI on this Mac, or nil when it isn't installed.
  static func boxdExecutable() -> String? {
    boxdCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// `runtime`'s CLI on this Mac, or nil when it isn't installed.
  static func executable(for runtime: ContainerRuntime) -> String? {
    (runtime == .docker ? runtimeCandidates : appleCandidates).first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  /// What each container workroom on `runtime` gets (#309): the hidden settings, else for Apple's
  /// runtime, whose own default is a 1 GB VM per container, half this Mac's cores and a quarter of
  /// its memory, between 2 and 8 GB. Docker's containers share Docker's VM, which already bounds
  /// them, so they get nothing unless set.
  static func resources(
    for runtime: ContainerRuntime, cpus: Int? = Defaults[.containerCPUs],
    memory: String? = Defaults[.containerMemory],
    cores: Int = ProcessInfo.processInfo.activeProcessorCount,
    physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
  ) -> (cpus: Int?, memory: String?) {
    guard runtime == .apple else { return (cpus, memory) }
    let gigabytes = min(max(Int(physicalMemory / 4 / 1_073_741_824), 2), 8)
    return (cpus ?? max(2, cores / 2), memory ?? "\(gigabytes)G")
  }
}

extension PendingMachines.Entry {
  var key: RemoteHosts.DriverKey? {
    RemoteHosts.DriverKey(HostDescriptor(driver: driver, org: org, account: account))
  }
}
