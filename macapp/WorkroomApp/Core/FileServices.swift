import Darwin
import Foundation

/// Which host holds the files, and — when the repository is registered — where its shared
/// repository lives (the jj working-copy lock is keyed by it). Deliberately NOT a
/// `RepositoryContext`: that type carries a backend, and file listing must not depend on one. A
/// colocated jj repository lists through immutable git first, exactly as it always has, so the
/// backend is chosen per call by the caller's git-then-jj loop rather than fixed by registration.
struct FileContext: Hashable, Sendable {
  let location: RepositoryLocation
  let sharedLocation: RepositoryLocation?
}

/// How a host-side read treats symbolic links. The raw values are the wire's `symlinks` field.
enum FileSymlinkPolicy: String, Sendable {
  /// The file viewer: follow links, but only to a target inside the root.
  case followWithinRoot = "follow_within_root"
  /// Diff highlighting: a leaf link's diff is its target's PATH TEXT, so it is refused outright.
  case refuse
}

/// Why a file-service call failed, typed so a caller can tell "too large" from "refused" from "gone".
enum FileServiceError: Error, Equatable, Sendable, LocalizedError {
  /// Containment refused it: a path escaping the root, a link under `.refuse`, or not a regular file.
  case refused(String)
  case tooLarge
  case notFound(String)
  /// The listing exceeded the 4 MiB capture cap. Never surfaced as a shortened list.
  case listingTruncated
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .refused(let detail): return "File access refused: \(detail)"
    case .tooLarge: return "File too large."
    case .notFound(let detail): return "File not found: \(detail)"
    case .listingTruncated: return "Too many files to list."
    case .failed(let detail): return detail
    }
  }
}

/// What a watch subscription reports. `.lost` is synthesized locally when the connection carrying the
/// subscription dies; the agent sends the other two.
enum FileWatchEvent: Equatable, Sendable {
  /// `overflow` means some changes are not listed (a cap was hit, or the OS lost track): treat the
  /// batch as relevant to every filter.
  case changed(paths: [String], overflow: Bool)
  /// The watched root went away or the watcher failed; the subscription is over.
  case ended(reason: String)
  /// The connection ended. The subscription is gone and the state behind it may be stale.
  case lost
}

struct FileWatchHandle: Sendable {
  /// Stops the subscription. Idempotent, and safe after the connection is gone.
  let cancel: @Sendable () async -> Void
}

/// Listing, raw reads and change notification for one repository's files, on whichever host holds
/// them. The seam beside `VCSProviding`: native on this machine when no agent serves the request,
/// wr-agent otherwise.
protocol FileProviding: Sendable {
  var context: FileContext { get }

  /// One raw listing command's result, exactly as the native runner would return it. Parsing stays
  /// in `FileListing.parse`, the only parser, so both paths agree on what a listing means.
  /// Throws `.listingTruncated` rather than returning a cut-off list.
  func list(_ vcs: FileListVCS) async throws -> CommandResult

  /// The file's bytes, verified on the host that holds them. `path` is repository-relative.
  /// `maxBytes` is a ceiling the READ enforces (`.tooLarge`), not a hint.
  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data

  /// Subscribe to changes under `root`. `nil` means this provider cannot watch — the native one —
  /// and the caller uses local FSEvents instead.
  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
}

/// The local, in-process implementation: what every file operation was before the agent, and what a
/// local host still uses when its running agent predates the File service.
struct NativeFileProvider: FileProviding {
  let context: FileContext
  var runner: StatusCommandRunning = StatusCommandRunner()
  var gate: JJSnapshotGate = .shared

  func list(_ vcs: FileListVCS) async throws -> CommandResult {
    let command = FileListing.command(vcs)
    let path = context.location.path
    let result: CommandResult
    if vcs == .jj {
      // The client holds the working-copy lock here, as it always has: jj's listing snapshots `@`,
      // and this is the native path, where nothing on the other side holds it for us.
      guard let shared = context.sharedLocation else {
        throw RepositoryRoutingError.registrationRequired
      }
      result =
        (try? await gate.run(repository: shared) {
          await runner.run(
            command.executable, command.args, in: path, timeout: FileListing.timeout)
        }) ?? CommandResult(stdout: "", stderr: "", exitCode: 1, timedOut: false)
    } else {
      result = await runner.run(
        command.executable, command.args, in: path, timeout: FileListing.timeout)
    }
    if result.stdoutTruncated { throw FileServiceError.listingTruncated }
    return result
  }

  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
    let root = context.location.path
    return try await runBlocking {
      try Self.readVerified(root: root, relative: path, symlinks: symlinks, maxBytes: maxBytes)
    }
  }

  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
  { nil }

  /// Read one regular file under `root`, verifying the DESCRIPTOR rather than the path.
  ///
  /// The wr-agent's `read_file` does the same thing on its side and this must stay in step with it:
  /// `AgentFileIntegrationTests.assertContainmentMatrix` runs one matrix against both. Checking a path
  /// and then opening it
  /// leaves a window where the path is swapped for a link out of the root, and a plain open of a FIFO
  /// blocks forever — the two things the old client-side `isContained`/`readWorkingFile` could not
  /// prevent. So: open first and non-blocking, then ask the kernel what was opened.
  static func readVerified(
    root: String, relative: String, symlinks: FileSymlinkPolicy, maxBytes: Int
  ) throws -> Data {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
      !relative.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == "." || $0 == ".." })
    else { throw FileServiceError.failed("Invalid relative file path.") }
    guard let realRoot = realPath(root) else { throw FileServiceError.notFound(root) }

    // `O_NOCTTY`: a committed link can point at a tty, and opening one without it can make it this
    // process's controlling terminal. The descriptor check refuses it afterwards, but the open has
    // already happened.
    var flags = O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
    if symlinks == .refuse { flags |= O_NOFOLLOW }
    let descriptor = open((root as NSString).appendingPathComponent(relative), flags)
    guard descriptor >= 0 else {
      switch errno {
      case ELOOP where symlinks == .refuse: throw FileServiceError.refused("symbolic link")
      case ENOENT, ENOTDIR: throw FileServiceError.notFound(relative)
      default: throw FileServiceError.failed(String(cString: strerror(errno)))
      }
    }
    defer { close(descriptor) }

    // What the kernel says this descriptor IS, not what the string we opened resolves to now.
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else {
      throw FileServiceError.failed(String(cString: strerror(errno)))
    }
    let real = String(cString: buffer)
    // Compared by path COMPONENT, so `/a/bc` is not inside `/a/b`.
    let rootComponents = URL(fileURLWithPath: realRoot).pathComponents
    let components = URL(fileURLWithPath: real).pathComponents
    guard components.count >= rootComponents.count,
      Array(components.prefix(rootComponents.count)) == rootComponents
    else { throw FileServiceError.refused("outside the repository root") }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw FileServiceError.failed(String(cString: strerror(errno)))
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw FileServiceError.refused("not a regular file")
    }
    guard info.st_size <= maxBytes else { throw FileServiceError.tooLarge }

    // Bounded regardless of the size just checked: a file that grows between the check and the read
    // still cannot exceed `maxBytes`.
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw FileServiceError.failed(String(cString: strerror(errno))) }
      if count == 0 { break }
      data.append(contentsOf: chunk.prefix(count))
      if data.count > maxBytes { throw FileServiceError.tooLarge }
    }
    return data
  }

  /// `realpath(3)`. Not `URL.resolvingSymlinksInPath`, which strips a leading `/private` and so
  /// disagrees with the form `F_GETPATH` reports (`/private/var/...`).
  private static func realPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

/// What a LOCAL host uses for files when its agent is in play: the agent first, this process second.
///
/// A local file is readable without any agent, so an agent that is missing, dead, hung or too old must
/// cost the caller performance and coalescing, never the file. Listing and reading are idempotent, so
/// when the agent fails at the TRANSPORT level (`HostConnectionError`: connection lost, request timed
/// out, budget exhausted, generation replaced, undecodable reply) the same request is simply run
/// natively. Nothing else falls back:
/// - a semantic answer from a healthy agent (`.refused`, `.tooLarge`, `.notFound`, a truncated
///   listing, a registration or lock error) is the answer, and the native path would give the same;
/// - cancellation propagates, since retrying work its caller abandoned helps nobody.
///
/// Never used for a remote host: there is no native path to fall back to, and unavailability is an
/// explicit failure. `watch` is not retried natively here — the caller (`HostFileWatcher`) owns that
/// decision because it has to keep trying the agent afterwards.
struct LocalFallbackFileProvider: FileProviding {
  let primary: FileProviding
  let fallback: FileProviding
  var context: FileContext { primary.context }

  func list(_ vcs: FileListVCS) async throws -> CommandResult {
    do {
      return try await primary.list(vcs)
    } catch is HostConnectionError {
      return try await fallback.list(vcs)
    }
  }

  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
    do {
      return try await primary.read(path: path, symlinks: symlinks, maxBytes: maxBytes)
    } catch is HostConnectionError {
      return try await fallback.read(path: path, symlinks: symlinks, maxBytes: maxBytes)
    }
  }

  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
  { try await primary.watch(root: root, onEvent: onEvent) }
}

/// Stands in for an agent that could not be obtained at all. Every call throws the same transport-level
/// error, so a `LocalFallbackFileProvider` around it runs listing and reading natively while `watch`
/// throws — which is what tells `HostFileWatcher` to watch locally for now and keep retrying the agent,
/// where a bare `NativeFileProvider` (whose `watch` is `nil`) would read as "this host never can" and
/// stop trying.
struct UnavailableFileProvider: FileProviding {
  let context: FileContext
  let reason: String

  private var failure: HostConnectionError { .serviceUnavailable(reason) }

  func list(_ vcs: FileListVCS) async throws -> CommandResult { throw failure }
  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
    throw failure
  }
  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
  { throw failure }
}

/// Retains the connection generation that produced the service, like `HostRepositoryReader`: a call
/// on a lease the manager has since invalidated fails rather than running against a replaced
/// connection. Reacquiring is an explicit caller decision, never a retry.
struct HostFileProvider: FileProviding {
  let context: FileContext
  let service: FileProviding
  let manager: HostConnectionManager
  let lease: HostConnectionManager.Lease

  func list(_ vcs: FileListVCS) async throws -> CommandResult {
    try await manager.perform(on: lease) { try await service.list(vcs) }
  }
  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
    try await manager.perform(on: lease) {
      try await service.read(path: path, symlinks: symlinks, maxBytes: maxBytes)
    }
  }
  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
  {
    try await manager.perform(on: lease) {
      let handle = try await service.watch(root: root, onEvent: onEvent)
      // `perform` discards a result that arrives after its caller was cancelled or its lease ended,
      // and this operation's own task is cancelled in exactly those cases. A subscription created
      // just before that is an agent-side watcher nobody holds a handle to, so it is unsubscribed
      // here, where the handle still exists.
      if Task.isCancelled, let handle {
        await handle.cancel()
        throw CancellationError()
      }
      return handle
    }
  }
}
