import Foundation
import Synchronization
import WorkroomDomain
import XCTest

@testable import Workroom

/// A fake CLI for unit-testing AppStore mutations without a real subprocess
/// (issue #103, the WorkroomCLIProtocol seam). Records add-project calls and lists
/// a controlled project set so post-add selection can be asserted.
final class FakeWorkroomCLI: WorkroomCLIProtocol {
  // Set by the test, read by the store's calls off the main actor.
  private struct State {
    var addProjectCalls: [(path: String, create: Bool)] = []
    var canonicalToReturn: String
    var projectsToList: [Project]
    var addProjectError: Error?
    var cloneCalls: [(url: String, path: String)] = []
    var cloneProgress: [String] = []
  }
  private let state: Mutex<State>

  var addProjectCalls: [(path: String, create: Bool)] { state.withLock { $0.addProjectCalls } }
  var canonicalToReturn: String {
    get { state.withLock { $0.canonicalToReturn } }
    set { state.withLock { $0.canonicalToReturn = newValue } }
  }
  var projectsToList: [Project] {
    get { state.withLock { $0.projectsToList } }
    set { state.withLock { $0.projectsToList = newValue } }
  }
  /// When set, `addProject` throws this instead of succeeding — for the `Result` failure case.
  var addProjectError: Error? {
    get { state.withLock { $0.addProjectError } }
    set { state.withLock { $0.addProjectError = newValue } }
  }

  var cloneCalls: [(url: String, path: String)] { state.withLock { $0.cloneCalls } }
  /// The lines `cloneProject` streams before it returns, as git's progress would arrive.
  var cloneProgress: [String] {
    get { state.withLock { $0.cloneProgress } }
    set { state.withLock { $0.cloneProgress = newValue } }
  }

  init(canonical: String, projects: [Project]) {
    state = Mutex(State(canonicalToReturn: canonical, projectsToList: projects))
  }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    ListResponse(projects: projectsToList, workroomsDir: nil, configPath: nil)
  }

  func addProject(_ path: String, create: Bool) async throws -> String {
    let (error, canonical) = state.withLock {
      $0.addProjectCalls.append((path, create))
      return ($0.addProjectError, $0.canonicalToReturn)
    }
    if let error { throw error }
    return canonical
  }

  func cloneProject(_ url: String, into path: String, onLog: @escaping @Sendable (String) -> Void)
    async throws -> String
  {
    let (error, canonical, progress) = state.withLock {
      $0.cloneCalls.append((url, path))
      return ($0.addProjectError, $0.canonicalToReturn, $0.cloneProgress)
    }
    progress.forEach(onLog)
    if let error { throw error }
    return canonical
  }

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    throw WorkroomCLIError.timedOut  // not exercised by these tests
  }

  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}

@MainActor
final class AppStoreAddProjectTests: XCTestCase {

  private func makeStore(_ fake: FakeWorkroomCLI) -> AppStore {
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    return store
  }

  /// Create mode passes --create and selects the project by the CANONICAL path the
  /// CLI returned — not the (possibly ~/symlinked) path the user typed.
  func testCreateModePassesFlagAndSelectsByCanonicalPath() async {
    let canonical = "/private/var/tmp/wr-new-project"
    let fake = FakeWorkroomCLI(
      canonical: canonical,
      projects: [Project(path: canonical, vcs: "git", workrooms: [])])
    let store = makeStore(fake)

    await store.addProject("~/typed/path", create: true)

    XCTAssertEqual(fake.addProjectCalls.count, 1)
    XCTAssertEqual(fake.addProjectCalls.first?.path, "~/typed/path")
    XCTAssertEqual(fake.addProjectCalls.first?.create, true)
    XCTAssertEqual(store.selectedProjectID, canonical, "should select by the CLI's canonical path")
    XCTAssertEqual(store.selectedTargetID, .root(project: canonical))
  }

  /// Existing mode passes create:false (preserving the repo-only path).
  func testExistingModePassesCreateFalse() async {
    let canonical = "/private/var/tmp/wr-existing-repo"
    let fake = FakeWorkroomCLI(
      canonical: canonical,
      projects: [Project(path: canonical, vcs: "git", workrooms: [])])
    let store = makeStore(fake)

    await store.addProject(canonical, create: false)

    XCTAssertEqual(fake.addProjectCalls.first?.create, false)
    XCTAssertEqual(store.selectedProjectID, canonical)
  }

  /// The `Result` contract (issue #151 — the onboarding wizard reads this to decide whether to
  /// advance, instead of relying on `errorMessage`): a successful add returns `.success`.
  func testAddProjectReturnsSuccessOnSuccess() async {
    let canonical = "/private/var/tmp/wr-result-success"
    let fake = FakeWorkroomCLI(
      canonical: canonical,
      projects: [Project(path: canonical, vcs: "git", workrooms: [])])
    let store = makeStore(fake)

    let result = await store.addProject(canonical, create: false)

    guard case .success = result else { return XCTFail("expected .success, got \(result)") }
  }

  /// A CLI-level failure returns `.failure` carrying the same error `present(error)` already
  /// displays — not silently swallowed into a bare `false`.
  func testAddProjectReturnsFailureOnCLIError() async {
    let fake = FakeWorkroomCLI(canonical: "/unused", projects: [])
    fake.addProjectError = WorkroomCLIError.cli(kind: "permission_denied", message: "denied")
    let store = makeStore(fake)

    let result = await store.addProject("/some/path", create: true)

    guard case .failure(let error) = result else {
      return XCTFail("expected .failure, got \(result)")
    }
    XCTAssertEqual((error as? WorkroomCLIError)?.errorDescription, "denied")
    XCTAssertNotNil(
      store.modals.errorMessage, "present(error) should still fire on the store, unchanged")
  }

  // MARK: Clone a repository… (issue #620)

  /// A clone streams git's progress to the caller, then selects the clone by the CLI's canonical
  /// path and opens its root, as any other add does.
  func testCloneStreamsProgressAndSelectsTheClone() async {
    let canonical = "/private/var/tmp/wr-clone/api"
    let fake = FakeWorkroomCLI(
      canonical: canonical,
      projects: [Project(path: canonical, vcs: "git", workrooms: [])])
    fake.cloneProgress = ["Cloning into '/tmp/wr-clone/api'...", "Receiving objects: 42% (21/50)"]
    let store = makeStore(fake)
    let seen = Mutex<[String]>([])

    let result = await store.cloneProject(
      "git@github.com:acme/api.git", into: "/tmp/wr-clone/api",
      onProgress: { line in seen.withLock { $0.append(line) } })

    guard case .success = result else { return XCTFail("expected .success, got \(result)") }
    XCTAssertEqual(fake.cloneCalls.first?.url, "git@github.com:acme/api.git")
    XCTAssertEqual(fake.cloneCalls.first?.path, "/tmp/wr-clone/api")
    XCTAssertEqual(seen.withLock { $0 }, fake.cloneProgress)
    XCTAssertEqual(store.selectedProjectID, canonical)
    XCTAssertEqual(store.selectedTargetID, .root(project: canonical))
  }

  /// A failed clone hands its error back for the sheet to show inline: no alert behind the sheet.
  func testCloneFailureIsReturnedNotPresented() async {
    let fake = FakeWorkroomCLI(canonical: "/unused", projects: [])
    fake.addProjectError = WorkroomCLIError.cli(
      kind: "CloneFailed", message: "git clone failed: Permission denied (publickey).")
    let store = makeStore(fake)

    let result = await store.cloneProject("git@github.com:acme/api.git", into: "/x/api") { _ in }

    guard case .failure(let error) = result else {
      return XCTFail("expected .failure, got \(result)")
    }
    XCTAssertEqual((error as? WorkroomCLIError)?.kind, "CloneFailed")
    XCTAssertNil(store.modals.errorMessage, "the sheet shows a clone's error, not an alert")
    XCTAssertNil(store.selectedProjectID)
  }
}
