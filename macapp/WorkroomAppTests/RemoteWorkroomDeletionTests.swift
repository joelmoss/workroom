import XCTest

@testable import Workroom

/// Deleting a remote workroom or a project's base from the app (#253): what is taken down, and
/// what is refused before anything is. The teardown itself runs on the ssh fixture
/// (`RemoteProvisioningIntegrationTests`).
final class RemoteWorkroomDeletionTests: XCTestCase {
  /// What the delete sequence wrote to config, in place of the CLI.
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var all: [String] { lock.withLock { log } }
    func add(_ call: String) { lock.withLock { log.append(call) } }

    var recorder: RemoteWorkrooms.Recorder {
      RemoteWorkrooms.Recorder(
        reserve: { _, _ in
          self.add("reserve")
          return "unused"
        },
        record: { workroom, descriptor in
          self.add("record \(workroom ?? "-") \(descriptor.state ?? "serving")")
        },
        forget: { self.add("forget \($0)") })
    }
  }

  private let mine = RemoteWorkrooms.provisioner

  /// Nothing live, nothing to take down: a destroyed host, or a create that crashed before its
  /// derive made a box, is only dropped, and needs no broker or Docker.
  func testAWorkroomWithNothingLiveIsOnlyForgotten() async throws {
    let calls = Calls()
    try await RemoteWorkrooms.delete(
      "gone", host: HostDescriptor(state: "destroyed", provisioner: mine, id: UUID()),
      environment: nil, recorder: calls.recorder)
    try await RemoteWorkrooms.delete(
      "crashed", host: HostDescriptor(state: "creating", provisioner: mine, workroomID: UUID()),
      environment: nil, recorder: calls.recorder)
    XCTAssertEqual(calls.all, ["forget gone", "forget crashed"])
  }

  /// Another build's host takes another build's key, so this one refuses it and records nothing;
  /// one already destroyed is anyone's to drop.
  func testAnotherBuildsLiveWorkroomIsRefusedBeforeAnythingIsDone() async throws {
    let calls = Calls()
    do {
      try await RemoteWorkrooms.delete(
        "theirs", host: HostDescriptor(provisioner: "another.build", id: UUID(), grantID: "g"),
        environment: nil, recorder: calls.recorder)
      XCTFail("another build's workroom was deleted")
    } catch RemoteWorkrooms.Failure.anotherBuildsHost(let build) {
      XCTAssertEqual(build, "another.build")
    }
    XCTAssertEqual(calls.all, [])

    try await RemoteWorkrooms.delete(
      "theirs", host: HostDescriptor(state: "destroyed", provisioner: "another.build"),
      environment: nil, recorder: calls.recorder)
    XCTAssertEqual(calls.all, ["forget theirs"])
  }

  /// A live host without the environment to take it down (signed out) is refused, not forgotten:
  /// its record is the only one of the box and the grant.
  func testALiveWorkroomIsNeverForgottenWithoutBeingTakenDown() async throws {
    let calls = Calls()
    do {
      try await RemoteWorkrooms.delete(
        "live", host: HostDescriptor(provisioner: mine, id: UUID(), grantID: "g"),
        environment: nil, recorder: calls.recorder)
      XCTFail("a live workroom was forgotten")
    } catch RemoteWorkrooms.Failure.signedOut {}
    XCTAssertEqual(calls.all, [])
  }

  /// The checks the app makes before its optimistic removal: whether anything is live, and
  /// another build's live host refused among several.
  func testDeletabilityIsCheckedAcrossEveryHost() throws {
    XCTAssertFalse(try RemoteWorkrooms.checkDeletable([]))
    XCTAssertFalse(try RemoteWorkrooms.checkDeletable([HostDescriptor(state: "destroyed")]))
    XCTAssertTrue(
      try RemoteWorkrooms.checkDeletable([HostDescriptor(provisioner: mine, grantID: "g")]))
    XCTAssertThrowsError(
      try RemoteWorkrooms.checkDeletable([
        HostDescriptor(provisioner: mine, id: UUID()),
        HostDescriptor(provisioner: nil, id: UUID()),
      ]))
  }

  /// A base with nothing live is only cleared; a live one is never cleared without its box going.
  func testABaseIsClearedOnlyOnceNothingOfItIsLive() async throws {
    let calls = Calls()
    try await RemoteWorkrooms.deleteBase(
      HostDescriptor(state: "destroyed", provisioner: mine, id: UUID()), environment: nil
    ) { calls.add("clear") }
    XCTAssertEqual(calls.all, ["clear"])

    do {
      try await RemoteWorkrooms.deleteBase(
        HostDescriptor(provisioner: mine, id: UUID()), environment: nil
      ) { calls.add("clear") }
      XCTFail("a live base was cleared")
    } catch RemoteWorkrooms.Failure.signedOut {}
    XCTAssertEqual(calls.all, ["clear"])
  }

  /// Removing a workroom from the sidebar keeps its project's base: without it, the next New
  /// Remote Workroom before a reload would build a second base.
  @MainActor
  func testRemovingAWorkroomLocallyKeepsTheProjectsBase() {
    let store = AppStore()
    let base = HostDescriptor(provisioner: mine, id: UUID(), repository: "o/r")
    let workroom = Workroom(
      name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
      host: HostDescriptor(provisioner: mine, id: UUID()))
    let project = Project(path: "/proj", vcs: "git", workrooms: [workroom], host: base)
    store.projects = [project]

    store.removeWorkroomLocally(workroom, in: project)

    XCTAssertEqual(store.projects.first?.workrooms, [])
    XCTAssertEqual(store.projects.first?.host, base)
  }

  /// The CLI, recording each call the delete flows make, in order.
  private final class RecordingCLI: WorkroomCLIProtocol, @unchecked Sendable {
    let calls = Calls()
    /// What config lists: a delete's reload publishes it.
    var listed: [Project] = []
    func list(warnings: String, project: String?) async throws -> ListResponse {
      ListResponse(projects: listed, workroomsDir: nil, configPath: nil)
    }
    func addProject(_ path: String, create: Bool) async throws -> String { path }
    func create(
      project: String, onLog: ((String) -> Void)?, onReady: ((String, String, Bool) -> Void)?
    ) async throws -> CreateResponse { throw WorkroomCLIError.timedOut }
    func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {
      calls.add("delete \(name)")
    }
    func deleteProject(
      _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
    ) async throws -> [URL] {
      calls.add("delete-project")
      return []
    }
    func setHost(project: String, workroom: String?, descriptor: Data?) async throws {
      let state = try descriptor.map { try JSONDecoder().decode(HostDescriptor.self, from: $0) }
      calls.add("host \(workroom ?? "project") \(state.map { $0.state ?? "serving" } ?? "clear")")
    }
  }

  @MainActor
  private func waitFor(
    _ call: String, in cli: RecordingCLI, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !cli.calls.all.contains(call) {
      guard ContinuousClock.now < deadline else {
        return XCTFail("\(call) never came: \(cli.calls.all)", file: file, line: line)
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// A project delete drops its remote entries before the CLI's own, which refuses any: each remote
  /// workroom, then the base, since config keeps a project with a base only while it has one. So
  /// `--from-disk` never hands a path on a remote host to the Bin.
  @MainActor
  func testAProjectDeleteDropsItsRemoteWorkroomsThenItsBaseThenTheProject() async {
    let cli = RecordingCLI()
    let store = AppStore(cli: cli)
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(name: "l", path: "/proj/l", vcsName: "workroom/l", warnings: []),
        Workroom(
          name: "r", path: "/home/workroom/r", vcsName: "workroom/r", warnings: [],
          host: HostDescriptor(state: "destroyed", provisioner: mine, id: UUID())),
      ],
      host: HostDescriptor(state: "destroyed", provisioner: mine, id: UUID()))
    store.projects = [project]

    store.deleteProject(project, scope: .fromDisk)
    await waitFor("delete-project", in: cli)

    XCTAssertEqual(
      cli.calls.all, ["host r destroyed", "delete r", "host project clear", "delete-project"])
    XCTAssertNil(store.errorMessage)
  }

  /// One remote workroom's delete records it destroyed, then has the CLI drop it.
  @MainActor
  func testAWorkroomDeleteDropsADestroyedRemoteWorkroom() async {
    let cli = RecordingCLI()
    let store = AppStore(cli: cli)
    let remote = Workroom(
      name: "r", path: "/home/workroom/r", vcsName: "workroom/r", warnings: [],
      host: HostDescriptor(state: "destroyed", provisioner: mine))
    let project = Project(path: "/proj", vcs: "git", workrooms: [remote])
    store.projects = [project]
    cli.listed = [Project(path: "/proj", vcs: "git", workrooms: [])]

    store.deleteWorkroom(remote, in: project)
    await waitFor("delete r", in: cli)

    XCTAssertEqual(cli.calls.all, ["host r destroyed", "delete r"])
    XCTAssertEqual(store.projects.first?.workrooms, [])
  }

  /// A remote workroom still being created (its project busy with the create) can't be deleted,
  /// so its row offers no Delete; one a crash left at `creating` can.
  @MainActor
  func testARemoteWorkroomIsCreatingOnlyWhileItsProjectIsBusy() {
    let store = AppStore()
    let creating = Workroom(
      name: "c", path: "/home/workroom/r", vcsName: "workroom/c", warnings: [],
      host: HostDescriptor(state: "creating", provisioner: mine, workroomID: UUID()))
    let project = Project(path: "/proj", vcs: "git", workrooms: [creating])
    store.projects = [project]
    XCTAssertFalse(store.isCreatingWorkroom(creating, in: project))

    store.busyProjects["/proj"] = 1
    XCTAssertTrue(store.isCreatingWorkroom(creating, in: project))
    store.deleteWorkroom(creating, in: project)
    XCTAssertEqual(store.projects, [project], "a create still deriving was deleted")
  }

  /// Once a remote create's workroom has a name, its row takes the create's progress and the
  /// project is free for another create; the workroom stays undeletable until the create ends.
  @MainActor
  func testARemoteCreateHandsItsProgressToItsWorkroomOnceNamed() async {
    let cli = RecordingCLI()
    let store = AppStore(cli: cli)
    let creating = Workroom(
      name: "c", path: "/home/workroom/r", vcsName: "workroom/c", warnings: [],
      host: HostDescriptor(state: "creating", provisioner: mine, workroomID: UUID()))
    let project = Project(path: "/proj", vcs: "git", workrooms: [])
    cli.listed = [Project(path: "/proj", vcs: "git", workrooms: [creating])]
    store.projects = [project]
    let row = AppStore.RemoteCreateRow()
    let clone = AppStore.CreateStep(fraction: 0.25, label: "clone")
    let snapshot = AppStore.CreateStep(fraction: 0.5, label: "snapshot")
    let sid = SidebarID.workroom(project: "/proj", name: "c")

    store.busyProjects["/proj"] = 1
    store.showRemoteCreateStep(clone, in: "/proj", row: row)
    XCTAssertEqual(store.createSteps, [.project("/proj"): clone])

    await store.handOffRemoteCreate(named: "c", in: "/proj", to: row)
    XCTAssertEqual(store.createSteps, [sid: clone], "the step moves to the workroom's row")
    XCTAssertTrue(store.canCreateRemoteWorkroom(in: project), "the project is free again")
    XCTAssertEqual(store.projects.first?.workrooms, [creating], "the row is listed")
    XCTAssertTrue(store.isCreatingWorkroom(creating, in: project))

    store.showRemoteCreateStep(snapshot, in: "/proj", row: row)
    XCTAssertEqual(store.createSteps, [sid: snapshot])

    store.endRemoteCreate(in: "/proj", row: row)
    XCTAssertEqual(store.createSteps, [:])
    XCTAssertFalse(store.isCreatingWorkroom(creating, in: project))
    XCTAssertFalse(store.isBusyProject("/proj"))
    store.showRemoteCreateStep(snapshot, in: "/proj", row: row)
    XCTAssertEqual(store.createSteps, [:], "a step after the create ended shows nowhere")
  }

  /// A teardown that fails says what is still up and why, ending in one full stop whether or not
  /// the reason brings its own, not that undoing something failed.
  func testAFailedTeardownSaysWhatIsStillUp() {
    func message(_ cleanup: String) -> String? {
      RemoteProvisioning.Failure.rollbackIncomplete(
        cause: "", host: nil, grantID: "g", cleanup: [cleanup]
      ).errorDescription
    }
    XCTAssertEqual(
      message("cancelling grant g: down"), "Taking it down didn't finish: cancelling grant g: down."
    )
    XCTAssertEqual(
      message("cancelling grant g: Try again in a minute."),
      "Taking it down didn't finish: cancelling grant g: Try again in a minute.")
  }

  /// A later message replaces an earlier error's link as well as its details: the Install button
  /// belongs to the error that offered it.
  @MainActor
  func testANewErrorMessageDropsTheEarlierErrorsLink() throws {
    let store = AppStore()
    store.errorLink = AppStore.ErrorLink(
      title: "Install", url: try XCTUnwrap(URL(string: "https://codaset.dev/install/o")))
    store.errorDetails = "HTTP 409"
    store.errorMessage = "Teardown failed"
    XCTAssertNil(store.errorLink)
    XCTAssertNil(store.errorDetails)
  }

  /// Every scope of a project delete takes its remote hosts down, so the sheet says so whichever
  /// is chosen, and says nothing for a project with none.
  func testTheProjectSheetWarnsOfTheRemoteHostsItDestroys() {
    XCTAssertNil(DeleteProjectSheetModel.remoteWarning(remoteWorkroomCount: 0, hasBase: false))
    XCTAssertEqual(
      DeleteProjectSheetModel.remoteWarning(remoteWorkroomCount: 2, hasBase: true),
      "⚠️ Whichever option you choose, this destroys its 2 remote workrooms and base machine, "
        + "with everything on them that isn't pushed.")
    XCTAssertEqual(
      DeleteProjectSheetModel.remoteWarning(remoteWorkroomCount: 0, hasBase: true),
      "⚠️ Whichever option you choose, this destroys its base machine, with everything on it "
        + "that isn't pushed.")
  }
}
