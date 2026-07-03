import Foundation
import XCTest

@testable import Workroom

/// A fake CLI for the create/delete reload-race tests. `list` returns a controllable snapshot (so a
/// test can simulate a STALE list taken before a teardown persisted), and `delete` is *gated*: it
/// blocks until the test flips `allowDelete`, so the deletion tombstone stays active across a
/// concurrent reload — exactly the window in which the bug resurrects a deleted workroom.
private final class DeleteRaceFakeCLI: WorkroomCLIProtocol {
  /// What `list` returns — mutate between reloads to model stale vs fresh config snapshots.
  var listResult: [Project] = []
  /// Set true once `delete` has been entered (its teardown is in flight, tombstone active).
  private(set) var deleteStarted = false
  /// Flip true to let the gated `delete` complete (teardown finishes).
  var allowDelete = false
  /// When true, the released `delete` throws — modelling a failed teardown (workroom stays on disk).
  var deleteFails = false

  func list(warnings: String, project: String?) async throws -> ListResponse {
    ListResponse(projects: listResult, workroomsDir: nil, configPath: nil)
  }

  func addProject(_ path: String, create: Bool) async throws -> String { path }

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    throw WorkroomCLIError.timedOut  // not exercised by these tests
  }

  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {
    deleteStarted = true
    // Gate: hold the teardown open until the test releases it, keeping the tombstone live.
    while !allowDelete { await Task.yield() }
    if deleteFails { throw WorkroomCLIError.timedOut }
  }

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}

@MainActor
final class AppStoreDeleteRaceTests: XCTestCase {
  private let projectPath = "/private/var/tmp/wr-race-project"

  private func makeStore(_ fake: WorkroomCLIProtocol) -> AppStore {
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    return store
  }

  private func workroom(_ name: String) -> Workroom {
    Workroom(name: name, path: "\(projectPath)/.workrooms/\(name)", vcsName: "git", warnings: [])
  }

  private func project(_ workrooms: [Workroom]) -> Project {
    Project(path: projectPath, vcs: "git", workrooms: workrooms)
  }

  private func workroomNames(_ store: AppStore) -> [String] {
    (store.projects.first { $0.id == projectPath }?.workrooms.map(\.name) ?? []).sorted()
  }

  private func targetID(_ name: String) -> TerminalTarget.ID {
    TerminalTarget.workroomID(project: projectPath, name: name)
  }

  /// Poll a condition on the main actor, letting queued teardown/reload work run. Bounded so a broken
  /// condition fails the assertion instead of hanging.
  private func waitUntil(
    _ condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms; up to ~400ms total
    }
    XCTFail(message, file: file, line: line)
  }

  // MARK: - The reload race (the reported bug)

  /// The core bug: after a workroom is optimistically deleted, a concurrent reload whose `list`
  /// snapshot was taken BEFORE the teardown persisted must NOT resurrect it (issue #116).
  func testStaleReloadDoesNotResurrectDeletedWorkroom() async {
    let a = workroom("a")
    let b = workroom("b")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a, b])]
    let store = makeStore(fake)
    await store.reload()
    XCTAssertEqual(workroomNames(store), ["a", "b"])

    // Delete `a`. Its teardown is gated (never released here), so `a` stays tombstoned throughout.
    store.deleteWorkroom(a, in: project([a, b]))
    XCTAssertEqual(workroomNames(store), ["b"], "optimistic removal drops it immediately")
    XCTAssertTrue(store.deletingWorkrooms.contains(targetID("a")))

    // A concurrent flow (another create/delete/refresh) reloads while `a`'s teardown is still in
    // flight — and its `list` snapshot is STALE, still listing `a` (config not yet updated).
    fake.listResult = [project([a, b])]
    await store.reload()
    XCTAssertEqual(
      workroomNames(store), ["b"],
      "a stale reload must NOT bring the deleted workroom back")

    // Let the teardown finish; the tombstone lifts and a now-fresh list stays clean.
    fake.allowDelete = true
    await waitUntil({ store.deletingWorkrooms.isEmpty }, "tombstone should clear after teardown")
    fake.listResult = [project([b])]
    await store.reload()
    XCTAssertEqual(workroomNames(store), ["b"])
  }

  /// A FAILED teardown must restore the workroom: the tombstone is cleared and the reload brings it
  /// back (it still exists on disk / in config).
  func testFailedTeardownRestoresWorkroom() async {
    let a = workroom("a")
    let b = workroom("b")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a, b])]
    fake.deleteFails = true
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a, b]))
    XCTAssertEqual(workroomNames(store), ["b"], "optimistic removal")
    await waitUntil({ fake.deleteStarted }, "teardown should start")

    // The teardown fails; config still has `a`, so it must reappear once the tombstone clears.
    fake.allowDelete = true
    await waitUntil(
      { self.workroomNames(store) == ["a", "b"] }, "failed teardown restores the workroom")
    XCTAssertFalse(store.deletingWorkrooms.contains(targetID("a")), "tombstone cleared on failure")
  }

  /// The tombstone clears after a successful teardown, so re-creating a same-named workroom later
  /// isn't filtered out by a stale tombstone.
  func testTombstoneClearsAfterSuccessfulTeardown() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a]))
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    fake.allowDelete = true
    await waitUntil({ store.deletingWorkrooms.isEmpty }, "tombstone should clear")

    // A fresh create of the same name resolves normally (not filtered by a lingering tombstone).
    fake.listResult = [project([a])]
    await store.reload()
    XCTAssertEqual(workroomNames(store), ["a"])
  }

  // MARK: - Delete blocked during setup

  /// A workroom whose create is still in flight (its setup runs against the worktree) can't be
  /// deleted — the delete is a no-op and never tombstones it (issue #116).
  func testDeleteBlockedWhileCreating() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    let store = makeStore(fake)
    await store.reload()

    store.creatingWorkrooms.insert(targetID("a"))
    store.deleteWorkroom(a, in: project([a]))

    XCTAssertEqual(workroomNames(store), ["a"], "delete is blocked while the setup is in progress")
    XCTAssertFalse(store.deletingWorkrooms.contains(targetID("a")), "no teardown was started")
  }
}
