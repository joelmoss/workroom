import Foundation
import WorkroomDomain
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
  /// What a failing delete throws, and the script output it streams first.
  var deleteError: Error = WorkroomCLIError.timedOut
  var deleteLog: [String] = []
  /// Each delete's `skipTeardown`, in order, workroom and project deletes alike.
  private(set) var skips: [Bool] = []
  /// What a released `deleteProject` hands back to move to the Bin.
  var trashPaths: [URL] = []
  private(set) var listCalls = 0
  /// When true, `list` throws — modelling a config read that fails after a delete succeeded.
  var listFails = false

  func list(warnings: String, project: String?) async throws -> ListResponse {
    listCalls += 1
    if listFails { throw WorkroomCLIError.timedOut }
    return ListResponse(projects: listResult, workroomsDir: nil, configPath: nil)
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
    skips.append(false)
    try await gatedDelete(onLog)
  }

  func delete(
    name: String, project: String, skipTeardown: Bool, onLog: (@Sendable (String) -> Void)?
  ) async throws {
    skips.append(skipTeardown)
    try await gatedDelete(onLog)
  }

  private func gatedDelete(_ onLog: ((String) -> Void)?) async throws {
    deleteStarted = true
    // Gate: hold the teardown open until the test releases it, keeping the tombstone live.
    while !allowDelete { await Task.yield() }
    if deleteFails {
      for line in deleteLog { onLog?(line) }
      throw deleteError
    }
  }

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] {
    skips.append(false)
    return try await gatedDeleteProject(onLog)
  }

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, skipTeardown: Bool,
    onLog: (@Sendable (String) -> Void)?
  ) async throws -> [URL] {
    skips.append(skipTeardown)
    return try await gatedDeleteProject(onLog)
  }

  /// Each script approved (#363), as "<name> <text>".
  private(set) var approvals: [String] = []

  func trustScript(_ name: String, text: Data, project: String) async throws {
    approvals.append("\(name) \(String(decoding: text, as: UTF8.self))")
  }

  private func gatedDeleteProject(_ onLog: ((String) -> Void)?) async throws -> [URL] {
    // Gated like `delete`, so the project tombstone stays live across a concurrent reload (#287).
    deleteStarted = true
    while !allowDelete { await Task.yield() }
    if deleteFails {
      for line in deleteLog { onLog?(line) }
      throw deleteError
    }
    return trashPaths
  }
}

/// Holds one `prepareRepositories` call open so a test can park a read between its `list` and its
/// publication. Polled across tasks without a lock, which is enough for a test gate.
private final class PrepareGate: @unchecked Sendable {
  private(set) var calls = 0
  var open = false

  func enter() -> Int {
    calls += 1
    return calls
  }
}

/// Records what each trash request saw: whether the project was still tombstoned, and how many
/// `list` reads had started.
private final class OrderTrasher: Trashing {
  var observe: () -> (tombstoned: Bool, listCalls: Int) = { (false, 0) }
  private(set) var seen: [(tombstoned: Bool, listCalls: Int)] = []
  func trash(_ url: URL) throws { seen.append(observe()) }
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

  /// A read issued before config dropped the workroom, still in flight when the teardown succeeds,
  /// must not publish the workroom once the tombstone lifts: the success path's own reload
  /// supersedes it (#295).
  func testStaleReloadInFlightAcrossSuccessfulTeardownDoesNotResurrectWorkroom() async {
    let a = workroom("a")
    let b = workroom("b")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a, b])]
    let shared = ProjectStore()
    let gate = PrepareGate()
    shared.prepareRepositories = { _ in
      // Hold only the stale read (the second call), between its `list` and its publication.
      if gate.enter() == 2 { while !gate.open { await Task.yield() } }
      return []
    }
    let store = AppStore(projectStore: shared, cli: fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a, b]))
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    let stale = Task { await store.reload() }  // `list` still has `a`
    await waitUntil({ gate.calls == 2 }, "stale read should reach publication")

    fake.listResult = [project([b])]  // config drops `a`
    fake.allowDelete = true
    await waitUntil({ store.deletingWorkrooms.isEmpty }, "tombstone should clear after teardown")
    gate.open = true
    await stale.value
    XCTAssertEqual(
      workroomNames(store), ["b"], "a stale in-flight read must not republish the workroom")
  }

  /// The reload a successful teardown runs is quiet: if that `list` fails, the delete that worked
  /// is not reported as an error, and the workroom stays gone (#295).
  // Value: protects=a successful delete is never reported as an error because its follow-up read
  //   failed; fails_when=the success path's load surfaces errors (plain reload());
  //   why_new=no other test makes list throw after a successful teardown; seam=none
  func testFailedReloadAfterSuccessfulTeardownShowsNoError() async {
    let a = workroom("a")
    let b = workroom("b")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a, b])]
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a, b]))
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    fake.listFails = true
    fake.allowDelete = true
    // The tombstone lifts only after the success path's load returns.
    await waitUntil({ store.deletingWorkrooms.isEmpty }, "tombstone should clear after teardown")
    XCTAssertNil(store.errorMessage, "a delete that succeeded must not report an error")
    XCTAssertEqual(workroomNames(store), ["b"], "the workroom stays gone")
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

  /// A failed teardown keeps the CLI's reason as the message and shows the script's output apart,
  /// in the sheet's log box: the output alone doesn't say which script failed or how.
  func testFailedTeardownShowsTheReasonAboveTheScriptOutput() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.deleteFails = true
    let reason =
      "teardown script failed: /x/scripts/workroom_teardown returned a non-zero exit code"
    fake.deleteError = WorkroomCLIError.cli(kind: "TeardownScriptFailed", message: reason)
    fake.deleteLog = ["dropping myapp_a", "dropdb: database does not exist"]
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a]))
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    fake.allowDelete = true
    await waitUntil({ store.errorMessage != nil }, "the failure is surfaced")

    XCTAssertEqual(store.errorTitle, "Teardown of ‘a’ failed")
    XCTAssertEqual(store.errorMessage, reason)
    XCTAssertEqual(store.errorLog, "dropping myapp_a\ndropdb: database does not exist")
  }

  /// A teardown that printed nothing shows no log box, only the reason.
  func testSilentFailedTeardownShowsNoLog() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.deleteFails = true
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a]))
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    fake.allowDelete = true
    await waitUntil({ store.errorMessage != nil }, "the failure is surfaced")

    XCTAssertEqual(store.errorMessage, WorkroomCLIError.timedOut.errorDescription)
    XCTAssertNil(store.errorLog)
    XCTAssertEqual(store.errorAction?.label, "Delete Anyway", "a teardown that ran out of time")
  }

  private static let teardownFailed = WorkroomCLIError.cli(
    kind: "TeardownScriptFailed",
    message: "teardown script failed: /x/scripts/workroom_teardown returned a non-zero exit code")

  /// Value: protects=D3, a failed teardown offers Delete Anyway, which deletes the workroom as it is
  /// now with the script skipped; fails_when=no action, or the retry runs the script again;
  /// no_claim=the CLI's flag itself (cmd and workroom tests cover it)
  func testATeardownFailureOffersDeleteAnywayWhichSkipsTheScript() async throws {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.deleteFails = true
    fake.deleteError = Self.teardownFailed
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a]))
    fake.allowDelete = true
    await waitUntil({ store.errorAction != nil }, "no Delete Anyway was offered")
    XCTAssertEqual(store.errorAction?.label, "Delete Anyway")

    fake.deleteFails = false
    fake.listResult = [project([])]
    let action = try XCTUnwrap(store.errorAction)
    store.clearError()
    action.run()
    await waitUntil({ fake.skips == [false, true] }, "Delete Anyway didn't skip the script")
    await waitUntil({ self.workroomNames(store).isEmpty }, "the workroom wasn't deleted")
  }

  /// Value: protects=#363, a teardown this Mac has not approved offers Approve beside Delete Anyway,
  /// says why the delete stopped and for which workroom of which project, shows the script to read,
  /// and Approve records the bytes shown then deletes with the script; fails_when=no approval is
  /// offered, the message leaves out the reason, workroom or project, the script isn't shown, or the
  /// delete skips the script or never runs again; no_claim=the sheet's drawing (UI tests)
  func testAnUnapprovedTeardownOffersApprove() async throws {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.deleteFails = true
    let script = ScriptTrust(
      name: "workroom_teardown", origin: "workroom", sha256: String(repeating: "b", count: 64),
      text: "#!/bin/sh\ndropdb a\n", trusted: false, exempt: false)
    fake.deleteError = WorkroomCLIError.scriptNotTrusted(script, message: "script is not trusted")
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a]))
    fake.allowDelete = true
    await waitUntil({ store.errorApproval != nil }, "no Approve was offered")
    XCTAssertEqual(store.errorApproval?.label, "Approve")
    XCTAssertEqual(store.errorAction?.label, "Delete Anyway")
    XCTAssertEqual(store.errorTitle, "Approve the teardown script?")
    XCTAssertEqual(
      store.errorMessage,
      "Deleting ‘a’ in \(project([a]).displayName) runs scripts/workroom_teardown in the workroom "
        + "first, and it is new, or changed since it was approved on this Mac. Read it, then "
        + "approve it to run it and delete the workroom, or delete without running it.")
    XCTAssertNotNil(store.errorDetails, "the error's codes went with the new message")
    XCTAssertEqual(store.errorLog, "#!/bin/sh\ndropdb a\n")
    XCTAssertEqual(
      store.errorScriptName, "workroom_teardown", "the sheet can't draw it as its file")

    fake.deleteFails = false
    fake.listResult = [project([])]
    let approve = try XCTUnwrap(store.errorApproval)
    store.clearError()
    approve.run()
    await waitUntil(
      { fake.skips == [false, false] }, "Approve didn't delete with the script")
    XCTAssertEqual(fake.approvals, ["workroom_teardown #!/bin/sh\ndropdb a\n"])
    await waitUntil({ self.workroomNames(store).isEmpty }, "the workroom wasn't deleted")
  }

  /// Value: protects=R6, a delete that failed outside its script offers no Delete Anyway, which
  /// would fail the same way; fails_when=the button shows for a git failure; no_claim=none beyond
  /// protects
  func testAFailureOutsideTheScriptOffersNoDeleteAnyway() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.deleteFails = true
    fake.deleteError = WorkroomCLIError.cli(kind: "VCSCommandFailed", message: "git said no")
    let store = makeStore(fake)
    await store.reload()

    store.deleteWorkroom(a, in: project([a]))
    fake.allowDelete = true
    await waitUntil({ store.errorMessage != nil }, "the failure is surfaced")
    XCTAssertNil(store.errorAction)
  }

  // MARK: - Delete withdraws notifications

  /// Deleting a workroom must withdraw its pending notifications (`AppStore.reapTargetLocally` calls
  /// `notifications.removeForTarget`) — a sibling workroom's notifications must be untouched. A real
  /// XCUITest fixture-mode round trip can't isolate this cleanly: fixture projects are never
  /// registered with the CLI, so `deleteWorkroom`'s teardown always fails there (see
  /// `testFailedTeardownRestoresWorkroom` above) and the notifications legitimately come back with
  /// the restored workroom — this unit test exercises the SUCCEEDING path `DeleteRaceFakeCLI` can
  /// give a fast, deterministic answer for.
  func testDeletingAWorkroomWithdrawsItsNotifications() async {
    let a = workroom("a")
    let b = workroom("b")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a, b])]
    fake.allowDelete = true  // teardown completes immediately, and succeeds
    let store = makeStore(fake)
    await store.reload()

    let aTarget = targetID("a")
    let bTarget = targetID("b")
    func notification(for target: TerminalTarget.ID, title: String) -> WorkroomNotification {
      WorkroomNotification(
        id: UUID(), targetID: target, tabID: UUID(), source: "test", title: title,
        body: nil, date: Date(), count: 1)
    }
    store.notifications.seedForTesting([
      notification(for: aTarget, title: "a's notification"),
      notification(for: bTarget, title: "b's notification"),
    ])
    XCTAssertEqual(store.notifications.count(target: aTarget), 1)
    XCTAssertEqual(store.notifications.count(target: bTarget), 1)

    store.deleteWorkroom(a, in: project([a, b]))
    await waitUntil(
      { store.notifications.count(target: aTarget) == 0 },
      "deleting a workroom should withdraw its pending notifications")
    XCTAssertEqual(
      store.notifications.count(target: bTarget), 1,
      "a sibling workroom's notifications must be untouched")
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

  // MARK: - Delete Project tombstone (#287)

  /// A reload while Delete Project's teardown is in flight must not republish the project, and a
  /// second delete of it is refused.
  func testStaleReloadDoesNotResurrectDeletingProject() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    let store = makeStore(fake)
    await store.reload()

    store.deleteProject(project([a]), scope: .configOnly)
    XCTAssertTrue(store.projects.isEmpty, "optimistic removal")
    await waitUntil({ fake.deleteStarted }, "teardown should start")

    await store.reload()  // stale: `list` still has the project
    XCTAssertTrue(store.projects.isEmpty, "a stale reload must NOT bring the project back")

    store.deleteProject(project([a]), scope: .configOnly)
    XCTAssertEqual(store.errorMessage, "\(project([a]).displayName) is already being deleted.")

    fake.allowDelete = true
    await waitUntil({ store.deletingProjects.isEmpty }, "tombstone should clear after teardown")
    fake.listResult = []
    await store.reload()
    XCTAssertTrue(store.projects.isEmpty, "a fresh list after the teardown keeps it gone")
  }

  /// The tombstone lives in the shared `ProjectStore`, so another window's reload can't republish
  /// the project and its stale confirm dialog can't start a second delete.
  func testDeletingProjectTombstoneIsSharedAcrossWindows() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    let shared = ProjectStore()
    let windowA = AppStore(projectStore: shared, cli: fake)
    let windowB = AppStore(projectStore: shared, cli: fake)
    await windowA.reload()

    windowA.deleteProject(project([a]), scope: .configOnly)
    await waitUntil({ fake.deleteStarted }, "teardown should start")

    await windowB.reload()  // stale: `list` still has the project
    XCTAssertTrue(windowB.projects.isEmpty, "another window's reload must not republish it")
    windowB.deleteProject(project([a]), scope: .configOnly)
    XCTAssertEqual(windowB.errorMessage, "\(project([a]).displayName) is already being deleted.")

    fake.allowDelete = true
    await waitUntil({ shared.deletingProjects.isEmpty }, "tombstone should clear after teardown")
  }

  /// A read issued before config dropped the project, still in flight when the delete succeeds,
  /// must not publish the project once the tombstone lifts: the success path's own reload
  /// supersedes it.
  func testStaleReloadInFlightAcrossSuccessfulDeleteDoesNotResurrectProject() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    let shared = ProjectStore()
    let gate = PrepareGate()
    shared.prepareRepositories = { _ in
      // Hold only the stale read (the second call), between its `list` and its publication.
      if gate.enter() == 2 { while !gate.open { await Task.yield() } }
      return []
    }
    let store = AppStore(projectStore: shared, cli: fake)
    await store.reload()

    store.deleteProject(project([a]), scope: .configOnly)
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    let stale = Task { await store.reload() }  // `list` still has the project
    await waitUntil({ gate.calls == 2 }, "stale read should reach publication")

    fake.listResult = []  // config drops the project
    fake.allowDelete = true
    await waitUntil({ shared.deletingProjects.isEmpty }, "tombstone should clear after teardown")
    gate.open = true
    await stale.value
    XCTAssertTrue(store.projects.isEmpty, "a stale in-flight read must not republish the project")
  }

  /// A create from a picker opened before the delete is refused while the project is tombstoned.
  func testCreateRefusedWhileProjectIsBeingDeleted() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    let store = makeStore(fake)
    await store.reload()

    store.deleteProject(project([a]), scope: .configOnly)
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    await store.createWorkroom(in: project([a]))
    XCTAssertEqual(store.errorMessage, "\(project([a]).displayName) is being deleted.")
    XCTAssertTrue(store.creationRuns.isEmpty, "no create was started")
    XCTAssertFalse(store.canCreateRemoteWorkroom(in: project([a])), "nor a remote one")

    fake.allowDelete = true
    await waitUntil({ store.deletingProjects.isEmpty }, "tombstone should clear after teardown")
  }

  /// `--from-disk` moves the returned directories to the Bin while the project is still tombstoned
  /// and before the success path's reload suspends, so nothing can re-register them in between.
  func testFromDiskTrashesBeforeTheReloadAndTheLift() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.trashPaths = [URL(fileURLWithPath: projectPath)]
    let store = makeStore(fake)
    let trasher = OrderTrasher()
    trasher.observe = { [unowned store] in
      (store.deletingProjects.contains(self.projectPath), fake.listCalls)
    }
    store.trasher = trasher
    await store.reload()

    store.deleteProject(project([a]), scope: .fromDisk)
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    let readsBefore = fake.listCalls
    fake.listResult = []
    fake.allowDelete = true
    await waitUntil({ store.deletingProjects.isEmpty }, "tombstone should clear after teardown")

    XCTAssertEqual(trasher.seen.count, 1)
    XCTAssertEqual(trasher.seen.first?.tombstoned, true, "trashed while still tombstoned")
    XCTAssertEqual(trasher.seen.first?.listCalls, readsBefore, "trashed before the reload began")
    XCTAssertTrue(store.projects.isEmpty)
  }

  /// A FAILED Delete Project lifts the tombstone before reloading, so the project reappears.
  func testFailedDeleteProjectRestoresProject() async {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.deleteFails = true
    let store = makeStore(fake)
    await store.reload()

    store.deleteProject(project([a]), scope: .configOnly)
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    fake.allowDelete = true
    await waitUntil({ self.workroomNames(store) == ["a"] }, "failed delete restores the project")
    XCTAssertTrue(store.deletingProjects.isEmpty, "tombstone cleared on failure")
    XCTAssertNotNil(store.errorTitle, "the failure is surfaced")
  }

  /// A cascade whose teardown fails keeps the reason as the message and the output in the log box,
  /// as a single workroom's delete does.
  func testFailedDeleteProjectShowsTheReasonAboveTheScriptOutput() async throws {
    let a = workroom("a")
    let fake = DeleteRaceFakeCLI()
    fake.listResult = [project([a])]
    fake.deleteFails = true
    let reason =
      "teardown script failed: /x/scripts/workroom_teardown returned a non-zero exit code"
    fake.deleteError = WorkroomCLIError.cli(kind: "TeardownScriptFailed", message: reason)
    fake.deleteLog = ["rm: cannot remove 'tmp'"]
    let store = makeStore(fake)
    await store.reload()

    store.deleteProject(project([a]), scope: .workrooms)
    await waitUntil({ fake.deleteStarted }, "teardown should start")
    fake.allowDelete = true
    await waitUntil({ store.errorMessage != nil }, "the failure is surfaced")

    XCTAssertEqual(store.errorTitle, "Delete of ‘wr-race-project’ failed")
    XCTAssertEqual(store.errorMessage, reason)
    XCTAssertEqual(store.errorLog, "rm: cannot remove 'tmp'")

    // Delete Anyway reruns the same scope with every teardown skipped.
    fake.deleteFails = false
    fake.listResult = []
    let action = try XCTUnwrap(store.errorAction)
    // A project's says it skips every remaining teardown, not only the failed one.
    XCTAssertEqual(action.label, "Delete Without Teardowns")
    store.clearError()
    action.run()
    await waitUntil({ fake.skips == [false, true] }, "Delete Anyway didn't skip the teardowns")
    await waitUntil({ store.projects.isEmpty }, "the project wasn't deleted")
  }

  /// A later message must not show an earlier failure's output.
  func testANewErrorMessageDropsTheLog() {
    let store = makeStore(DeleteRaceFakeCLI())
    store.errorMessage = "first"
    store.errorLog = "output"
    store.errorMessage = "second"
    XCTAssertNil(store.errorLog)
  }
}
