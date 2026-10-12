import Foundation

/// How a host-side read treats symbolic links. The raw values are the wire's `symlinks` field.
public enum FileSymlinkPolicy: String, Sendable {
  /// The file viewer: follow links, but only to a target inside the root.
  case followWithinRoot = "follow_within_root"
  /// Diff highlighting: a leaf link's diff is its target's PATH TEXT, so it is refused outright.
  case refuse
}

/// Why a file-service call failed, typed so a caller can tell "too large" from "refused" from "gone".
public enum FileServiceError: Error, Equatable, Sendable, LocalizedError {
  /// Containment refused it: a path escaping the root, a link under `.refuse`, or not a regular file.
  case refused(String)
  case tooLarge
  case notFound(String)
  /// The listing exceeded the 4 MiB capture cap. Never surfaced as a shortened list.
  case listingTruncated
  case failed(String)

  public var errorDescription: String? {
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
public enum FileWatchEvent: Equatable, Sendable {
  /// `overflow` means some changes are not listed (a cap was hit, or the OS lost track): treat the
  /// batch as relevant to every filter.
  case changed(paths: [String], overflow: Bool)
  /// The watched root went away or the watcher failed; the subscription is over.
  case ended(reason: String)
  /// The connection ended. The subscription is gone and the state behind it may be stale.
  case lost
}

public struct FileWatchHandle: Sendable {
  /// Stops the subscription. Idempotent, and safe after the connection is gone.
  public let cancel: @Sendable () async -> Void

  public init(cancel: @escaping @Sendable () async -> Void) {
    self.cancel = cancel
  }
}
