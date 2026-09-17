import Foundation

/// A host instance, independent of its current network address.
enum HostID: Hashable, Sendable {
  case local
  case remote(UUID)
}

enum RepositoryRoutingError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
  case invalidPath(String)
  case mixedHosts
  case unavailable(HostID)
  case registrationRequired

  var description: String { errorDescription ?? "Repository unavailable" }

  var errorDescription: String? {
    switch self {
    case .invalidPath(let path): return "Invalid repository path: \(path)"
    case .mixedHosts: return "Working and shared repositories must be on the same host."
    case .unavailable: return "Repository service unavailable."
    case .registrationRequired:
      return "Reload projects to register this repository before changing it."
    }
  }
}

/// Only completed validation can produce a key. Equality and hashing never touch the filesystem.
struct RepositoryLocation: Hashable, Sendable {
  let host: HostID
  let path: String

  private init(host: HostID, path: String) {
    self.host = host
    self.path = path
  }

  static func local(_ path: String) async throws -> Self {
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
  static func remote(host: UUID, path: String) throws -> Self {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard path.hasPrefix("/"), !path.contains("\0"),
      !components.contains("."), !components.contains("..")
    else { throw RepositoryRoutingError.invalidPath(path) }
    return Self(host: .remote(host), path: "/" + components.joined(separator: "/"))
  }

  func requireLocalURL() throws -> URL {
    guard host == .local else { throw RepositoryRoutingError.unavailable(host) }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}

enum RepositoryBackend: String, Hashable, Sendable {
  case git, jj
}

/// Immutable routing decision. Only the router constructs contexts from a captured registry entry.
struct RepositoryContext: Hashable, Sendable {
  let location: RepositoryLocation
  let backend: RepositoryBackend
  /// Unknown for a fallback read. Never invent ownership from an unregistered workspace's path.
  let sharedLocation: RepositoryLocation?

  fileprivate init(
    location: RepositoryLocation, backend: RepositoryBackend,
    sharedLocation: RepositoryLocation?
  ) throws {
    guard sharedLocation == nil || sharedLocation?.host == location.host else {
      throw RepositoryRoutingError.mixedHosts
    }
    self.location = location
    self.backend = backend
    self.sharedLocation = sharedLocation
  }

  func requireOwnership() throws -> RepositoryLocation {
    guard let sharedLocation else { throw RepositoryRoutingError.registrationRequired }
    return sharedLocation
  }
}

/// Local input → async canonicalization ─┐
/// Remote input → pure validation ────────┴→ location → captured registry entry → bound services
///   Unregistered local: probe for immutable reads; snapshots/writes require registration.
///   Unregistered remote: unavailable, with no local filesystem or provider access.
final class RepositoryRouter: @unchecked Sendable {
  struct Entry: Hashable, Sendable {
    let backend: RepositoryBackend
    let sharedLocation: RepositoryLocation
  }

  struct Registration: Sendable {
    let location: RepositoryLocation
    let entry: Entry
    let localSourcePath: String?

    init(
      location: RepositoryLocation, backend: RepositoryBackend,
      sharedLocation: RepositoryLocation, localSourcePath: String? = nil
    ) throws {
      guard location.host == sharedLocation.host else { throw RepositoryRoutingError.mixedHosts }
      self.location = location
      self.localSourcePath = localSourcePath
      self.entry = Entry(backend: backend, sharedLocation: sharedLocation)
    }
  }

  static let shared = RepositoryRouter()
  private let lock = NSLock()
  private var entries: [RepositoryLocation: Entry] = [:]
  private var localLocations: [String: RepositoryLocation] = [:]

  /// Injected remote factories never fall back to local services.
  let remoteReader: @Sendable (RepositoryContext) throws -> VCSProviding
  let remoteWriter: @Sendable (RepositoryContext, VCSProviding) throws -> VCSWriting

  init(
    remoteReader: @escaping @Sendable (RepositoryContext) throws -> VCSProviding = {
      throw RepositoryRoutingError.unavailable($0.location.host)
    },
    remoteWriter: @escaping @Sendable (RepositoryContext, VCSProviding) throws -> VCSWriting = {
      context, _ in throw RepositoryRoutingError.unavailable(context.location.host)
    }
  ) {
    self.remoteReader = remoteReader
    self.remoteWriter = remoteWriter
  }

  static func prepare(_ projects: [Project]) async throws -> [Registration] {
    var registrations: [Registration] = []
    for project in projects {
      guard let backend = RepositoryBackend(rawValue: project.vcs) else { continue }
      let shared = try await RepositoryLocation.local(project.path)
      registrations.append(
        try Registration(
          location: shared, backend: backend, sharedLocation: shared, localSourcePath: project.path)
      )
      for workroom in project.workrooms {
        let location = try await RepositoryLocation.local(workroom.path)
        registrations.append(
          try Registration(
            location: location, backend: backend, sharedLocation: shared,
            localSourcePath: workroom.path))
      }
    }
    return registrations
  }

  func replaceLocal(_ registrations: [Registration]) {
    let local = registrations.filter { $0.location.host == .local }
    lock.withLock {
      entries = entries.filter { $0.key.host != .local }
      localLocations = [:]
      for registration in local {
        entries[registration.location] = registration.entry
        localLocations[registration.location.path] = registration.location
        if let source = registration.localSourcePath {
          localLocations[source] = registration.location
        }
      }
    }
  }

  func register(_ registration: Registration) {
    lock.withLock {
      entries[registration.location] = registration.entry
      if registration.location.host == .local {
        localLocations[registration.location.path] = registration.location
        if let source = registration.localSourcePath {
          localLocations[source] = registration.location
        }
      }
    }
  }

  /// Listing aliases were normalized during preparation. This lookup does no filesystem work.
  func localLocation(for path: String) -> RepositoryLocation? {
    lock.withLock { localLocations[path] }
  }

  func entry(for location: RepositoryLocation) -> Entry? {
    lock.withLock { entries[location] }
  }

  func context(for location: RepositoryLocation) async throws -> RepositoryContext {
    if let entry = entry(for: location) {
      return try RepositoryContext(
        location: location, backend: entry.backend,
        sharedLocation: entry.sharedLocation)
    }
    let root = try location.requireLocalURL()
    let kind = try await runBlocking { VCS.repoKind(at: root) }
    let backend: RepositoryBackend
    switch kind {
    case .plainGit: backend = .git
    case .jjColocated, .jjNonColocated: backend = .jj
    case .unsupported(let reason): throw VCSError.unsupportedRepo(reason)
    }
    return try RepositoryContext(location: location, backend: backend, sharedLocation: nil)
  }

  func reader(for location: RepositoryLocation) async throws -> VCSProviding {
    try reader(context: await context(for: location))
  }

  private func reader(context: RepositoryContext) throws -> VCSProviding {
    guard context.location.host == .local else { return try remoteReader(context) }
    let provider: LocalVCSProviding = context.backend == .jj ? RustJJProvider() : GitProvider()
    return BoundLocalReader(context: context, provider: provider)
  }

  func registeredContext(for location: RepositoryLocation) throws -> RepositoryContext {
    guard let entry = entry(for: location) else {
      if location.host == .local { throw RepositoryRoutingError.registrationRequired }
      throw RepositoryRoutingError.unavailable(location.host)
    }
    return try RepositoryContext(
      location: location, backend: entry.backend,
      sharedLocation: entry.sharedLocation)
  }

  func gitHub(
    for location: RepositoryLocation,
    resolver: WorkroomStatusResolver = WorkroomStatusResolver()
  ) async throws -> RepositoryGitHub {
    try RepositoryGitHub(context: await context(for: location), resolver: resolver)
  }

  func writer(for location: RepositoryLocation) async throws -> VCSWriting {
    let context = try registeredContext(for: location)
    _ = try context.requireOwnership()
    let reader = try reader(context: context)
    guard location.host == .local else { return try remoteWriter(context, reader) }
    let provider: LocalVCSProviding = context.backend == .jj ? RustJJProvider() : GitProvider()
    let writer = CLIVCSWriter(
      vcs: context.backend.rawValue, runner: StatusCommandRunner(),
      makeProvider: { _ in provider }, gate: .shared)
    return try BoundLocalWriter(context: context, reader: reader, writer: writer)
  }
}
