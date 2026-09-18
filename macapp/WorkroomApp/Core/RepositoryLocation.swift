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

  static let shared: RepositoryRouter = {
    #if DEBUG
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return RepositoryRouter()
      }
    #endif
    return RepositoryRouter(
      localReader: { try await LocalAgentVCS.shared.reader(context: $0) },
      localWriter: { try await LocalAgentVCS.shared.writer(context: $0) })
  }()
  private let lock = NSLock()
  private var entries: [RepositoryLocation: Entry] = [:]
  private var localLocations: [String: RepositoryLocation] = [:]

  /// Injected remote factories never fall back to local services.
  let remoteReader: @Sendable (RepositoryContext) throws -> VCSProviding
  let remoteWriter: @Sendable (RepositoryContext, VCSProviding) throws -> VCSWriting
  private let connections: HostConnectionManager?
  private let localReader: (@Sendable (RepositoryContext) async throws -> VCSProviding)?
  /// nil in every test router that doesn't opt in (the vast majority, read-focused) — `writer(for:)`
  /// then goes straight to the native `CLIVCSWriter` fallback it always has, unchanged.
  private let localWriter: (@Sendable (RepositoryContext) async throws -> VCSWriting)?

  /// Production routers share app-wide host connections. Tests can retain native local providers
  /// or inject an isolated agent without starting a service against the user's session socket.
  init(
    connections: HostConnectionManager = .shared,
    localReader: (@Sendable (RepositoryContext) async throws -> VCSProviding)? = nil,
    localWriter: (@Sendable (RepositoryContext) async throws -> VCSWriting)? = nil
  ) {
    self.connections = connections
    self.localReader = localReader
    self.localWriter = localWriter
    self.remoteReader = { throw RepositoryRoutingError.unavailable($0.location.host) }
    self.remoteWriter = { context, _ in
      throw RepositoryRoutingError.unavailable(context.location.host)
    }
  }

  init(
    remoteReader: @escaping @Sendable (RepositoryContext) throws -> VCSProviding,
    remoteWriter: @escaping @Sendable (RepositoryContext, VCSProviding) throws -> VCSWriting = {
      context, _ in throw RepositoryRoutingError.unavailable(context.location.host)
    }
  ) {
    self.connections = nil
    self.localReader = nil
    self.localWriter = nil
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
    let context = try await context(for: location)
    if location.host != .local, let connections {
      return try await connections.reader(context: context)
    }
    if location.host == .local, let localReader {
      do {
        return try await localReader(context)
      } catch VCSError.backendVersion(_) {
        // A still-running pre-upgrade agent (kept alive because it may own terminals) has no VCS
        // service at all — never replaced, so this is not transient. Serve the read natively
        // rather than leaving every local repository unavailable until the user restarts it.
        return try reader(context: context)
      }
    }
    return try reader(context: context)
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
    if location.host != .local, let connections {
      return try await connections.writer(context: context)
    }
    let reader: VCSProviding
    if location.host == .local, let localReader {
      do {
        reader = try await localReader(context)
      } catch VCSError.backendVersion(_) {
        // See the matching fallback in `reader(for:)`: a pre-upgrade agent with no VCS service.
        reader = try self.reader(context: context)
      }
    } else {
      reader = try self.reader(context: context)
    }
    guard location.host == .local else { return try remoteWriter(context, reader) }
    // Local writes route through the same agent connection reads already use — mirroring
    // `reader(for:)` above — and fall back to a native `CLIVCSWriter` only when the agent predates
    // the write service (`VCSError.backendVersion`, from `AgentVCSConnection.writer`'s capability
    // check). The fallback only ever fires before any write is attempted, never mid-operation:
    // obtaining a writer here does not execute anything.
    if let localWriter {
      do {
        return try await localWriter(context)
      } catch VCSError.backendVersion(_) {}
    }
    let provider: LocalVCSProviding = context.backend == .jj ? RustJJProvider() : GitProvider()
    let writer = CLIVCSWriter(
      vcs: context.backend.rawValue, runner: StatusCommandRunner(),
      makeProvider: { _ in provider }, gate: .shared)
    return try BoundLocalWriter(context: context, reader: reader, writer: writer)
  }
}
