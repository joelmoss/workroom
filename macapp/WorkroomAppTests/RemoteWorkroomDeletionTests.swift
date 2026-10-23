import DaemonConnection
import HostDrivers
import WorkroomDomain
import WorkroomVCS
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
  /// driver made a box, is only dropped, and needs no provider or Docker.
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
        "theirs", host: HostDescriptor(provisioner: "another.build", id: UUID()),
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

  /// A live host without the environment to take it down is refused, not forgotten: its record is
  /// the only one of the box.
  func testALiveWorkroomIsNeverForgottenWithoutBeingTakenDown() async throws {
    let calls = Calls()
    do {
      try await RemoteWorkrooms.delete(
        "live", host: HostDescriptor(provisioner: mine, id: UUID()),
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
      try RemoteWorkrooms.checkDeletable([HostDescriptor(provisioner: mine, id: UUID())]))
    XCTAssertFalse(
      try RemoteWorkrooms.checkDeletable([HostDescriptor(provisioner: mine, workroomID: UUID())]),
      "a create that crashed before its box is live")
    XCTAssertThrowsError(
      try RemoteWorkrooms.checkDeletable([
        HostDescriptor(provisioner: mine, id: UUID()),
        HostDescriptor(provisioner: nil, id: UUID()),
      ]))
  }

  /// Removing a workroom from the sidebar keeps its project's base record, so the launch that
  /// retires older builds' bases (`BaseRetirement`) still finds it.
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
    /// What the next `deleteProject` throws, once, after it is recorded.
    var deleteProjectError: Error?
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
      if let error = deleteProjectError {
        deleteProjectError = nil
        throw error
      }
      return []
    }
    func setHost(project: String, workroom: String?, descriptor: Data?) async throws {
      let state = try descriptor.map { try JSONDecoder().decode(HostDescriptor.self, from: $0) }
      calls.add("host \(workroom ?? "project") \(state.map { $0.state ?? "serving" } ?? "clear")")
    }
    func claimProvisioned(from shared: String, provisioner: String) async throws {
      calls.add("claim \(shared) \(provisioner)")
    }
  }

  /// Every Dev build keeps its own config, a workroom's included; Release and Nightly share the
  /// CLI's own.
  func testOnlyDevBuildsKeepTheirOwnConfig() {
    XCTAssertNil(WorkroomCLI.configPath(bundleID: "com.developwithstyle.workroom"))
    XCTAssertNil(WorkroomCLI.configPath(bundleID: "com.developwithstyle.workroom.nightly"))
    XCTAssertNil(WorkroomCLI.configPath(bundleID: "com.developwithstyle.workroom.develop"))
    XCTAssertNil(WorkroomCLI.configPath(bundleID: nil))
    for id in ["com.developwithstyle.workroom.dev", "com.developwithstyle.workroom.dev.wr-a-1"] {
      XCTAssertEqual(
        WorkroomCLI.configPath(bundleID: id).map {
          URL(fileURLWithPath: $0).pathComponents.suffix(3)
        },
        ["Workroom", id, "config.json"])
    }
  }

  /// A Dev build takes what it made out of the shared config once a launch, and never from a
  /// test process or a Release or Nightly build. The once is per process, so this is the only test
  /// that may call `claimProvisionedOnce` with `isTestProcess: false`.
  @MainActor
  func testADevBuildClaimsItsEntriesOnceALaunch() async {
    let cli = RecordingCLI()
    let dev = "com.developwithstyle.workroom.dev"
    await AppStore.claimProvisionedOnce(cli, bundleID: dev, isTestProcess: true)
    await AppStore.claimProvisionedOnce(
      cli, bundleID: "com.developwithstyle.workroom.nightly", isTestProcess: false)
    XCTAssertEqual(cli.calls.all, [])
    await AppStore.claimProvisionedOnce(cli, bundleID: dev, isTestProcess: false)
    await AppStore.claimProvisionedOnce(cli, bundleID: dev, isTestProcess: false)
    XCTAssertEqual(cli.calls.all, ["claim \(WorkroomCLI.sharedConfigPath) \(dev)"])
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

  /// Value: protects=C4, Delete Anyway on a project delete re-runs it as the project is now: a remote
  /// workroom taken down before the failure is not taken down again; fails_when=the retry reuses the
  /// project as it was when the delete began; no_claim=a live remote host's teardown (needs a driver)
  @MainActor
  func testDeleteAnywayAfterAProjectDeleteDoesNotRedoAGoneRemoteWorkroom() async throws {
    let cli = RecordingCLI()
    let store = AppStore(cli: cli)
    let local = Workroom(name: "l", path: "/proj/l", vcsName: "workroom/l", warnings: [])
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        local,
        Workroom(
          name: "r", path: "/home/workroom/r", vcsName: "workroom/r", warnings: [],
          host: HostDescriptor(state: "destroyed", provisioner: mine, id: UUID())),
      ])
    store.projects = [project]
    // The CLI's teardown fails after the remote workroom went; the reload no longer lists it.
    cli.deleteProjectError = WorkroomCLIError.cli(
      kind: "TeardownScriptFailed", message: "teardown script failed")
    cli.listed = [Project(path: "/proj", vcs: "git", workrooms: [local])]

    store.deleteProject(project, scope: .workrooms)
    let deadline = ContinuousClock.now + .seconds(10)
    while store.errorAction == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let action = try XCTUnwrap(store.errorAction, "no Delete Anyway was offered")
    store.clearError()
    action.run()
    while cli.calls.all.filter({ $0 == "delete-project" }).count < 2, ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(5))
    }

    XCTAssertEqual(
      cli.calls.all, ["host r destroyed", "delete r", "delete-project", "delete-project"])
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

  /// A remote workroom still being created (a create running in its project) can't be deleted,
  /// so its row offers no Delete; one a crash left at `creating` can. Ported (#483): the running
  /// create is its run, not a busy project.
  /// Value: protects=a `creating` record is undeletable while its create runs and deletable after
  /// a crash; fails_when=the run isn't consulted; no_claim=none beyond protects
  @MainActor
  func testARemoteWorkroomIsCreatingOnlyWhileItsProjectIsBusy() {
    let store = AppStore()
    let creating = Workroom(
      name: "c", path: "/home/workroom/r", vcsName: "workroom/c", warnings: [],
      host: HostDescriptor(state: "creating", provisioner: mine, workroomID: UUID()))
    let project = Project(path: "/proj", vcs: "git", workrooms: [creating])
    store.projects = [project]
    XCTAssertFalse(store.isCreatingWorkroom(creating, in: project))

    store.register(
      CreationRun(project: project, kind: .boxd, splitAnchor: nil, previousSelection: nil))
    XCTAssertTrue(store.isCreatingWorkroom(creating, in: project))
    store.deleteWorkroom(creating, in: project)
    XCTAssertEqual(store.projects, [project], "a create still deriving was deleted")
  }

  /// A teardown that fails says what is still up and why, ending in one full stop whether or not
  /// the reason brings its own, not that undoing something failed.
  func testAFailedTeardownSaysWhatIsStillUp() {
    func message(_ cleanup: String) -> String? {
      RemoteProvisioning.Failure.rollbackIncomplete(
        cause: "", host: .remote(UUID()), cleanup: [cleanup]
      )
      .errorDescription
    }
    XCTAssertEqual(
      message("destroying the instance: down"),
      "Taking it down didn't finish: destroying the instance: down.")
    XCTAssertEqual(
      message("destroying the instance: Try again in a minute."),
      "Taking it down didn't finish: destroying the instance: Try again in a minute.")
  }

  /// A later message replaces an earlier error's details: its codes belong to the error that
  /// set them.
  @MainActor
  func testANewErrorMessageDropsTheEarlierErrorsDetails() {
    let store = AppStore()
    store.errorDetails = "HTTP 409"
    store.errorMessage = "Teardown failed"
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

/// A remote workroom's teardown script, run on its host before the host goes
/// (`docs/designs/scripts-on-every-workroom.md`: D3, R1).
final class RemoteTeardownTests: XCTestCase {
  private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var all: [String] { lock.withLock { entries } }
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
  }

  private final class Driver: HostTerminalDriver, @unchecked Sendable {
    let log: Log
    init(_ log: Log) { self.log = log }
    var daemonSocket: String { "/home/boxd/.workroom/workroomd.sock" }
    func create() async throws -> HostID { .remote(UUID()) }
    func destroy(_ host: HostID) async throws { log.add("destroy") }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      log.add("exec")
      throw HostDriverError.provisioning("no exec")
    }
    func attachCommand(
      to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
      metadata: [(key: String, value: String)], runCommand: String?
    ) throws -> String { "" }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool { false }
    func lastAttach(of session: UUID, on host: HostID) -> LastAttach { .finished }
  }

  private func recorder(_ log: Log) -> RemoteWorkrooms.Recorder {
    RemoteWorkrooms.Recorder(
      reserve: { _, _ in "unused" },
      record: { _, descriptor in log.add("record \(descriptor.state ?? "serving")") },
      forget: { log.add("forget \($0)") })
  }

  private func host(state: String? = nil) -> HostDescriptor {
    HostDescriptor(
      state: state, driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
      id: UUID())
  }

  private func teardown(
    _ log: Log, skip: Bool = false, result: RemoteProvisioning.ScriptRun
  ) -> RemoteWorkrooms.Teardown {
    var teardown = RemoteWorkrooms.Teardown(
      path: "/home/boxd/r", rootScript: nil, skip: skip, judge: RemoteScriptTests.approveAll,
      onLine: { _ in })
    teardown.run = { request in
      log.add("script \(request.script.rawValue) \(request.workroom) \(request.path)")
      return result
    }
    return teardown
  }

  private func delete(
    _ host: HostDescriptor, _ log: Log, teardown: RemoteWorkrooms.Teardown
  ) async throws {
    let driver = Driver(log)
    try await RemoteWorkrooms.delete(
      "w", host: host,
      environment: RemoteProvisioning.Environment(
        driver: driver, daemonSocket: driver.daemonSocket),
      recorder: recorder(log), teardown: teardown)
  }

  /// Value: protects=the teardown runs, in the checkout, before the host is destroyed and the
  /// record forgotten; fails_when=it runs after, or not at all; no_claim=a real host
  /// (RemoteScriptTests runs the daemon)
  func testTheTeardownRunsBeforeTheHostGoes() async throws {
    let log = Log()
    try await delete(host(), log, teardown: teardown(log, result: .passed))
    XCTAssertEqual(log.all, ["script teardown w /home/boxd/r", "destroy", "forget w"])
  }

  /// Value: protects=D3, a failed teardown stops the delete with nothing taken down and its reason
  /// kept, so deleting again retries; fails_when=the host is destroyed or the record changed;
  /// no_claim=none beyond protects
  func testAFailedTeardownTakesNothingDown() async throws {
    let log = Log()
    let why =
      "teardown script failed: /home/boxd/r/scripts/workroom_teardown returned a non-zero exit code"
    do {
      try await delete(host(), log, teardown: teardown(log, result: .failed(why)))
      XCTFail("a failed teardown let the delete go on")
    } catch RemoteWorkrooms.Failure.teardownScriptFailed(let reason) {
      XCTAssertEqual(reason, why)
    }
    XCTAssertEqual(log.all, ["script teardown w /home/boxd/r"])
  }

  /// Value: protects=#363, a teardown this Mac has not approved stops the delete with nothing taken
  /// down, carrying the script for the sheet to show; fails_when=the host goes anyway, or the
  /// script is lost; no_claim=the judgement on the host (RemoteScriptTests)
  func testAnUnapprovedTeardownTakesNothingDown() async throws {
    let log = Log()
    let script = RemoteScriptTests.judged(Data("#!/bin/sh\n".utf8), trusted: false)
    do {
      try await delete(host(), log, teardown: teardown(log, result: .notTrusted(script)))
      XCTFail("an unapproved teardown let the delete go on")
    } catch RemoteWorkrooms.Failure.teardownScriptNotTrusted(let refused) {
      XCTAssertEqual(refused, script)
    }
    XCTAssertEqual(log.all, ["script teardown w /home/boxd/r"])
  }

  /// Value: protects=Delete Anyway destroys the host without running the script; fails_when=the
  /// script runs again or the host stays; no_claim=none beyond protects
  func testDeleteAnywaySkipsTheScript() async throws {
    let log = Log()
    try await delete(host(), log, teardown: teardown(log, skip: true, result: .failed("no")))
    XCTAssertEqual(log.all, ["destroy", "forget w"])
  }

  /// Value: protects=a host a create left `creating` or a delete left `failed` is taken down
  /// without its script, since it may not be whole; fails_when=the script runs there and blocks
  /// the cleanup; no_claim=none beyond protects
  func testAHalfMadeHostSkipsTheScript() async throws {
    let log = Log()
    try await delete(host(state: "failed"), log, teardown: teardown(log, result: .failed("no")))
    XCTAssertEqual(log.all, ["destroy", "forget w"])
  }

  /// Value: protects=R6, which failures offer Delete Anyway: a local or remote teardown failure and
  /// a timed-out delete do, a failure elsewhere doesn't; fails_when=a case is dropped from or added
  /// to `isTeardownFailure`, leaving a failed remote teardown with no way out; no_claim=the sheet
  /// showing the button (AppStoreDeleteRaceTests drive that for the local cases)
  func testWhichFailuresOfferDeleteAnyway() {
    XCTAssertTrue(
      AppStore.isTeardownFailure(
        WorkroomCLIError.cli(kind: "TeardownScriptFailed", message: "teardown script failed")))
    XCTAssertTrue(AppStore.isTeardownFailure(WorkroomCLIError.timedOut))
    XCTAssertTrue(
      AppStore.isTeardownFailure(
        RemoteWorkrooms.Failure.teardownScriptFailed("teardown script failed: no route")))
    let script = RemoteScriptTests.judged(Data(), trusted: false)
    XCTAssertTrue(
      AppStore.isTeardownFailure(WorkroomCLIError.scriptNotTrusted(script, message: "not trusted")))
    XCTAssertTrue(
      AppStore.isTeardownFailure(RemoteWorkrooms.Failure.teardownScriptNotTrusted(script)))
    // A teardown Workroom won't read (a device, over 1 MiB) comes without its script.
    XCTAssertTrue(
      AppStore.isTeardownFailure(
        WorkroomCLIError.cli(kind: "ScriptNotTrusted", message: "not a regular file")))
    XCTAssertFalse(
      AppStore.isTeardownFailure(WorkroomCLIError.cli(kind: "VCSCommandFailed", message: "git")))
    XCTAssertFalse(AppStore.isTeardownFailure(RemoteWorkrooms.Failure.signedOut))
  }

  /// Value: protects=a remote delete's teardown carries the workroom's checkout, the root's copy
  /// and Delete Anyway's skip; fails_when=`remoteTeardown` drops the skip (Delete Anyway re-runs the
  /// failing script) or points at the wrong script; no_claim=the delete itself (tests above)
  func testARemoteDeletesTeardownCarriesItsSkip() {
    let workroom = Workroom(
      name: "r", path: "/home/workroom/r", vcsName: "workroom/r", warnings: [],
      host: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID()))
    let project = Project(path: "/proj", vcs: "git", workrooms: [workroom])
    for skip in [false, true] {
      let teardown = AppStore.remoteTeardown(
        of: workroom, in: project, log: nil, skip: skip, cli: WorkroomCLI.shared)
      XCTAssertEqual(teardown.skip, skip)
      XCTAssertEqual(teardown.path, "/home/workroom/r")
      XCTAssertEqual(teardown.rootScript?.path, "/proj/scripts/workroom_teardown")
    }
  }

  /// Value: protects=a descriptor from before the `driver` field (Docker's) still runs its
  /// teardown, as its host's delete still finds Docker; fails_when=the script fails as an unknown
  /// driver; no_claim=none beyond protects
  func testADescriptorWithNoDriverRunsItsTeardownAsDockers() async throws {
    let log = Log()
    let legacy = HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID())
    var teardown = teardown(log, result: .passed)
    let run = teardown.run
    teardown.run = { request in
      log.add("key \(request.key == RemoteHosts.DriverKey() ? "docker" : "other")")
      return await run(request)
    }
    try await delete(legacy, log, teardown: teardown)
    XCTAssertEqual(
      log.all, ["key docker", "script teardown w /home/boxd/r", "destroy", "forget w"])
  }

  /// Value: protects=R1, the script connects through the app's `ensureConnected` (which joins a
  /// connect under way, replaces an older daemon and puts a relayed host's credentials up) before
  /// anything runs, and a failed connect is a failed script; fails_when=the script runs without
  /// connecting, or a failed connect passes; no_claim=the join, bootstrap and relay themselves
  /// (RemoteHostsTests and DaemonBootstrap's tests)
  func testTheScriptConnectsFirstAndAFailedConnectIsAFailure() async {
    let log = Log()
    let driver = Driver(log)
    let hosts = RemoteHosts(
      connectHost: { _ in
        log.add("connect")
        throw HostDriverError.provisioning("no route to host")
      }, startHost: { _ in })
    let boxd = RemoteHosts.DriverKey.boxd(org: nil, account: nil)
    let result = await RemoteWorkrooms.runScript(
      RemoteWorkrooms.ScriptRequest(
        script: .teardown, workroom: "w", path: "/home/boxd/r", host: .remote(UUID()),
        key: boxd, driver: driver, daemonBinary: "/workroomd", rootScript: nil,
        judge: RemoteScriptTests.approveAll, onLine: { _ in }),
      hosts: hosts)
    guard case .failed(let why) = result else { return XCTFail("a failed connect passed") }
    XCTAssertEqual(why, "teardown script failed: couldn't reach the host")
    XCTAssertEqual(log.all, ["connect"], "the script ran without a connection")
  }

  /// Value: protects=R1, a stopped container (every Apple one after a reboot) is started before its
  /// script, as opening its workroom starts it, so a delete from the context menu runs the
  /// teardown; fails_when=the script connects to the host without starting it; no_claim=the start
  /// itself (ContainerHostDriver's tests)
  func testTheScriptStartsAStoppedHostFirst() async {
    let log = Log()
    let hosts = RemoteHosts(
      connectHost: { _ in
        log.add("connect")
        throw HostDriverError.provisioning("no route to host")
      }, startHost: { _ in log.add("start") })
    let docker = RemoteHosts.DriverKey.container(.docker, context: nil)
    _ = await RemoteWorkrooms.runScript(
      RemoteWorkrooms.ScriptRequest(
        script: .teardown, workroom: "w", path: "/r", host: .remote(UUID()),
        key: docker, driver: Driver(log), daemonBinary: "/workroomd",
        rootScript: nil, judge: RemoteScriptTests.approveAll, onLine: { _ in }),
      hosts: hosts)
    XCTAssertEqual(log.all, ["start", "connect"])
  }
}
