import Foundation

struct AgentVCSReader: VCSProviding {
  let context: RepositoryContext
  let connection: AgentVCSConnection

  private func read<T: Decodable & Sendable>(
    _ method: String, limit: Int? = nil, revision: String? = nil, path: String? = nil,
    base: VCSWorkingDiffBase? = nil
  ) async throws -> T {
    if context.backend == .jj,
      method == "working_status" || (method == "working_file_diff" && base == .workingCopy)
    {
      _ = try context.requireOwnership()
    }
    let request = AgentVCSRequest(
      root: context.location.path, sharedRoot: context.sharedLocation?.path,
      backend: context.backend.rawValue, method: method, limit: limit, revision: revision,
      path: path, base: base.map { $0 == .workingCopy ? "working_copy" : "parent" })
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
  func workingFileDiff(path: String, base: VCSWorkingDiffBase) async throws -> String {
    try await read("working_file_diff", path: path, base: base)
  }
  func fileContent(rev: String, path: String) async throws -> String? {
    try await read("file_content", revision: rev, path: path)
  }
  func commitParentFileContent(commitID: String, path: String) async throws -> String? {
    try await read("commit_parent_file_content", revision: commitID, path: path)
  }
  func workingBaseFileContent(base: VCSWorkingDiffBase, path: String) async throws -> String? {
    try await read("working_base_file_content", path: path, base: base)
  }
  func currentRef() async throws -> VCSRef {
    let ref: AgentRef = try await read("current_ref")
    return VCSRef(name: ref.name, kind: ref.kind.model)
  }
  func workingStatus() async throws -> WorkroomStatus {
    let status: AgentStatus = try await read("working_status")
    let files = status.files ?? status.workingCopy?.files ?? []
    let untracked = status.untracked.map(Set.init)
    let changed = files.map {
      ChangedFile(
        path: $0.path,
        change: untracked?.contains($0.path) == true ? .untracked : $0.kind.status,
        oldPath: $0.oldPath)
    }
    // Required fields are validated by the DTO: an invalid reply cannot mean a clean checkout.
    return WorkroomStatus(
      dirty: !changed.isEmpty || status.conflicted, conflicted: status.conflicted,
      changedFiles: changed,
      insertions: files.reduce(0) { $0 + ($1.lineStats?.insertions ?? 0) },
      deletions: files.reduce(0) { $0 + ($1.lineStats?.deletions ?? 0) },
      branchForCI: status.branchForCi,
      jjWorkingCopy: status.workingCopy.map {
        JJCommitChanges(
          changeID: $0.changeId, commitID: $0.commitId, refs: $0.refs,
          description: $0.description, files: changed)
      })
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

private enum AgentChangeKind: String, Decodable, Sendable {
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
private enum AgentPushState: String, Decodable, Sendable {
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
private enum AgentRefKind: String, Decodable, Sendable {
  case branch = "Branch"
  case ancestor = "Ancestor"
  case detached = "Detached"
  case none = "None"
  var model: VCSRefKind {
    switch self {
    case .branch: .branch
    case .ancestor: .ancestor
    case .detached: .detached
    case .none: .none
    }
  }
}
private struct AgentAuthor: Decodable, Sendable {
  let name: String
  let email: String
}
private struct AgentScope: Decodable, Sendable {
  let refName: String?
  let count: Int
  var model: VCSPushScope { VCSPushScope(refName: refName, count: count) }
}
private struct AgentCommit: Decodable, Sendable {
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
      commitID: commitId, shortID: shortId, changeID: changeId, summary: summary, body: body,
      authors: authors.map { VCSAuthor(name: $0.name, email: $0.email) },
      timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
      refs: refs, parentIDs: parentIds, isWorkingCopy: isWorkingCopy,
      changeOffset: changeOffset, divergentSiblings: divergentSiblings.map(\.model),
      pushState: pushState.model, isRoot: isRoot)
  }
}
private struct AgentHistory: Decodable, Sendable {
  let commits: [AgentCommit]
  let reachedEnd: Bool
  let pushScope: AgentScope?
}
private struct AgentStats: Decodable, Sendable {
  let insertions: Int
  let deletions: Int
}
private struct AgentFile: Decodable, Sendable {
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
private struct AgentRef: Decodable, Sendable {
  let name: String?
  let kind: AgentRefKind
}
private struct AgentWorkingCopy: Decodable, Sendable {
  let changeId: String?
  let commitId: String?
  let refs: [String]
  let description: String?
  let files: [AgentFile]
}
private struct AgentStatus: Decodable, Sendable {
  let conflicted: Bool
  let files: [AgentFile]?
  let untracked: [String]?
  let branchForCi: String?
  let workingCopy: AgentWorkingCopy?
  enum CodingKeys: CodingKey { case conflicted, files, untracked, branchForCi, workingCopy }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    conflicted = try values.decode(Bool.self, forKey: .conflicted)
    files = try values.decodeIfPresent([AgentFile].self, forKey: .files)
    untracked = try values.decodeIfPresent([String].self, forKey: .untracked)
    branchForCi = try values.decodeIfPresent(String.self, forKey: .branchForCi)
    workingCopy = try values.decodeIfPresent(AgentWorkingCopy.self, forKey: .workingCopy)
    guard (files != nil) != (workingCopy != nil) else {
      throw HostConnectionError.serviceUnavailable(
        "Agent status must contain exactly one backend's changed files.")
    }
  }
}
