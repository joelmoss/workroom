import Foundation

/// Services are bound to one routing snapshot; callers cannot substitute a path or backend.
public protocol VCSProviding: Sendable {
  var context: RepositoryContext { get }
  func log(limit: Int) async throws -> VCSHistoryPage
  func changeset(commitID: String) async throws -> VCSChangeset
  func fileDiff(commitID: String, path: String) async throws -> String
  func workingFileDiff(path: String) async throws -> String
  func fileContent(rev: String, path: String) async throws -> String?
  func commitParentFileContent(commitID: String, path: String) async throws -> String?
  func workingBaseFileContent(path: String) async throws -> String?
  func workingStatus() async throws -> WorkroomStatus
  func currentRef() async throws -> VCSRef
}

public protocol VCSWriting: Sendable {
  var context: RepositoryContext { get }
  var reader: VCSProviding { get }
  func remoteState() async -> VCSRemoteResolution
  func fetch(remote: String) async -> VCSRemoteActionResult
  func push(current: VCSRef, remote: String, setUpstream: Bool) async -> VCSRemoteActionResult
  func pullRebase(current: VCSRef, remote: String, tracking: VCSTracking?) async
    -> VCSRemoteActionResult
  func abortRebase() async -> VCSRemoteActionResult
  func commit(request: VCSCommitRequest) async -> VCSCommitResult
  func stagedContentAtRisk(files: [ChangedFile]) async throws -> [String]
  func commitPreflight() async throws -> VCSCommitPreflight
}
