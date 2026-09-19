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
    /// The GitHub repository this registration is a checkout of, when the registrant knows it. A
    /// local host leaves it nil (its identity comes from its own git remote); a remote host has no
    /// checkout on this Mac, so the identity is registered with it (issue #207).
    let github: GitHubRepository?

    init(
      backend: RepositoryBackend, sharedLocation: RepositoryLocation,
      github: GitHubRepository? = nil
    ) {
      self.backend = backend
      self.sharedLocation = sharedLocation
      self.github = github
    }
  }

  struct Registration: Sendable {
    let location: RepositoryLocation
    let entry: Entry
    let localSourcePath: String?

    init(
      location: RepositoryLocation, backend: RepositoryBackend,
      sharedLocation: RepositoryLocation, localSourcePath: String? = nil,
      github: GitHubRepository? = nil
    ) throws {
      guard location.host == sharedLocation.host else { throw RepositoryRoutingError.mixedHosts }
      self.location = location
      self.localSourcePath = localSourcePath
      self.entry = Entry(backend: backend, sharedLocation: sharedLocation, github: github)
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
      localWriter: { try await LocalAgentVCS.shared.writer(context: $0) },
      localFiles: { try await LocalAgentVCS.shared.files(context: $0) })
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
  /// nil in every test router that doesn't opt in: `files(for:)` then serves natively, as it did
  /// before the File service existed.
  private let localFiles: (@Sendable (FileContext) async throws -> FileProviding)?

  /// Production routers share app-wide host connections. Tests can retain native local providers
  /// or inject an isolated agent without starting a service against the user's session socket.
  init(
    connections: HostConnectionManager = .shared,
    localReader: (@Sendable (RepositoryContext) async throws -> VCSProviding)? = nil,
    localWriter: (@Sendable (RepositoryContext) async throws -> VCSWriting)? = nil,
    localFiles: (@Sendable (FileContext) async throws -> FileProviding)? = nil
  ) {
    self.connections = connections
    self.localReader = localReader
    self.localWriter = localWriter
    self.localFiles = localFiles
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
    self.localFiles = nil
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

  /// Listing, raw reads and change notification for `location`'s files.
  ///
  /// Registered or not: an unregistered repository lists and reads exactly as before, and only a jj
  /// listing needs the shared repository (`FileContext.sharedLocation`), which it reports itself.
  ///
  /// **A local host never loses its files to its agent.** A local file is readable without one, so when
  /// the agent cannot be obtained — missing from the bundle, failed to start, too old for the File
  /// service (`VCSError.backendVersion`; it is kept alive because it may own terminals, so that is not
  /// transient) — the answer is a provider that lists and reads natively (`UnavailableFileProvider`
  /// inside a `LocalFallbackFileProvider`), and when a working agent fails mid-request at the transport
  /// level, the same idempotent request is re-run natively. See `LocalFallbackFileProvider` for exactly
  /// which failures fall back. Only cancellation propagates.
  ///
  /// A REMOTE host has no native path: its unavailability is an explicit failure, never empty data.
  func files(
    for location: RepositoryLocation, runner: StatusCommandRunning = StatusCommandRunner(),
    gate: JJSnapshotGate = .shared
  ) async throws -> FileProviding {
    let context = FileContext(
      location: location, sharedLocation: entry(for: location)?.sharedLocation)
    guard location.host == .local else {
      guard let connections else { throw RepositoryRoutingError.unavailable(location.host) }
      return try await connections.files(context: context)
    }
    let native = NativeFileProvider(context: context, runner: runner, gate: gate)
    guard let localFiles else { return native }
    let agent: FileProviding
    do {
      agent = try await localFiles(context)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      agent = UnavailableFileProvider(context: context, reason: "\(error)")
    }
    return LocalFallbackFileProvider(primary: agent, fallback: native)
  }

  private func registeredEntry(for location: RepositoryLocation) throws -> Entry {
    guard let entry = entry(for: location) else {
      if location.host == .local { throw RepositoryRoutingError.registrationRequired }
      throw RepositoryRoutingError.unavailable(location.host)
    }
    return entry
  }

  func registeredContext(for location: RepositoryLocation) throws -> RepositoryContext {
    let entry = try registeredEntry(for: location)
    return try RepositoryContext(
      location: location, backend: entry.backend,
      sharedLocation: entry.sharedLocation)
  }

  /// GitHub status for a REGISTERED location, bound to the identity it was registered with. The one
  /// way to build a service from a registration: context and identity come from the same captured
  /// entry, so a caller (a PR write, a sweep) cannot end up with one and not the other.
  func registeredGitHub(
    for location: RepositoryLocation,
    resolver: WorkroomStatusResolver = WorkroomStatusResolver()
  ) throws -> RepositoryGitHub {
    try github(for: location, entry: registeredEntry(for: location), resolver: resolver)
  }

  private func github(
    for location: RepositoryLocation, entry: Entry, resolver: WorkroomStatusResolver
  ) throws -> RepositoryGitHub {
    try RepositoryGitHub(
      context: RepositoryContext(
        location: location, backend: entry.backend, sharedLocation: entry.sharedLocation),
      resolver: resolver, repository: entry.github)
  }

  /// A registered location goes through `registeredGitHub`; an unregistered LOCAL one is probed, so
  /// it can still be read (status only — a write needs a registration).
  func gitHub(
    for location: RepositoryLocation,
    resolver: WorkroomStatusResolver = WorkroomStatusResolver()
  ) async throws -> RepositoryGitHub {
    // ONE registry read: a registration cleared between two reads must fall through to the probe.
    if let entry = entry(for: location) {
      return try github(for: location, entry: entry, resolver: resolver)
    }
    return try RepositoryGitHub(context: await context(for: location), resolver: resolver)
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
