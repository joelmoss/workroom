import Foundation
import WorkroomSystem

/// Which host holds the files, and — when the repository is registered — where its shared
/// repository lives (sent to workroomd as `shared_root`, which its File service still accepts).
/// Deliberately NOT a `RepositoryContext`: listing an unregistered directory must work too, and a
/// context only comes from a registration or a repository probe.
public struct FileContext: Hashable, Sendable {
  public let location: RepositoryLocation
  public let sharedLocation: RepositoryLocation?

  public init(location: RepositoryLocation, sharedLocation: RepositoryLocation?) {
    self.location = location
    self.sharedLocation = sharedLocation
  }
}

/// Listing, raw reads and change notification for one repository's files, on whichever host holds
/// them. The seam beside `VCSProviding`: native on this machine when no daemon serves the request,
/// workroomd otherwise.
public protocol FileProviding: Sendable {
  var context: FileContext { get }

  /// One raw listing command's result, exactly as the native runner would return it. Parsing stays
  /// in `FileListing.parse`, the only parser, so both paths agree on what a listing means.
  /// Throws `.listingTruncated` rather than returning a cut-off list.
  func list() async throws -> CommandResult

  /// The file's bytes, verified on the host that holds them. `path` is repository-relative.
  /// `maxBytes` is a ceiling the READ enforces (`.tooLarge`), not a hint.
  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data

  /// The repository-relative path `path` names once resolved on the host, through any symlink on
  /// the way (#327). `path` may hold `..`, but never one that climbs above the root as written.
  func resolve(path: String) async throws -> String

  /// Subscribe to changes under `root`. `nil` means this provider cannot watch — the native one —
  /// and the caller uses local FSEvents instead.
  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
}
