import Foundation

struct AgentVCSReader: VCSProviding {
  let context: RepositoryContext
  let connection: AgentVCSConnection

  private func read<T: Decodable & Sendable>(
    _ method: String, limit: Int? = nil, revision: String? = nil, path: String? = nil,
    base: String? = nil
  ) async throws -> T {
    let request = AgentVCSRequest(
      root: context.location.path, sharedRoot: context.sharedLocation?.path,
      backend: "git", method: method, limit: limit, revision: revision,
      path: path, base: base)
    return try AgentVCSReply<T>.decode(await connection.request(request))
  }

  func log(limit: Int) async throws -> VCSHistoryPage {
    let page: AgentHistory = try await read("log", limit: max(0, limit))
    return VCSHistoryPage(
      commits: page.commits.map(\.model), reachedEnd: page.reachedEnd,
      pushScope: page.pushScope?.model)
  }
  func changeset(commitID: String) async throws -> VCSChangeset {
    let change: AgentChangeset = try await read("changeset", revision: commitID)
    return VCSChangeset(
      commit: change.commit.model, fullMessage: change.fullMessage,
      files: change.files.map(\.model), isMerge: change.isMerge,
      insertions: change.files.reduce(0) { $0 + ($1.lineStats?.insertions ?? 0) },
      deletions: change.files.reduce(0) { $0 + ($1.lineStats?.deletions ?? 0) },
      pushScope: change.pushScope?.model)
  }
  func fileDiff(commitID: String, path: String) async throws -> String {
    try await read("file_diff", revision: commitID, path: path)
  }
  func workingFileDiff(path: String) async throws -> String {
    // ponytail: `base` is a jj-era wire field (#266). Every agent reads a missing base as
    // "working_copy"; it is sent explicitly only until the protocol bump that drops `backend`.
    try await read("working_file_diff", path: path, base: "working_copy")
  }
  func fileContent(rev: String, path: String) async throws -> String? {
    try await read("file_content", revision: rev, path: path)
  }
  func commitParentFileContent(commitID: String, path: String) async throws -> String? {
    try await read("commit_parent_file_content", revision: commitID, path: path)
  }
  func workingBaseFileContent(path: String) async throws -> String? {
    try await read("working_base_file_content", path: path, base: "working_copy")
  }
  func currentRef() async throws -> VCSRef {
    let ref: AgentRef = try await read("current_ref")
    return VCSRef(name: ref.name, kind: ref.kind.model)
  }
  func workingStatus() async throws -> WorkroomStatus {
    let status: AgentStatus = try await read("working_status")
    let files = status.files
    let untracked = status.untracked.map(Set.init)
    let changed = files.map {
      ChangedFile(
        path: $0.path,
        change: untracked?.contains($0.path) == true ? .untracked : $0.kind.status,
        oldPath: $0.oldPath)
    }
    return WorkroomStatus(
      dirty: !changed.isEmpty || status.conflicted, conflicted: status.conflicted,
      changedFiles: changed,
      insertions: files.reduce(0) { $0 + ($1.lineStats?.insertions ?? 0) },
      deletions: files.reduce(0) { $0 + ($1.lineStats?.deletions ?? 0) },
      branchForCI: status.branchForCi)
  }
}

/// Deliberately separate from UI Codable: the versioned wire representation is its own contract.
struct AgentVCSReply<T: Decodable>: Decodable {
  let result: T
  enum CodingKeys: CodingKey { case version, result, error }
  init(from decoder: Decoder) throws {
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
  static func decode(_ data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do { return try decoder.decode(Self.self, from: data).result } catch let error as VCSError {
      throw error
    } catch { throw HostConnectionError.serviceUnavailable("Invalid VCS response: \(error)") }
  }
}

// The agent wire types below are internal, not private, so AgentVCSProtocolTests can decode canned
// older-agent replies through them: the decode contract is the thing under test.
enum AgentChangeKind: String, Decodable, Sendable {
  case added = "Added"
  case modified = "Modified"
  case deleted = "Deleted"
  case renamed = "Renamed"
  case copied = "Copied"
  case conflicted = "Conflicted"
  case other = "Other"
  var model: VCSChangeKind {
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
  var status: ChangedFile.Change {
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
enum AgentPushState: String, Decodable, Sendable {
  case pushed = "Pushed"
  case unpushed = "Unpushed"
  case unknown = "Unknown"
  var model: VCSPushState {
    switch self {
    case .pushed: .pushed
    case .unpushed: .unpushed
    case .unknown: .unknown
    }
  }
}
// ponytail: `Ancestor` (and AgentCommit's change-id/working-copy/root/divergence fields) are
// jj-era wire shape, still decoded so an older agent's replies keep parsing. A git reader never
// sends `Ancestor`; read it as a branch. Prune once app/agent skew no longer spans #266.
enum AgentRefKind: String, Decodable, Sendable {
  case branch = "Branch"
  case ancestor = "Ancestor"
  case detached = "Detached"
  case none = "None"
  var model: VCSRefKind {
    switch self {
    case .branch, .ancestor: .branch
    case .detached: .detached
    case .none: .none
    }
  }
}
struct AgentAuthor: Decodable, Sendable {
  let name: String
  let email: String
}
struct AgentScope: Decodable, Sendable {
  let refName: String?
  let count: Int
  var model: VCSPushScope { VCSPushScope(refName: refName, count: count) }
}
struct AgentCommit: Decodable, Sendable {
  let commitId: String
  let shortId: String
  let changeId: String?
  let summary: String
  let body: String
  let authors: [AgentAuthor]
  let timestampMs: Int64
  let refs: [String]
  let parentIds: [String]
  let isWorkingCopy: Bool
  let isRoot: Bool
  let changeOffset: Int?
  let divergentSiblings: [AgentCommit]
  let pushState: AgentPushState
  var model: VCSCommit {
    VCSCommit(
      commitID: commitId, shortID: shortId, summary: summary, body: body,
      authors: authors.map { VCSAuthor(name: $0.name, email: $0.email) },
      timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
      refs: refs, parentIDs: parentIds, pushState: pushState.model)
  }
}
struct AgentHistory: Decodable, Sendable {
  let commits: [AgentCommit]
  let reachedEnd: Bool
  let pushScope: AgentScope?
}
struct AgentStats: Decodable, Sendable {
  let insertions: Int
  let deletions: Int
}
struct AgentFile: Decodable, Sendable {
  let path: String
  let oldPath: String?
  let kind: AgentChangeKind
  let lineStats: AgentStats?
  var model: VCSChangedFile { VCSChangedFile(path: path, oldPath: oldPath, kind: kind.model) }
}
private struct AgentChangeset: Decodable, Sendable {
  let commit: AgentCommit
  let fullMessage: String
  let files: [AgentFile]
  let isMerge: Bool
  let pushScope: AgentScope?
}
struct AgentRef: Decodable, Sendable {
  let name: String?
  let kind: AgentRefKind
}
/// Required fields are validated here: an invalid reply cannot mean a clean checkout.
struct AgentStatus: Decodable, Sendable {
  let conflicted: Bool
  let files: [AgentFile]
  let untracked: [String]?
  let branchForCi: String?
}
