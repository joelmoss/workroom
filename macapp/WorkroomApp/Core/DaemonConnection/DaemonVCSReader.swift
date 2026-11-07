import DaemonConnection
import Foundation
import WorkroomVCS

struct DaemonVCSReader: VCSProviding {
  let context: RepositoryContext
  let connection: DaemonClient

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
