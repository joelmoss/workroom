import DaemonConnection
import Foundation
import WorkroomVCS

struct DaemonVCSReader: VCSProviding {
  let context: RepositoryContext
  let connection: DaemonVCSConnection

  private func read<T: Decodable & Sendable>(
    _ method: String, limit: Int? = nil, revision: String? = nil, path: String? = nil,
    base: String? = nil
  ) async throws -> T {
    let request = DaemonVCSRequest(
      root: context.location.path, sharedRoot: context.sharedLocation?.path,
      backend: "git", method: method, limit: limit, revision: revision,
      path: path, base: base)
    return try DaemonVCSReply<T>.decode(await connection.request(request))
  }

  func log(limit: Int) async throws -> VCSHistoryPage {
    let page: DaemonHistory = try await read("log", limit: max(0, limit))
    return VCSHistoryPage(
      commits: page.commits.map(\.model), reachedEnd: page.reachedEnd,
      pushScope: page.pushScope?.model)
  }
  func changeset(commitID: String) async throws -> VCSChangeset {
    let change: DaemonChangeset = try await read("changeset", revision: commitID)
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
    // ponytail: `base` is a jj-era wire field (#266). Every daemon reads a missing base as
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
    let ref: DaemonRef = try await read("current_ref")
    return VCSRef(name: ref.name, kind: ref.kind.model)
  }
  func workingStatus() async throws -> WorkroomStatus {
    let status: DaemonStatus = try await read("working_status")
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

// The daemon wire types below are internal, not private, so DaemonVCSProtocolTests can decode canned
// older-daemon replies through them: the decode contract is the thing under test.
enum DaemonChangeKind: String, Decodable, Sendable {
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
enum DaemonPushState: String, Decodable, Sendable {
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
// ponytail: `Ancestor` (and DaemonCommit's change-id/working-copy/root/divergence fields) are
// jj-era wire shape, still decoded so an older daemon's replies keep parsing. A git reader never
// sends `Ancestor`; read it as a branch. Prune once app/daemon skew no longer spans #266.
enum DaemonRefKind: String, Decodable, Sendable {
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
struct DaemonAuthor: Decodable, Sendable {
  let name: String
  let email: String
}
struct DaemonScope: Decodable, Sendable {
  let refName: String?
  let count: Int
  var model: VCSPushScope { VCSPushScope(refName: refName, count: count) }
}
struct DaemonCommit: Decodable, Sendable {
  let commitId: String
  let shortId: String
  let changeId: String?
  let summary: String
  let body: String
  let authors: [DaemonAuthor]
  let timestampMs: Int64
  let refs: [String]
  let parentIds: [String]
  let isWorkingCopy: Bool
  let isRoot: Bool
  let changeOffset: Int?
  let divergentSiblings: [DaemonCommit]
  let pushState: DaemonPushState
  var model: VCSCommit {
    VCSCommit(
      commitID: commitId, shortID: shortId, summary: summary, body: body,
      authors: authors.map { VCSAuthor(name: $0.name, email: $0.email) },
      timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
      refs: refs, parentIDs: parentIds, pushState: pushState.model)
  }
}
struct DaemonHistory: Decodable, Sendable {
  let commits: [DaemonCommit]
  let reachedEnd: Bool
  let pushScope: DaemonScope?
}
struct DaemonStats: Decodable, Sendable {
  let insertions: Int
  let deletions: Int
}
struct DaemonFile: Decodable, Sendable {
  let path: String
  let oldPath: String?
  let kind: DaemonChangeKind
  let lineStats: DaemonStats?
  var model: VCSChangedFile { VCSChangedFile(path: path, oldPath: oldPath, kind: kind.model) }
}
private struct DaemonChangeset: Decodable, Sendable {
  let commit: DaemonCommit
  let fullMessage: String
  let files: [DaemonFile]
  let isMerge: Bool
  let pushScope: DaemonScope?
}
struct DaemonRef: Decodable, Sendable {
  let name: String?
  let kind: DaemonRefKind
}
/// Required fields are validated here: an invalid reply cannot mean a clean checkout.
struct DaemonStatus: Decodable, Sendable {
  let conflicted: Bool
  let files: [DaemonFile]
  let untracked: [String]?
  let branchForCi: String?
}
