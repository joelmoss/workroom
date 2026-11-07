import DaemonConnection
import Foundation
import WorkroomDomain

// What a driver can do beyond `HostDriver`, each asked of `any HostDriver` with `as? any <it>`, as
// `DaemonPlacingDriver` and `ProvisioningHostDriver` are (ADR 0067). The app decides when to ask;
// the driver says what is so. A driver that can't do one simply doesn't conform.

/// What a driver's provider says of a host without reaching it, for a background read that must
/// not wake it (#356).
public enum HostPresence: Equatable, Sendable { case awake, asleep, gone }

/// A driver whose hosts sleep, and whose provider can say so without the ssh login that would wake
/// one (boxd).
public protocol HostPresenceReporting: HostDriver {
  /// Whether `host` is awake, asleep or gone; nil when the provider could not say.
  func presence(_ host: HostID) async -> HostPresence?
}

/// A driver whose hosts can be stopped, and started again on this Mac (containers, #309).
public protocol StartableHostDriver: HostDriver {
  /// Starts `host` if it is stopped, and waits until it can be reached.
  func startIfStopped(_ host: HostID) async throws
  /// What `host` runs on the first connect after each start (a container's postStartCommand,
  /// #308): nil when there was nothing to run, else how it ended and what it printed.
  func runPostStartIfNeeded(on host: HostID) async throws -> (status: Int32, output: String)?
}

/// A driver whose exchanges with a host share a connection it keeps (an SSH control master, ADR
/// 0056).
public protocol ReconnectingHostDriver: HostDriver {
  /// Drops that shared connection, so the next exchange opens a new one: after a wake or a network
  /// change found the host not answering, rather than inherit a dead link.
  func invalidateConnection() async
}

/// A driver that makes a host with the host options a create resolved (#575: boxd, exe.dev).
public protocol OptionedProvisioningDriver: ProvisioningHostDriver {
  func create(options: ResolvedHostOptions) async throws -> HostID
}

/// A driver whose host made from an image can still hold another workroom's checkout: boxd's images
/// are snapshots of used machines (#575).
public protocol CheckoutClearingDriver: HostDriver {
  /// Removes a checkout of `cloneURL` at `path` on `host`, and nothing else there.
  func clearCheckout(at path: String, of cloneURL: String, on host: HostID) async throws
}

/// A driver whose provider gives each repository its hosts may clone access to, which Workroom
/// adds before the first host is made (exe.dev's GitHub integration, ADR 0049).
public protocol RepositoryGranting: HostDriver {
  func grantGitHub(host: String, owner: String, name: String) async throws
}

/// A driver that keeps what it needs to reach a host in the host's descriptor, so a later launch,
/// which knows the host only from config, reaches it again: a container's record, an SSH host's
/// destination and home.
public protocol HostRecording: HostDriver {
  /// Writes what this driver knows of `host` into `descriptor`'s fields of its kind.
  func record(_ host: HostID, in descriptor: inout HostDescriptor)
  /// Takes back what `descriptor` recorded, as a reload does; nothing for a host already held.
  func adopt(_ descriptor: HostDescriptor) throws
}

/// A driver that puts each workroom in a folder of its own on a host it did not make (an SSH host,
/// ADR 0056). A create makes the folder and marks it; only a folder the mark names is removed.
public protocol FolderPlacingDriver: HostTerminalDriver {
  /// The host, as the user names it.
  var destination: String { get }
  /// Whether the folder at `path` is still there, checked against `workroom`'s mark.
  func folderState(path: String, workroom: UUID) async throws -> WorkroomFolderState
  /// Removes the folder at `path` and its mark, only when the mark names `workroom` and `path`.
  func removeFolder(path: String, workroom: UUID) async throws
}

/// Whether a workroom's folder on a host is still there (`FolderPlacingDriver.folderState`).
public enum WorkroomFolderState: Sendable, Equatable { case present, gone }

/// What a provider says about the host options it takes (#575), for the option fields.
public enum HostOptionsFacts: Equatable, Sendable {
  /// The account's snapshots and the org's default size, nil when that one read failed.
  case boxd(snapshots: [String], size: BoxdHostDriver.DefaultSize?)
  case exeDev(ExeDevHostDriver.PlanLimits)
}

/// A driver whose provider says what host options it takes (#575).
public protocol HostOptionsReading: HostDriver {
  func readHostOptions() async throws -> HostOptionsFacts
}

/// What the app registers a remote pane against when no driver holds its host: one this build
/// can't reach (a container whose runtime isn't on this Mac, or a record naming no driver it
/// knows). It holds no host and keeps no files, so the pane says it couldn't reach the host rather
/// than open a shell on this Mac, and nothing a real driver recorded is read for it.
public struct UnreachableHostDriver: HostTerminalDriver {
  public init() {}

  public var linkCrossesNetwork: Bool { false }

  public func openStream(to host: HostID) async throws -> HostStream {
    throw HostDriverError.unknownHost(host)
  }

  public func exec(_ command: String, on host: HostID) async throws -> HostStream {
    throw HostDriverError.unknownHost(host)
  }

  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)], runCommand: String?
  ) throws -> String {
    throw HostDriverError.unknownHost(host)
  }

  public func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool { false }

  /// No attach of its own ever ran, so none recorded a status.
  public func lastAttach(of session: UUID, on host: HostID) -> LastAttach { .unrecorded }
}
