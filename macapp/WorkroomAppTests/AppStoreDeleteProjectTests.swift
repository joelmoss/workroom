import XCTest

@testable import Workroom

/// Project-deletion tests (issue #61). These drive the SAFE, synchronous seams only —
/// `removeProjectLocally` (optimistic in-memory cleanup), `SidebarID.belongsToProject`, and the
/// pure `DeleteProjectSheetModel`. The background CLI/config path (`deleteProject` → the bundled
/// `workroom` binary → the real ~/.config/workroom/config.json) is deliberately NOT exercised
/// here — it is covered by manual QA so the test suite never touches real projects or config.
@MainActor
final class AppStoreDeleteProjectTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  // MARK: removeProjectLocally

  func testRemoveProjectLocallyDropsProjectAndReturnsAllTargets() {
    let p = project("/a", workrooms: ["feat", "bug"])
    let store = makeStore([p, project("/b", workrooms: ["x"])])

    let targets = store.removeProjectLocally(p)

    XCTAssertFalse(store.projects.contains { $0.id == "/a" }, "project not removed")
    XCTAssertTrue(store.projects.contains { $0.id == "/b" }, "unrelated project disturbed")
    XCTAssertEqual(
      Set(targets),
      [
        TerminalTarget.rootID(project: "/a"),
        TerminalTarget.workroomID(project: "/a", name: "feat"),
        TerminalTarget.workroomID(project: "/a", name: "bug"),
      ], "should return the root + every workroom target id")
  }

  func testRemoveProjectLocallyClearsSelectionInsideProject() {
    let p = project("/a", workrooms: ["feat"])
    let store = makeStore([p])
    store.selectedProjectID = "/a"
    store.selectedTargetID = .workroom(project: "/a", name: "feat")

    store.removeProjectLocally(p)

    XCTAssertNil(store.selectedTargetID, "selection inside the deleted project must clear")
    XCTAssertNil(store.selectedProjectID, "selected project must clear")
  }

  func testRemoveProjectLocallyPreservesSelectionInOtherProject() {
    let p = project("/a", workrooms: ["feat"])
    let other = project("/b", workrooms: ["x"])
    let store = makeStore([p, other])
    store.selectedProjectID = "/b"
    store.selectedTargetID = .root(project: "/b")

    store.removeProjectLocally(p)

    XCTAssertEqual(
      store.selectedTargetID, .root(project: "/b"), "other project's selection must survive")
    XCTAssertEqual(store.selectedProjectID, "/b")
  }

  func testRemoveProjectLocallyDropsStatuses() {
    let p = project("/a", workrooms: ["feat"])
    let store = makeStore([p])
    store.workroomStatuses[.root(project: "/a")] = .unresolved
    store.workroomStatuses[.workroom(project: "/a", name: "feat")] = .unresolved

    store.removeProjectLocally(p)

    XCTAssertNil(store.workroomStatuses[.root(project: "/a")], "root status must drop")
    XCTAssertNil(
      store.workroomStatuses[.workroom(project: "/a", name: "feat")], "workroom status must drop")
  }

  /// #127 follow-up: a pending Project Settings sheet targeting the deleted project must clear, or
  /// its Save path would still write config for the now-gone path (a re-add of that same path would
  /// silently inherit the stale config).
  func testRemoveProjectLocallyClearsPendingProjectSettingsForTheDeletedProject() {
    let p = project("/a", workrooms: [])
    let store = makeStore([p])
    store.pendingProjectSettings = PendingProjectSettings(project: p)

    store.removeProjectLocally(p)

    XCTAssertNil(store.pendingProjectSettings, "pending sheet for the deleted project must clear")
  }

  /// A pending sheet for a DIFFERENT project must survive an unrelated project's deletion.
  func testRemoveProjectLocallyPreservesPendingProjectSettingsForAnotherProject() {
    let p = project("/a", workrooms: [])
    let other = project("/b", workrooms: [])
    let store = makeStore([p, other])
    store.pendingProjectSettings = PendingProjectSettings(project: other)

    store.removeProjectLocally(p)

    XCTAssertEqual(
      store.pendingProjectSettings?.project.path, "/b",
      "pending sheet for an unrelated project must not be cleared")
  }

  /// Same gap, same fix, for the workroom-label sheet (issue #41's pending state).
  func testRemoveProjectLocallyClearsPendingWorkroomLabelForTheDeletedProject() {
    let p = project("/a", workrooms: ["feat"])
    let store = makeStore([p])
    store.pendingWorkroomLabel = PendingWorkroomLabel(workroom: p.workrooms[0], project: p)

    store.removeProjectLocally(p)

    XCTAssertNil(
      store.pendingWorkroomLabel, "pending label sheet for the deleted project must clear")
  }

  // MARK: - Cross-window deletion (adversarial review: removeProjectLocally only covers the
  // deleting window's own store — another window's reload goes through `apply(_:)` instead)

  /// A pending Project Settings sheet must also clear when the project disappears from a RELOAD
  /// (e.g. another window deleted it) — not just from this window's own `removeProjectLocally`.
  /// Otherwise Save would still write `Defaults[.runCommands]` for the now-gone path.
  func testReloadClearsPendingProjectSettingsForAProjectDeletedElsewhere() async {
    let p = project("/a", workrooms: [])
    let fake = FakeWorkroomCLI(canonical: "/a", projects: [p])
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    await store.reload()
    store.pendingProjectSettings = PendingProjectSettings(project: p)

    // Simulate another window deleting "/a": the next `list` snapshot no longer contains it.
    fake.projectsToList = []
    await store.reload()

    XCTAssertNil(
      store.pendingProjectSettings,
      "pending sheet must clear once its project is gone from a reload, not just a local delete")
  }

  /// A pending workroom-label sheet must likewise clear when its workroom disappears from a reload.
  func testReloadClearsPendingWorkroomLabelForAWorkroomDeletedElsewhere() async {
    let p = project("/a", workrooms: ["feat"])
    let fake = FakeWorkroomCLI(canonical: "/a", projects: [p])
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    await store.reload()
    store.pendingWorkroomLabel = PendingWorkroomLabel(workroom: p.workrooms[0], project: p)

    // Simulate another window deleting the "feat" workroom.
    fake.projectsToList = [project("/a", workrooms: [])]
    await store.reload()

    XCTAssertNil(
      store.pendingWorkroomLabel,
      "pending label sheet must clear once its workroom is gone from a reload")
  }

  /// A pending sheet for a project that's still live must survive an unrelated reload.
  func testReloadPreservesPendingProjectSettingsWhenProjectStillLive() async {
    let p = project("/a", workrooms: [])
    let fake = FakeWorkroomCLI(canonical: "/a", projects: [p])
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    await store.reload()
    store.pendingProjectSettings = PendingProjectSettings(project: p)

    await store.reload()  // same project still in the list

    XCTAssertEqual(
      store.pendingProjectSettings?.project.path, "/a",
      "pending sheet must survive a reload where its project is still live")
  }

  // MARK: SidebarID.belongsToProject

  func testSidebarIDBelongsToProject() {
    XCTAssertTrue(SidebarID.root(project: "/a").belongsToProject("/a"))
    XCTAssertTrue(SidebarID.workroom(project: "/a", name: "feat").belongsToProject("/a"))
    XCTAssertTrue(SidebarID.project("/a").belongsToProject("/a"))
    XCTAssertFalse(SidebarID.root(project: "/b").belongsToProject("/a"))
    XCTAssertFalse(SidebarID.workroom(project: "/b", name: "feat").belongsToProject("/a"))
  }

  // MARK: DeleteProjectSheetModel (pure presentation rules)

  func testSheetNameMatchIsExact() {
    XCTAssertTrue(DeleteProjectSheetModel.nameMatches(typed: "app", displayName: "app"))
    XCTAssertFalse(DeleteProjectSheetModel.nameMatches(typed: "App", displayName: "app"))
    XCTAssertFalse(DeleteProjectSheetModel.nameMatches(typed: " app ", displayName: "app"))
    XCTAssertFalse(DeleteProjectSheetModel.nameMatches(typed: "", displayName: "app"))
  }

  func testSheetDeleteLabelPerScope() {
    XCTAssertEqual(
      DeleteProjectSheetModel.deleteLabel(scope: .configOnly, workroomCount: 3), "Delete Project")
    XCTAssertEqual(
      DeleteProjectSheetModel.deleteLabel(scope: .workrooms, workroomCount: 3),
      "Delete Project & 3 Workrooms")
    XCTAssertEqual(
      DeleteProjectSheetModel.deleteLabel(scope: .workrooms, workroomCount: 1),
      "Delete Project & 1 Workroom", "singular workroom")
    XCTAssertEqual(
      DeleteProjectSheetModel.deleteLabel(scope: .fromDisk, workroomCount: 3),
      "Delete Everything to Bin")
  }

  func testSheetEffectFooterPerScope() {
    XCTAssertTrue(
      DeleteProjectSheetModel.effectFooter(scope: .configOnly, workroomCount: 2)
        .contains("Files on disk are kept"))

    // Level-2 is PERMANENT (the recoverability inversion must be explicit) and keeps branches.
    let lvl2 = DeleteProjectSheetModel.effectFooter(scope: .workrooms, workroomCount: 2)
    XCTAssertTrue(lvl2.contains("Permanently removes 2 worktree directories"))
    XCTAssertTrue(lvl2.contains("NOT recoverable"), "the inversion vs from-disk must be explicit")
    XCTAssertTrue(lvl2.contains("Branches are kept"))

    // From-disk moves to the Bin (restorable) and is honest that teardowns still run.
    let disk = DeleteProjectSheetModel.effectFooter(scope: .fromDisk, workroomCount: 2)
    XCTAssertTrue(disk.contains("to the Bin"))
    XCTAssertTrue(disk.lowercased().contains("restorable"))
    XCTAssertTrue(disk.contains("teardown"), "must not oversell recoverability (T2)")

    // No-workroom project: the from-disk copy collapses (no workroom/teardown mention).
    let diskNoWR = DeleteProjectSheetModel.effectFooter(scope: .fromDisk, workroomCount: 0)
    XCTAssertTrue(diskNoWR.contains("to the Bin"))
    XCTAssertFalse(diskNoWR.contains("workroom"))
  }

  // MARK: Investigate warning (issue #146)

  func testInvestigateWarningOnlyWhenLive() {
    XCTAssertNil(DeleteProjectSheetModel.investigateWarning(hasLiveInvestigateSession: false))
    XCTAssertEqual(
      DeleteProjectSheetModel.investigateWarning(hasLiveInvestigateSession: true),
      "⚠️ This project has an active Investigate agent session running — deleting will stop it.")
  }

  // MARK: from-disk trash orchestration (issue #108)

  /// Records trash requests and fails for any URL in `failURLs`, so the from-disk trash
  /// orchestration is asserted without touching the real user Trash.
  private final class FakeTrasher: Trashing {
    private(set) var trashed: [URL] = []
    var failURLs: Set<URL> = []
    struct TrashError: Error {}
    func trash(_ url: URL) throws {
      trashed.append(url)
      if failURLs.contains(url) { throw TrashError() }
    }
  }

  func testTrashToBinMovesEveryPathWhenAllSucceed() {
    let store = makeStore([])
    let fake = FakeTrasher()
    store.trasher = fake
    let urls = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b/c")]

    let failed = store.trashToBin(urls)

    XCTAssertEqual(fake.trashed, urls, "every path must be sent to the Bin, in order")
    XCTAssertTrue(failed.isEmpty, "no failures expected")
  }

  func testTrashToBinAttemptsAllAndReportsTheUnmovable() {
    let store = makeStore([])
    let fake = FakeTrasher()
    let bad = URL(fileURLWithPath: "/locked")
    fake.failURLs = [bad]
    store.trasher = fake
    let urls = [URL(fileURLWithPath: "/ok"), bad, URL(fileURLWithPath: "/ok2")]

    let failed = store.trashToBin(urls)

    XCTAssertEqual(fake.trashed, urls, "all paths attempted even after a failure")
    XCTAssertEqual(failed, [bad], "only the failing path is reported back")
  }

  func testPresentTrashFailureNamesTheLeftoverDirs() {
    let store = makeStore([])
    let p = project("/Users/me/dev/app", workrooms: [])

    store.presentTrashFailure(p, failedPaths: [URL(fileURLWithPath: "/Users/me/dev/app")])

    XCTAssertEqual(store.errorTitle, "Some files of ‘app’ could not be moved to the Bin")
    let message = store.errorMessage ?? ""
    XCTAssertTrue(message.contains("/Users/me/dev/app"), "must name the leftover dir")
    XCTAssertTrue(message.contains("removed from Workroom"), "must clarify the project IS gone")
  }
}
