import Foundation

/// Services are bound to one routing snapshot; callers cannot substitute a path or backend.
protocol VCSProviding: Sendable {
  var context: RepositoryContext { get }
  func log(limit: Int) async throws -> VCSHistoryPage
  func changeset(commitID: String) async throws -> VCSChangeset
  func fileDiff(commitID: String, path: String) async throws -> String
  func workingFileDiff(path: String, base: VCSWorkingDiffBase) async throws -> String
  func fileContent(rev: String, path: String) async throws -> String?
  func commitParentFileContent(commitID: String, path: String) async throws -> String?
  func workingBaseFileContent(base: VCSWorkingDiffBase, path: String) async throws -> String?
  func workingStatus() async throws -> WorkroomStatus
  func currentRef() async throws -> VCSRef
}

protocol VCSWriting: Sendable {
  var context: RepositoryContext { get }
  var reader: VCSProviding { get }
  func remoteState() async -> VCSRemoteResolution
  func fetch(remote: String) async -> VCSRemoteActionResult
  func push(current: VCSRef, remote: String, setUpstream: Bool, anonymousRevision: String) async
    -> VCSRemoteActionResult
  func pullRebase(current: VCSRef, remote: String, tracking: VCSTracking?) async
    -> VCSRemoteActionResult
  func abortRebase() async -> VCSRemoteActionResult
  func commit(request: VCSCommitRequest) async -> VCSCommitResult
  func stagedContentAtRisk(files: [ChangedFile]) async throws -> [String]
  func commitPreflight() async throws -> VCSCommitPreflight
}

/// Native engines remain local implementation details. All blocking work finishes before the
/// awaited operation returns, including when its caller has cancelled or stopped waiting.
struct BoundLocalReader: VCSProviding {
  let context: RepositoryContext
  let provider: LocalVCSProviding
  var gate: JJSnapshotGate = .shared

  private var root: URL { get throws { try context.location.requireLocalURL() } }

  func log(limit: Int) async throws -> VCSHistoryPage {
    let root = try root
    return try await runBlocking { try provider.log(root: root, limit: limit) }
  }
  func changeset(commitID: String) async throws -> VCSChangeset {
    try await provider.changeset(root: root, commitID: commitID)
  }
  func fileDiff(commitID: String, path: String) async throws -> String {
    try await provider.fileDiff(root: root, commitID: commitID, path: path)
  }
  func workingFileDiff(path: String, base: VCSWorkingDiffBase) async throws -> String {
    let root = try root
    if context.backend == .jj, base == .workingCopy {
      let shared = try context.requireOwnership()
      return try await gate.run(repository: shared) {
        try await provider.workingFileDiff(root: root, path: path, base: base)
      }
    }
    return try await provider.workingFileDiff(root: root, path: path, base: base)
  }
  func fileContent(rev: String, path: String) async throws -> String? {
    try await provider.fileContent(root: root, rev: rev, path: path)
  }
  func commitParentFileContent(commitID: String, path: String) async throws -> String? {
    try await provider.commitParentFileContent(root: root, commitID: commitID, path: path)
  }
  func workingBaseFileContent(base: VCSWorkingDiffBase, path: String) async throws -> String? {
    try await provider.workingBaseFileContent(root: root, base: base, path: path)
  }
  func workingStatus() async throws -> WorkroomStatus {
    let root = try root
    if context.backend == .jj {
      let shared = try context.requireOwnership()
      return try await gate.run(repository: shared) {
        try await runBlocking { try provider.workingStatus(root: root) }
      }
    }
    return try await runBlocking { try provider.workingStatus(root: root) }
  }
  func currentRef() async throws -> VCSRef {
    try await provider.currentRef(root: root)
  }
}

struct BoundLocalWriter: VCSWriting {
  let context: RepositoryContext
  let reader: VCSProviding
  let writer: LocalVCSWriting

  private var path: String { context.location.path }
  private let projectRoot: String

  init(context: RepositoryContext, reader: VCSProviding, writer: LocalVCSWriting) throws {
    _ = try context.location.requireLocalURL()
    projectRoot = try context.requireOwnership().path
    self.context = context
    self.reader = reader
    self.writer = writer
  }

  func remoteState() async -> VCSRemoteResolution {
    await writer.remoteState(path: path, projectRoot: projectRoot)
  }
  func fetch(remote: String) async -> VCSRemoteActionResult {
    await writer.fetch(path: path, projectRoot: projectRoot, remote: remote)
  }
  func push(current: VCSRef, remote: String, setUpstream: Bool, anonymousRevision: String) async
    -> VCSRemoteActionResult
  {
    await writer.push(
      path: path, projectRoot: projectRoot, current: current, remote: remote,
      setUpstream: setUpstream, anonymousRevision: anonymousRevision)
  }
  func pullRebase(current: VCSRef, remote: String, tracking: VCSTracking?) async
    -> VCSRemoteActionResult
  {
    await writer.pullRebase(
      path: path, projectRoot: projectRoot, current: current, remote: remote,
      tracking: tracking)
  }
  func abortRebase() async -> VCSRemoteActionResult {
    await writer.abortRebase(path: path, projectRoot: projectRoot)
  }
  func commit(request: VCSCommitRequest) async -> VCSCommitResult {
    await writer.commit(path: path, projectRoot: projectRoot, request: request)
  }
  func stagedContentAtRisk(files: [ChangedFile]) async throws -> [String] {
    try await writer.stagedContentAtRisk(path: path, files: files)
  }
  func commitPreflight() async throws -> VCSCommitPreflight {
    try await writer.commitPreflight(path: path)
  }
}
