import Foundation
import WorkroomVCS

// The VCS service's wire types, request and reply side by side: what the connection's capabilities
// probe and the app's VCS adapters (`DaemonVCSReader`, `DaemonClient+Services`) send, and the
// shapes the daemon's `vcs.rs` answers with. Deliberately separate from the VCS models: the
// versioned wire is its own contract, and each reply type maps itself onto its model (`model`).

public struct DaemonVCSCapabilities: Decodable {
  public let version: Int
  public let reads: Int
  /// The exec service's wire version, or nil on a still-running pre-upgrade daemon that predates the
  /// service entirely.
  ///
  /// Replaces a `writes` COUNT, which counted methods on `LocalVCSWriting` — a protocol that exists
  /// only in this process. workroomd implements one generic exec service and never had eight write
  /// methods to report, so the number described nothing on the answering side and nothing could keep
  /// it true: adding a ninth method here, a change the passthrough fully supports, made the equality
  /// check below fail against a completely capable daemon and silently dropped every user to native
  /// writes with no log line.
  public let exec: Int?

  public init(version: Int, reads: Int, exec: Int?) {
    self.version = version
    self.reads = reads
    self.exec = exec
  }
}

/// `StatRequest` in `vcs.rs`, which rejects unknown fields.
public struct DaemonStatRequest: Encodable, Sendable {
  public var version = 1
  public var kind = "stat"
  public let paths: [String]
  public let read: [String]

  public init(paths: [String], read: [String]) {
    self.paths = paths
    self.read = read
  }
}

public struct DaemonStatReply: Decodable {
  public struct Entry: Decodable {
    public let path: String
    public let exists: Bool
    public let isDir: Bool
    public let modifiedAt: Double?
    public let text: String?

    public init(path: String, exists: Bool, isDir: Bool, modifiedAt: Double?, text: String?) {
      self.path = path
      self.exists = exists
      self.isDir = isDir
      self.modifiedAt = modifiedAt
      self.text = text
    }
  }
  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }
}

public struct DaemonVCSRequest: Encodable, Sendable {
  public var version = 1
  public var root: String?
  // ponytail: `shared_root` and `backend` are jj-era wire fields (#266). The daemon ignores the first
  // and still requires the second ("git") on every read. Prune both with a protocol bump once no
  // supported daemon predates #266.
  public var sharedRoot: String?
  public var backend: String?
  public let method: String
  public var limit: Int?
  public var revision: String?
  public var path: String?
  public var base: String?

  public init(
    root: String? = nil, sharedRoot: String? = nil, backend: String? = nil, method: String,
    limit: Int? = nil, revision: String? = nil, path: String? = nil, base: String? = nil
  ) {
    self.root = root
    self.sharedRoot = sharedRoot
    self.backend = backend
    self.method = method
    self.limit = limit
    self.revision = revision
    self.path = path
    self.base = base
  }
}

// The read replies, each decoded from a `DaemonVCSReply`'s `result`.

public enum DaemonChangeKind: String, Decodable, Sendable {
  case added = "Added"
  case modified = "Modified"
  case deleted = "Deleted"
  case renamed = "Renamed"
  case copied = "Copied"
  case conflicted = "Conflicted"
  case other = "Other"
  public var model: VCSChangeKind {
    switch self {
    case .added: .added
    case .modified: .modified
    case .deleted: .deleted
    case .renamed: .renamed
    case .copied: .copied
    case .conflicted: .conflicted
    case .other: .other
    }
  }
  public var status: ChangedFile.Change {
    switch self {
    case .added: .added
    case .modified: .modified
    case .deleted: .deleted
    case .renamed, .copied: .renamed
    case .conflicted: .conflicted
    case .other: .other
    }
  }
}
public enum DaemonPushState: String, Decodable, Sendable {
  case pushed = "Pushed"
  case unpushed = "Unpushed"
  case unknown = "Unknown"
  public var model: VCSPushState {
    switch self {
    case .pushed: .pushed
    case .unpushed: .unpushed
    case .unknown: .unknown
    }
  }
}
// `Ancestor` is jj-era wire shape: a daemon from before #266 can still send it, and an unknown
// case would fail the decode, so it stays and reads as a branch. A git reader never sends it.
// DaemonCommit declares no jj-era field: the decoder ignores the ones an older daemon still sends.
public enum DaemonRefKind: String, Decodable, Sendable {
  case branch = "Branch"
  case ancestor = "Ancestor"
  case detached = "Detached"
  case none = "None"
  public var model: VCSRefKind {
    switch self {
    case .branch, .ancestor: .branch
    case .detached: .detached
    case .none: .none
    }
  }
}
public struct DaemonAuthor: Decodable, Sendable {
  public let name: String
  public let email: String
}
public struct DaemonScope: Decodable, Sendable {
  public let refName: String?
  public let count: Int
  public var model: VCSPushScope { VCSPushScope(refName: refName, count: count) }
}
public struct DaemonCommit: Decodable, Sendable {
  public let commitId: String
  public let shortId: String
  public let summary: String
  public let body: String
  public let authors: [DaemonAuthor]
  public let timestampMs: Int64
  public let refs: [String]
  public let parentIds: [String]
  public let pushState: DaemonPushState
  public var model: VCSCommit {
    VCSCommit(
      commitID: commitId, shortID: shortId, summary: summary, body: body,
      authors: authors.map { VCSAuthor(name: $0.name, email: $0.email) },
      timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
      refs: refs, parentIDs: parentIds, pushState: pushState.model)
  }
}
public struct DaemonHistory: Decodable, Sendable {
  public let commits: [DaemonCommit]
  public let reachedEnd: Bool
  public let pushScope: DaemonScope?
}
public struct DaemonStats: Decodable, Sendable {
  public let insertions: Int
  public let deletions: Int
}
public struct DaemonFile: Decodable, Sendable {
  public let path: String
  public let oldPath: String?
  public let kind: DaemonChangeKind
  public let lineStats: DaemonStats?
  public var model: VCSChangedFile {
    VCSChangedFile(path: path, oldPath: oldPath, kind: kind.model)
  }
}
public struct DaemonChangeset: Decodable, Sendable {
  public let commit: DaemonCommit
  public let fullMessage: String
  public let files: [DaemonFile]
  public let isMerge: Bool
  public let pushScope: DaemonScope?
}
public struct DaemonRef: Decodable, Sendable {
  public let name: String?
  public let kind: DaemonRefKind
}
/// Required fields are validated here: an invalid reply cannot mean a clean checkout.
public struct DaemonStatus: Decodable, Sendable {
  public let conflicted: Bool
  public let files: [DaemonFile]
  public let untracked: [String]?
  public let branchForCi: String?
}
