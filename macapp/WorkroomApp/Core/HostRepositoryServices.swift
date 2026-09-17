import Foundation

/// Services retain both the router's metadata and the connection generation that produced them.
/// Reacquiring a service after reconnect is an explicit caller decision, never an operation retry.
struct HostRepositoryReader: VCSProviding {
  let context: RepositoryContext
  let service: VCSProviding
  let manager: HostConnectionManager
  let lease: HostConnectionManager.Lease

  func log(limit: Int) async throws -> VCSHistoryPage {
    try await manager.perform(on: lease) { try await service.log(limit: limit) }
  }
  func changeset(commitID: String) async throws -> VCSChangeset {
    try await manager.perform(on: lease) { try await service.changeset(commitID: commitID) }
  }
  func fileDiff(commitID: String, path: String) async throws -> String {
    try await manager.perform(on: lease) {
      try await service.fileDiff(commitID: commitID, path: path)
    }
  }
  func workingFileDiff(path: String, base: VCSWorkingDiffBase) async throws -> String {
    try await manager.perform(on: lease) {
      try await service.workingFileDiff(path: path, base: base)
    }
  }
  func fileContent(rev: String, path: String) async throws -> String? {
    try await manager.perform(on: lease) { try await service.fileContent(rev: rev, path: path) }
  }
  func commitParentFileContent(commitID: String, path: String) async throws -> String? {
    try await manager.perform(on: lease) {
      try await service.commitParentFileContent(commitID: commitID, path: path)
    }
  }
  func workingBaseFileContent(base: VCSWorkingDiffBase, path: String) async throws -> String? {
    try await manager.perform(on: lease) {
      try await service.workingBaseFileContent(base: base, path: path)
    }
  }
  func workingStatus() async throws -> WorkroomStatus {
    try await manager.perform(on: lease) { try await service.workingStatus() }
  }
  func currentRef() async throws -> VCSRef {
    try await manager.perform(on: lease) { try await service.currentRef() }
  }
}

struct HostRepositoryWriter: VCSWriting {
  let context: RepositoryContext
  let reader: VCSProviding
  let service: VCSWriting
  let manager: HostConnectionManager
  let lease: HostConnectionManager.Lease

  func remoteState() async -> VCSRemoteResolution {
    do { return try await manager.perform(on: lease) { await service.remoteState() } } catch {
      return .failed(.other(error.localizedDescription))
    }
  }
  func fetch(remote: String) async -> VCSRemoteActionResult {
    await action { await service.fetch(remote: remote) }
  }
  func push(current: VCSRef, remote: String, setUpstream: Bool, anonymousRevision: String) async
    -> VCSRemoteActionResult
  {
    await action {
      await service.push(
        current: current, remote: remote, setUpstream: setUpstream,
        anonymousRevision: anonymousRevision)
    }
  }
  func pullRebase(current: VCSRef, remote: String, tracking: VCSTracking?) async
    -> VCSRemoteActionResult
  {
    await action { await service.pullRebase(current: current, remote: remote, tracking: tracking) }
  }
  func abortRebase() async -> VCSRemoteActionResult {
    await action { await service.abortRebase() }
  }
  func commit(request: VCSCommitRequest) async -> VCSCommitResult {
    do {
      return try await manager.perform(on: lease) { await service.commit(request: request) }
    } catch { return .failed(.other(writeFailureDetail(error))) }
  }
  func stagedContentAtRisk(files: [ChangedFile]) async throws -> [String] {
    try await manager.perform(on: lease) { try await service.stagedContentAtRisk(files: files) }
  }
  func commitPreflight() async throws -> VCSCommitPreflight {
    try await manager.perform(on: lease) { try await service.commitPreflight() }
  }

  private func action(
    _ operation: @escaping @Sendable () async -> VCSRemoteActionResult
  ) async -> VCSRemoteActionResult {
    do { return try await manager.perform(on: lease, operation: operation) } catch {
      return .failed(.other(writeFailureDetail(error)))
    }
  }

  private func writeFailureDetail(_ error: Error) -> String {
    if error is CancellationError {
      return
        "Stopped waiting for the host. The operation may have completed; refresh before retrying."
    }
    return error.localizedDescription
  }
}
