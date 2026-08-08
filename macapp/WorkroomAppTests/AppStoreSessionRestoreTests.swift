import AppKit
import XCTest

@testable import Workroom

/// Store-level restore behaviour (issue #46): claiming, one-shot application, self-healing against a
/// changed project list, and the `ensureInitialTerminal` race.
///
/// Every test injects a coordinator over a temp file, so none of this reads or writes the developer's
/// real session, and none of it touches a shared `Defaults` key.
@MainActor
final class AppStoreSessionRestoreTests: XCTestCase {
  private var directory: URL!
  private var url: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-store-restore-\(UUID().uuidString)", isDirectory: true)
    url = directory.appendingPathComponent("session.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func project(_ path: String, workrooms: [String] = []) -> Project {
    Project(
      path: path, vcs: "jj",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "jj", warnings: [])
      })
  }

  private func terminal(_ key: String, title: String) -> TabSession {
    TabSession(
      key: key, kind: TabSession.terminalKind,
      terminal: TerminalPayload(defaultTitle: title, cwd: nil))
  }

  private func windowSession(targetID: String, titles: [String]) -> WindowSession {
    WindowSession(
      windowKey: UUID().uuidString, isKey: true, selectedTargetID: targetID,
      targets: [
        TargetSession(
          targetID: targetID,
          tabs: titles.enumerated().map { terminal("t\($0.offset)", title: $0.element) },
          terminalCounter: titles.count)
      ])
  }

  private func makeStore(
    projects: [Project], session: WindowSession?, isLaunchWindow: Bool = true
  ) -> AppStore {
    let projectStore = ProjectStore()
    projectStore.sessionCoordinator = SessionCoordinator(
      store: SessionStore(url: url), debounce: 0.05, ceiling: 0.2, capture: { [] })
    if let session {
      SessionStore(url: url).writeSynchronously(
        SessionFile(savedAt: Date(timeIntervalSince1970: 0), windows: [session]))
    }
    projectStore.projects = projects
    let store = AppStore(projectStore: projectStore)
    store.isRestoreWindow = isLaunchWindow
    // A ⌘N window carries neither flag; the launch window and any restored sibling carry the claim.
    store.claimsSavedSession = isLaunchWindow
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command)
    }
    return store
  }

  // MARK: Claiming

  func testLaunchWindowClaimsTheSavedSessionOnce() {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let store = makeStore(
      projects: projects,
      session: windowSession(targetID: "wr|/p|calm-otter", titles: ["Terminal 1"]))

    store.claimSessionIfNeeded()
    XCTAssertNotNil(store.pendingSessionRestore)
    XCTAssertEqual(store.pendingRestoreSelection, "wr|/p|calm-otter", "the session owns selection")

    // Idempotent: `WindowAccessor` can resolve the same window more than once.
    let claimed = store.pendingSessionRestore
    store.claimSessionIfNeeded()
    XCTAssertEqual(store.pendingSessionRestore?.windowKey, claimed?.windowKey)
  }

  /// Every ⌘N window opens blank, matching how the persisted selection already behaves.
  func testNonLaunchWindowClaimsNothing() {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let store = makeStore(
      projects: projects,
      session: windowSession(targetID: "wr|/p|calm-otter", titles: ["Terminal 1"]),
      isLaunchWindow: false)

    store.claimSessionIfNeeded()
    XCTAssertNil(store.pendingSessionRestore)
  }

  func testWindowKeyIsAdoptedSoTheSlotIsStableAcrossLaunches() throws {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let saved = windowSession(targetID: "wr|/p|calm-otter", titles: ["Terminal 1"])
    let store = makeStore(projects: projects, session: saved)

    store.claimSessionIfNeeded()
    XCTAssertEqual(store.sessionKey.uuidString, saved.windowKey)
  }

  // MARK: Applying

  func testRestoresPanesForResolvableTargets() throws {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let store = makeStore(
      projects: projects,
      session: windowSession(
        targetID: "wr|/p|calm-otter", titles: ["Terminal 1", "Terminal 2"]))

    store.claimSessionIfNeeded()
    store.restorePersistedSessionIfPending(in: projects)

    let target = try XCTUnwrap(
      store.target(for: .workroom(project: "/p", name: "calm-otter")))
    XCTAssertEqual(store.terminals.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 2"])
  }

  /// `apply` runs twice per bootstrap and again on every reload — restoring more than once would
  /// duplicate panes.
  func testRestoreIsOneShot() throws {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let store = makeStore(
      projects: projects,
      session: windowSession(targetID: "wr|/p|calm-otter", titles: ["Terminal 1"]))

    store.claimSessionIfNeeded()
    store.restorePersistedSessionIfPending(in: projects)
    store.restorePersistedSessionIfPending(in: projects)

    let target = try XCTUnwrap(
      store.target(for: .workroom(project: "/p", name: "calm-otter")))
    XCTAssertEqual(store.terminals.tabs(for: target).count, 1)
    XCTAssertNil(store.pendingSessionRestore)
  }

  /// A workroom deleted between launches drops out, exactly as `validatedSelection` and
  /// `pruneWorkroomSplitToLiveLeaves` already self-heal.
  func testEntryForADeletedWorkroomIsDropped() {
    let projects = [project("/p", workrooms: ["still-here"])]
    let store = makeStore(
      projects: projects,
      session: windowSession(targetID: "wr|/p|since-deleted", titles: ["Terminal 1"]))

    store.claimSessionIfNeeded()
    store.restorePersistedSessionIfPending(in: projects)
    XCTAssertTrue(store.terminals.activeTargetIDs.isEmpty)
  }

  // MARK: The ensureInitialTerminal race

  /// **CRITICAL REGRESSION.**
  ///
  /// `WorkroomTerminalsView`'s `.task` calls `ensureInitialTerminal`, which adds a shell when the
  /// target has no tabs. Restoring at the END of `apply` — before any pane can mount — is what makes
  /// that a no-op instead of a stray "Terminal 1" beside the restored panes.
  func testEnsureInitialTerminalAddsNothingAfterRestore() throws {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let store = makeStore(
      projects: projects,
      session: windowSession(
        targetID: "wr|/p|calm-otter", titles: ["Terminal 1", "Terminal 2"]))

    store.claimSessionIfNeeded()
    store.restorePersistedSessionIfPending(in: projects)

    let target = try XCTUnwrap(
      store.target(for: .workroom(project: "/p", name: "calm-otter")))
    store.ensureInitialTerminal(for: target)

    XCTAssertEqual(
      store.terminals.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 2"],
      "no stray terminal may appear beside the restored panes")
  }

  /// With no saved session the old behaviour is untouched: the target opens exactly one shell.
  func testEnsureInitialTerminalStillOpensAShellWithoutASession() throws {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let store = makeStore(projects: projects, session: nil)

    store.claimSessionIfNeeded()
    store.restorePersistedSessionIfPending(in: projects)

    let target = try XCTUnwrap(
      store.target(for: .workroom(project: "/p", name: "calm-otter")))
    store.ensureInitialTerminal(for: target)
    XCTAssertEqual(store.terminals.tabs(for: target).count, 1)
  }

  // MARK: Save gate

  /// Saves stay suspended for the whole restore and resume once it finishes — the gate that stops a
  /// half-restored document being written over a full one.
  func testSavesAreSuspendedAcrossTheRestoreAndResumeAfterIt() {
    let projects = [project("/p", workrooms: ["calm-otter"])]
    let store = makeStore(
      projects: projects,
      session: windowSession(targetID: "wr|/p|calm-otter", titles: ["Terminal 1"]))
    let coordinator = store.projectStore.sessionCoordinator

    store.claimSessionIfNeeded()
    XCTAssertTrue(coordinator.isSuspended, "loading the session suspends saving")

    store.restorePersistedSessionIfPending(in: projects)
    XCTAssertFalse(coordinator.isSuspended, "finishing the restore resumes it")
  }

  /// Nothing to restore must still leave saving enabled — otherwise a fresh install never saves.
  func testNoSessionLeavesSavingEnabled() {
    let store = makeStore(projects: [project("/p")], session: nil)
    store.claimSessionIfNeeded()
    XCTAssertFalse(store.projectStore.sessionCoordinator.isSuspended)
  }

  // MARK: Workroom splits + sidebar expansion

  func testWorkroomSplitAndExpansionAreRestored() throws {
    let projects = [project("/p", workrooms: ["one", "two"])]
    var session = WindowSession(
      windowKey: UUID().uuidString, isKey: true, selectedTargetID: "wr|/p|one",
      targets: [
        TargetSession(targetID: "wr|/p|one", tabs: [terminal("a", title: "Terminal 1")]),
        TargetSession(targetID: "wr|/p|two", tabs: [terminal("b", title: "Terminal 1")]),
      ],
      workroomSplits: [
        .split(
          orientation: LayoutNode<String>.horizontal, ratio: 0.5,
          first: .leaf("wr|/p|one"), second: .leaf("wr|/p|two"))
      ],
      expandedTargets: ["wr|/p|one"])
    session.isKey = true

    let store = makeStore(projects: projects, session: session)
    store.claimSessionIfNeeded()
    store.restorePersistedSessionIfPending(in: projects)

    XCTAssertEqual(store.workroomSplits.count, 1)
    XCTAssertEqual(
      store.workroomSplits.first?.tabIDs,
      [.workroom(project: "/p", name: "one"), .workroom(project: "/p", name: "two")])
    XCTAssertEqual(store.expandedTerminalTargets, ["wr|/p|one"])
  }

  /// A group whose second workroom was deleted is not a group any more.
  func testWorkroomSplitDissolvesWhenALeafIsGone() {
    let projects = [project("/p", workrooms: ["one"])]
    let session = WindowSession(
      windowKey: UUID().uuidString, isKey: true,
      targets: [TargetSession(targetID: "wr|/p|one", tabs: [terminal("a", title: "Terminal 1")])],
      workroomSplits: [
        .split(
          orientation: LayoutNode<String>.horizontal, ratio: 0.5,
          first: .leaf("wr|/p|one"), second: .leaf("wr|/p|since-deleted"))
      ],
      expandedTargets: ["wr|/p|since-deleted"])

    let store = makeStore(projects: projects, session: session)
    store.claimSessionIfNeeded()
    store.restorePersistedSessionIfPending(in: projects)

    XCTAssertTrue(store.workroomSplits.isEmpty)
    XCTAssertTrue(
      store.expandedTerminalTargets.isEmpty,
      "an expand flag pointing at nothing would render an empty disclosure")
  }

  // MARK: Frame clamping

  /// Unplug the display a window was on and a raw restored frame reopens it out of reach.
  func testFrameOffEveryScreenIsRecentredOnThePrimary() throws {
    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let offscreen = NSRect(x: 4000, y: 2200, width: 1200, height: 780)

    let clamped = try XCTUnwrap(
      AppStore.frameOnAVisibleScreen(offscreen, screens: [primary]))
    XCTAssertTrue(primary.intersects(clamped))
    XCTAssertEqual(clamped.width, 1200)
    XCTAssertEqual(clamped.height, 780)
    XCTAssertEqual(clamped.midX, primary.midX, accuracy: 0.5)
  }

  func testFrameStillOnAScreenIsLeftExactlyAsItWas() throws {
    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let secondary = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    let onSecondary = NSRect(x: 1600, y: 100, width: 1200, height: 780)

    XCTAssertEqual(
      AppStore.frameOnAVisibleScreen(onSecondary, screens: [primary, secondary]), onSecondary)
  }

  /// A window barely overlapping a screen edge is not reachable in practice.
  func testBarelyOverlappingFrameIsRecentred() throws {
    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let slither = NSRect(x: 1430, y: 880, width: 1200, height: 780)

    let clamped = try XCTUnwrap(AppStore.frameOnAVisibleScreen(slither, screens: [primary]))
    XCTAssertNotEqual(clamped, slither)
    XCTAssertEqual(clamped.midX, primary.midX, accuracy: 0.5)
  }

  func testDegenerateFrameIsRejected() {
    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    XCTAssertNil(
      AppStore.frameOnAVisibleScreen(NSRect(x: 0, y: 0, width: 10, height: 10), screens: [primary]))
  }

  /// A frame bigger than the only screen is shrunk to fit rather than restored oversized.
  func testOversizedFrameIsShrunkToThePrimaryScreen() throws {
    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let huge = NSRect(x: 9000, y: 9000, width: 5000, height: 4000)

    let clamped = try XCTUnwrap(AppStore.frameOnAVisibleScreen(huge, screens: [primary]))
    XCTAssertEqual(clamped.width, primary.width)
    XCTAssertEqual(clamped.height, primary.height)
  }
}
