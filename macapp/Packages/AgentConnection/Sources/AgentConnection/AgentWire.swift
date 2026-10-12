import Foundation
import WorkroomVCS

// The agent's wire types that the connection itself encodes or decodes. The services' own request
// and reply types stay with their adapters in the app.

public struct AgentFileRequest: Encodable, Sendable {
  public var version = 1
  public let method: String
  // ponytail: `backend` (always "git") and `shared_root` are jj-era wire fields (#266), still sent
  // for agents built before it. Prune once no supported agent predates #266.
  public var backend: String?
  public var root: String?
  public var sharedRoot: String?
  public var path: String?
  public var symlinks: String?
  public var maxBytes: Int?
  public var subscription: UInt64?

  public init(
    method: String, backend: String? = nil, root: String? = nil, sharedRoot: String? = nil,
    path: String? = nil, symlinks: String? = nil, maxBytes: Int? = nil, subscription: UInt64? = nil
  ) {
    self.method = method
    self.backend = backend
    self.root = root
    self.sharedRoot = sharedRoot
    self.path = path
    self.symlinks = symlinks
    self.maxBytes = maxBytes
    self.subscription = subscription
  }
}

public struct AgentFileCapabilities: Decodable {
  public let version: Int
  public let maxReadBytes: Int
  public let maxSubscriptions: Int

  public init(version: Int, maxReadBytes: Int, maxSubscriptions: Int) {
    self.version = version
    self.maxReadBytes = maxReadBytes
    self.maxSubscriptions = maxSubscriptions
  }
}

public struct AgentFileSubscription: Decodable {
  public let subscription: UInt64

  public init(subscription: UInt64) {
    self.subscription = subscription
  }
}

/// An unsolicited frame from the agent: File service, stream 0.
public struct AgentFileEvent: Decodable {
  public let event: String
  public let subscription: UInt64
  public var paths: [String]?
  public var overflow: Bool?
  public var reason: String?

  /// Unknown event kinds are dropped rather than treated as errors, so a newer agent can add one
  /// without failing the connection of an older client.
  public var model: FileWatchEvent? {
    switch event {
    case "changed": return .changed(paths: paths ?? [], overflow: overflow ?? false)
    case "ended": return .ended(reason: reason ?? "")
    default: return nil
    }
  }

  public init(
    event: String, subscription: UInt64, paths: [String]? = nil, overflow: Bool? = nil,
    reason: String? = nil
  ) {
    self.event = event
    self.subscription = subscription
    self.paths = paths
    self.overflow = overflow
    self.reason = reason
  }
}

/// The reply envelope, decoded like `AgentVCSReply` but with `FileError`'s own tags. Every failure is
/// `{"Tag": "message"}`.
public struct AgentFileReply<T: Decodable>: Decodable {
  public let result: T
  public enum CodingKeys: CodingKey { case version, result, error }
  public init(from decoder: Decoder) throws {
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
      case "Unsupported", "Io", "Busy": throw FileServiceError.failed(message)
      default: throw HostConnectionError.serviceUnavailable("Unknown agent failure: \(kind)")
      }
    }
    result = try values.decode(T.self, forKey: .result)
  }

  public static func decode(_ data: Data) throws -> T {
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

/// Deliberately separate from UI Codable: the versioned wire representation is its own contract.
public struct AgentVCSReply<T: Decodable>: Decodable {
  public let result: T
  public enum CodingKeys: CodingKey { case version, result, error }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == 1 else {
      throw HostConnectionError.serviceUnavailable("Unsupported VCS response version.")
    }
    if values.contains(.error) {
      if let name = try? values.decode(String.self, forKey: .error) {
        switch name {
        case "LockContention": throw VCSError.lockContention
        case "StaleSnapshot": throw VCSError.staleSnapshot
        default: throw HostConnectionError.serviceUnavailable("Unknown agent failure: \(name)")
        }
      }
      let failure = try values.decode([String: String].self, forKey: .error)
      guard failure.count == 1, let (kind, message) = failure.first else {
        throw HostConnectionError.serviceUnavailable("Malformed agent failure.")
      }
      switch kind {
      case "UnsupportedRepo": throw VCSError.unsupportedRepo(message)
      case "NotFound": throw VCSError.notFound(message)
      case "PartialData": throw VCSError.partialData(message)
      case "BackendVersion": throw VCSError.backendVersion(message)
      case "Io": throw VCSError.io(message)
      default: throw HostConnectionError.serviceUnavailable("Unknown agent failure: \(kind)")
      }
    }
    result = try values.decode(T.self, forKey: .result)
  }
  public static func decode(_ data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do { return try decoder.decode(Self.self, from: data).result } catch let error as VCSError {
      throw error
    } catch { throw HostConnectionError.serviceUnavailable("Invalid VCS response: \(error)") }
  }
}

/// The opcodes of `Service::Forward` (`0x05`), the wire contract of
/// `vcs/crates/wr-agent/src/forward.rs` (issue #208). The service itself is `AgentForwardService`,
/// in the app.
public enum ForwardOpcode {
  public static let open: UInt8 = 0x01
  public static let reply: UInt8 = 0x02
  public static let data: UInt8 = 0x03
  public static let eof: UInt8 = 0x04
  public static let close: UInt8 = 0x05
  /// On a listener's stream only (`ReverseForward`): one connection is waiting to be claimed.
  public static let accepted: UInt8 = 0x06
}
