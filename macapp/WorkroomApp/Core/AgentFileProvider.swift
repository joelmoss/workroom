import AgentConnection
import Foundation
import WorkroomVCS

/// `Service::File` (`0x03`) on a wr-agent connection. Everything here is the wire contract of
/// `vcs/crates/wr-agent/src/file.rs` and `watch.rs`; the two are kept in step by
/// `AgentFileIntegrationTests`, which drives the real agent binary.
struct AgentFileProvider: FileProviding {
  /// What every agent with a File service answers a method it doesn't know with, as `Unsupported`
  /// (`file.rs`, unchanged since the service was added). It is how the app tells an agent that
  /// predates `resolve` (#327) from one that answered.
  static let unknownMethod = "unsupported file method"

  /// How the agent's answer begins when a `resolve` hit its deadline (#334): a walk through a link
  /// onto a hung mount. Every candidate of the same click resolves the same prefix, so the click
  /// stops there. `RESOLVE_TIMED_OUT` in `file.rs`, whose tests pin the prefix.
  static let resolveTimedOut = "resolving timed out"
  /// The agent timed out while opening and checking a file on a remote mount (#343).
  static let readOpenTimedOut = "opening file timed out"

  /// The agent's `Busy` answer to a `resolve` while too many earlier walks are still stuck (#334).
  /// A click ends on it as on a timeout: its other candidates could open through the same hung
  /// link. Pinned by the cap test in `file.rs`.
  static let resolveWalksBusy = "too many earlier resolves are still walking"

  /// A read refused because too many earlier opens are still stuck on mounts (#343).
  static let filesystemOperationsBusy = "too many earlier filesystem operations are still pending"

  let context: FileContext
  let connection: AgentVCSConnection

  func list() async throws -> CommandResult {
    let request = AgentFileRequest(
      method: "list", backend: "git", root: context.location.path,
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

  func resolve(path: String) async throws -> String {
    let request = AgentFileRequest(method: "resolve", root: context.location.path, path: path)
    return try AgentFileReply<AgentFileResolved>.decode(await connection.fileRequest(request)).path
  }

  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
  { try await connection.watch(root: root, onEvent: onEvent) }
}

private struct AgentFileListing: Decodable {
  let stdout: String
  let stderr: String
  let exitCode: Int32
  let timedOut: Bool
  let signaled: Bool
}

private struct AgentFileResolved: Decodable {
  let path: String
}

private struct AgentFileContent: Decodable {
  let size: Int
  let content: String
}
