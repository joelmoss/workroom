import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS

/// Where a remote workroom's clone lives (ADR 0056): on a host made for it alone
/// (`ProvisionedHostPlacement`: boxd, exe.dev, a container), or in a folder of its own on the
/// user's SSH server (`SSHFolderPlacement`), which Workroom never makes or destroys. A create makes
/// the placement, then clones and checks out on its host through one `RemoteProvisioning.place`,
/// which undoes the placement when a later step fails.
protocol Placement: Sendable {
  /// How the user gives the host GitHub access, said after git's own words when the clone fails,
  /// or nil where Workroom gives it.
  var credentialHint: String? { get }
  /// Makes the place and returns its host. `place` undoes nothing when this throws; a driver that
  /// leaves a host behind says so itself (`HostDriverError.leftBehind`).
  func make() async throws -> HostID
  /// Undoes `make`: nil when nothing is left, else what is still there, as
  /// `RemoteProvisioning.Failure.rollbackIncomplete` names it.
  func unmake(_ host: HostID) async -> String?
}

/// A host made for one workroom: its provider (or this Mac's container runtime) makes it, and it is
/// destroyed with the workroom.
struct ProvisionedHostPlacement: Placement {
  let environment: RemoteProvisioning.Environment

  var credentialHint: String? { environment.credentialHint }

  func make() async throws -> HostID {
    if let makeHost = environment.makeHost { return try await makeHost() }
    guard let driver = environment.driver as? any ProvisioningHostDriver else {
      throw HostDriverError.invalidConfiguration("This host cannot be provisioned")
    }
    return try await driver.create()
  }

  func unmake(_ host: HostID) async -> String? {
    do { try await RemoteProvisioning.tearDown(host: host, in: environment) } catch {
      return "destroying the instance: \(error.localizedDescription)"
    }
    return nil
  }
}

/// A workroom's own folder at `path` on the user's SSH server: made and marked for `workroom`, and
/// removed only where that mark names it. The server stays.
struct SSHFolderPlacement: Placement {
  let driver: SSHHostDriver
  let path: String
  let workroom: UUID

  var credentialHint: String? { HostKind.ssh.credentialHint }

  func make() async throws -> HostID {
    ProvisioningProgress.reportStep?(.machine)
    try await driver.prepareFolder(path: path, workroom: workroom)
    return driver.hostID
  }

  func unmake(_ host: HostID) async -> String? {
    do { try await driver.removeFolder(path: path, workroom: workroom) } catch {
      return error.localizedDescription
    }
    return nil
  }
}
