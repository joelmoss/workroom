import Foundation
import XCTest

@testable import Workroom

/// A fake CLI that drives `createWorkroom` deterministically (issue #116): it streams optional log
/// lines, fires `onReady` with a controlled name + `hasSetup`, then sleeps briefly to model the
/// workspace/setup work running after the "created" event — so the main-queue `onReady` effects have
/// applied by the time `create` returns, mirroring a real subprocess. `list` returns a project set
/// that already contains the created workroom, so the post-create reload resolves the selection.
private final class CreatingFakeCLI: WorkroomCLIProtocol {
  let projectPath: String
  let workroomName: String
  let hasSetup: Bool
  let logLines: [String]
  let failAfterReady: Bool

  init(
    projectPath: String, workroomName: String, hasSetup: Bool, logLines: [String] = [],
    failAfterReady: Bool = false
  ) {
    self.projectPath = projectPath
    self.workroomName = workroomName
    self.hasSetup = hasSetup
    self.logLines = logLines
    self.failAfterReady = failAfterReady
  }

  private var workroomAbsPath: String { "\(projectPath)/.workrooms/\(workroomName)" }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    let workroom = Workroom(
      name: workroomName, path: workroomAbsPath, vcsName: "git", warnings: [])
    return ListResponse(
      projects: [Project(path: projectPath, vcs: "git", workrooms: [workroom])],
      workroomsDir: nil, configPath: nil)
  }

  func addProject(_ path: String, create: Bool) async throws -> String { projectPath }

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    for line in logLines { onLog?(line) }
    onReady?(workroomName, workroomAbsPath, hasSetup)
    // Let the main-queue onReady work (name/target/hasSetup + mount) settle before returning.
    try? await Task.sleep(nanoseconds: 40_000_000)
    if failAfterReady { throw WorkroomCLIError.timedOut }
    return CreateResponse(
      name: workroomName, path: workroomAbsPath, vcs: "git", project: project)
  }

  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}

@MainActor
final class AppStoreCreateWorkroomTests: XCTestCase {
  private let projectPath = "/private/var/tmp/wr-create-project"

  private func makeStore(_ fake: WorkroomCLIProtocol) -> AppStore {
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    return store
  }

  private func project(withWorkroom name: String) -> Project {
    Project(
      path: projectPath, vcs: "git",
      workrooms: [
        Workroom(
          name: name, path: "\(projectPath)/.workrooms/\(name)", vcsName: "git", warnings: [])
      ])
  }

  // MARK: - Async create flow

  /// With NO setup script there's no dialog — just the loader — and the create clears itself when it
  /// completes: `creation` ends nil and the new workroom is selected so its terminal drops in (#116).
  func testNoSetupCreateClearsAndSelects() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "calm-otter", hasSetup: false)
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    XCTAssertNil(store.creation, "a no-setup create must clear itself when done")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "calm-otter"))
    XCTAssertFalse(store.isCreationFocused)
    XCTAssertTrue(store.creatingWorkrooms.isEmpty, "the create guard lifts when done (issue #116)")
  }

  /// With a setup script the dialog stays up (blocking) after creation completes — the terminal is
  /// withheld until the user dismisses it — and the new workroom's slot is the focused detail (#116).
  func testSetupCreateKeepsDialogBlocking() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "brave-fox", hasSetup: true,
      logLines: ["installing deps", "done"])
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "brave-fox")
    XCTAssertNotNil(store.creation, "a setup create must keep the dialog up until dismissed")
    XCTAssertEqual(store.creation?.hasSetup, true)
    XCTAssertEqual(store.creation?.targetID, wrID)
    XCTAssertTrue(store.isCreationBlocking(wrID), "the terminal must stay withheld during setup")
    XCTAssertTrue(store.isCreationFocused, "the new workroom's slot owns the detail")
    XCTAssertEqual(store.selectedTargetID, .workroom(project: projectPath, name: "brave-fox"))
    XCTAssertEqual(store.creation?.session.isFinished, true)
    XCTAssertNil(store.creation?.session.failureMessage)
    XCTAssertTrue(
      store.creatingWorkrooms.isEmpty, "setup finished → the workroom is deletable again (#116)")

    // Dismissing clears the dialog (which lets the withheld terminal mount).
    store.dismissCreation()
    XCTAssertNil(store.creation)
    XCTAssertFalse(store.isCreationBlocking(wrID))
    XCTAssertFalse(store.isCreationFocused)
  }

  /// A setup failure keeps the dialog up as a blocking failure (with its message) so the user sees
  /// why — `hasSetup` is forced true even if the failure preceded the setup flag being read.
  func testSetupFailureKeepsDialogWithMessage() async {
    let fake = CreatingFakeCLI(
      projectPath: projectPath, workroomName: "lost-cat", hasSetup: true, logLines: ["boom"],
      failAfterReady: true)
    let store = makeStore(fake)

    await store.createWorkroom(in: Project(path: projectPath, vcs: "git", workrooms: []))

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "lost-cat")
    XCTAssertNotNil(store.creation, "a failed setup must keep the dialog up")
    XCTAssertEqual(store.creation?.hasSetup, true)
    XCTAssertTrue(store.isCreationBlocking(wrID))
    XCTAssertNotNil(
      store.creation?.session.failureMessage, "the failure must be shown in the dialog")
  }

  // MARK: - Synchronous state semantics

  /// `isCreationBlocking` is true only for the in-progress creation's target AND only when a setup
  /// script is running — a no-setup create never withholds the terminal.
  func testIsCreationBlockingSemantics() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "wr")
    let session = ScriptLogSession(title: "t", phase: "setup")
    let proj = Project(path: projectPath, vcs: "git", workrooms: [])

    XCTAssertFalse(store.isCreationBlocking(wrID), "no creation → never blocking")

    store.creation = WorkroomCreation(
      session: session, project: proj, name: "wr", targetID: wrID, hasSetup: false)
    XCTAssertFalse(store.isCreationBlocking(wrID), "a no-setup create never blocks")

    store.creation = WorkroomCreation(
      session: session, project: proj, name: "wr", targetID: wrID, hasSetup: true)
    XCTAssertTrue(store.isCreationBlocking(wrID))
    XCTAssertFalse(
      store.isCreationBlocking(TerminalTarget.workroomID(project: projectPath, name: "other")),
      "only the creation's own target is withheld")
  }

  /// `isCreationFocused` owns the detail unconditionally pre-name (the loader phase), then follows
  /// selection once named so a setup script blocks ONLY the new workroom — selecting another workroom
  /// un-focuses it and reveals that workroom while the create keeps running (issue #116).
  func testIsCreationFocusedFollowsSelection() {
    let store = makeStore(FakeWorkroomCLI(canonical: projectPath, projects: []))
    let session = ScriptLogSession(title: "t", phase: "setup")
    let proj = Project(path: projectPath, vcs: "git", workrooms: [])

    // Pre-name: the loader owns the detail regardless of any prior selection.
    store.creation = WorkroomCreation(session: session, project: proj)
    store.selectedTargetID = .root(project: projectPath)
    XCTAssertTrue(store.isCreationFocused, "pre-name the loader owns the detail")

    // Named: focused only when the new workroom's own tab is selected.
    let wrID = TerminalTarget.workroomID(project: projectPath, name: "wr")
    store.creation = WorkroomCreation(
      session: session, project: proj, name: "wr", targetID: wrID, hasSetup: true)
    store.selectedTargetID = .root(project: projectPath)
    XCTAssertFalse(store.isCreationFocused, "another workroom stays visible while setup runs")
    store.selectedTargetID = .workroom(project: projectPath, name: "wr")
    XCTAssertTrue(store.isCreationFocused)
  }

  /// The in-progress creation's target shows as a workroom tab even before its terminal exists — so
  /// the chip is present through setup (issue #116) — and disappears once the dialog is dismissed.
  func testCreationTargetAppearsAsTab() async {
    let fake = FakeWorkroomCLI(canonical: projectPath, projects: [project(withWorkroom: "tab-wr")])
    let store = makeStore(fake)
    await store.reload()  // land the workroom in `projects` so its target resolves

    let wrID = TerminalTarget.workroomID(project: projectPath, name: "tab-wr")
    XCTAssertFalse(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "no tab before creation (the workroom has no live terminal)")

    store.creation = WorkroomCreation(
      session: ScriptLogSession(title: "t", phase: "setup"),
      project: project(withWorkroom: "tab-wr"), name: "tab-wr", targetID: wrID, hasSetup: true)
    XCTAssertTrue(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "the creation target must show as a tab during setup")

    store.dismissCreation()
    XCTAssertFalse(
      store.orderedWorkroomTargets().contains { $0.target.id == wrID },
      "the tab falls back to terminal-presence once the dialog is dismissed")
  }
}
