import Foundation

/// `Service::File` (`0x03`) on a wr-agent connection. Everything here is the wire contract of
/// `vcs/crates/wr-agent/src/file.rs` and `watch.rs`; the two are kept in step by
/// `AgentFileIntegrationTests`, which drives the real agent binary.
struct AgentFileProvider: FileProviding {
  let context: FileContext
  let connection: AgentVCSConnection

  func list(_ vcs: FileListVCS) async throws -> CommandResult {
    // The lock the jj listing takes lives in the SHARED repository, so an unregistered jj listing is
    // refused here, before a byte is sent — the same answer the native path gives.
    let backend: String
    switch vcs {
    case .git: backend = "git"
    case .jj:
      guard context.sharedLocation != nil else { throw RepositoryRoutingError.registrationRequired }
      backend = "jj"
    }
    let request = AgentFileRequest(
      method: "list", backend: backend, root: context.location.path,
      sharedRoot: context.sharedLocation?.path)
    let listing = try AgentFileReply<AgentFileListing>.decode(
      await connection.fileRequest(request))
    return CommandResult(
      stdout: listing.stdout, stderr: listing.stderr, exitCode: listing.exitCode,
      timedOut: listing.timedOut, signaled: listing.signaled)
  }

  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
    let request = AgentFileRequest(
      method: "read", root: context.location.path, path: path, symlinks: symlinks.rawValue,
      maxBytes: maxBytes)
    let file = try AgentFileReply<AgentFileContent>.decode(await connection.fileRequest(request))
    guard let data = Data(base64Encoded: file.content), data.count == file.size else {
      throw FileServiceError.failed("Malformed file reply.")
    }
    return data
  }

  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
  { try await connection.watch(root: root, onEvent: onEvent) }
}

struct AgentFileRequest: Encodable, Sendable {
  var version = 1
  let method: String
  var backend: String?
  var root: String?
  var sharedRoot: String?
  var path: String?
  var symlinks: String?
  var maxBytes: Int?
  var subscription: UInt64?
}

struct AgentFileCapabilities: Decodable {
  let version: Int
  let maxReadBytes: Int
  let maxSubscriptions: Int
}

private struct AgentFileListing: Decodable {
  let stdout: String
  let stderr: String
  let exitCode: Int32
  let timedOut: Bool
  let signaled: Bool
}

private struct AgentFileContent: Decodable {
  let size: Int
  let content: String
}

struct AgentFileSubscription: Decodable {
  let subscription: UInt64
}

/// An unsolicited frame from the agent: File service, stream 0.
struct AgentFileEvent: Decodable {
  let event: String
  let subscription: UInt64
  var paths: [String]?
  var overflow: Bool?
  var reason: String?

  /// Unknown event kinds are dropped rather than treated as errors, so a newer agent can add one
  /// without failing the connection of an older client.
  var model: FileWatchEvent? {
    switch event {
    case "changed": return .changed(paths: paths ?? [], overflow: overflow ?? false)
    case "ended": return .ended(reason: reason ?? "")
    default: return nil
    }
  }
}

/// The reply envelope, decoded like `AgentVCSReply` but with `FileError`'s own tags. Every failure is
/// `{"Tag": "message"}`.
struct AgentFileReply<T: Decodable>: Decodable {
  let result: T
  enum CodingKeys: CodingKey { case version, result, error }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == 1 else {
      throw HostConnectionError.serviceUnavailable("Unsupported file response version.")
    }
    if values.contains(.error) {
      let failure = try values.decode([String: String].self, forKey: .error)
      guard failure.count == 1, let (kind, message) = failure.first else {
        throw HostConnectionError.serviceUnavailable("Malformed agent failure.")
      }
      switch kind {
      case "Refused": throw FileServiceError.refused(message)
      case "TooLarge": throw FileServiceError.tooLarge
      case "NotFound": throw FileServiceError.notFound(message)
      case "ListingTruncated": throw FileServiceError.listingTruncated
      case "LockContention": throw VCSError.lockContention
      case "Registration": throw RepositoryRoutingError.registrationRequired
      case "Unsupported", "Io", "Busy": throw FileServiceError.failed(message)
      default: throw HostConnectionError.serviceUnavailable("Unknown agent failure: \(kind)")
      }
    }
    result = try values.decode(T.self, forKey: .result)
  }

  static func decode(_ data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    // Only a genuinely undecodable reply is wrapped. The typed failures `init(from:)` throws
    // (`FileServiceError`, `VCSError`, `RepositoryRoutingError`, `HostConnectionError`) propagate
    // unchanged, so a new one needs no edit here.
    do {
      return try decoder.decode(Self.self, from: data).result
    } catch let error as DecodingError {
      throw HostConnectionError.serviceUnavailable("Invalid file response: \(error)")
    }
  }
}
