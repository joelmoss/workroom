import Foundation
import WorkroomDomain
import WorkroomSystem

/// Only completed validation can produce a key. Equality and hashing never touch the filesystem.
public struct RepositoryLocation: Hashable, Sendable {
  public let host: HostID
  public let path: String

  private init(host: HostID, path: String) {
    self.host = host
    self.path = path
  }

  public static func local(_ path: String) async throws -> Self {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw RepositoryRoutingError.invalidPath(path)
    }
    return try await runBlocking {
      Self(
        host: .local,
        path: URL(fileURLWithPath: path)
          .standardizedFileURL.resolvingSymlinksInPath().path)
    }
  }

  /// POSIX paths on another host: no URL interpretation, case folding, or local symlink lookup.
  public static func remote(host: UUID, path: String) throws -> Self {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard path.hasPrefix("/"), !path.contains("\0"),
      !components.contains("."), !components.contains("..")
    else { throw RepositoryRoutingError.invalidPath(path) }
    return Self(host: .remote(host), path: "/" + components.joined(separator: "/"))
  }

  public func requireLocalURL() throws -> URL {
    guard host == .local else { throw RepositoryRoutingError.unavailable(host) }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}

/// Immutable routing decision. Only the router constructs contexts from a captured registry entry:
/// its initializer is SPI, so only a file that imports `@_spi(RepositoryRouting) WorkroomVCS` (the
/// app's `RepositoryRouter`) can call it.
public struct RepositoryContext: Hashable, Sendable {
  public let location: RepositoryLocation
  /// Unknown for a fallback read. Never invent ownership from an unregistered workspace's path.
  public let sharedLocation: RepositoryLocation?

  @_spi(RepositoryRouting)
  public init(location: RepositoryLocation, sharedLocation: RepositoryLocation?) throws {
    guard sharedLocation == nil || sharedLocation?.host == location.host else {
      throw RepositoryRoutingError.mixedHosts
    }
    self.location = location
    self.sharedLocation = sharedLocation
  }

  public func requireOwnership() throws -> RepositoryLocation {
    guard let sharedLocation else { throw RepositoryRoutingError.registrationRequired }
    return sharedLocation
  }
}
