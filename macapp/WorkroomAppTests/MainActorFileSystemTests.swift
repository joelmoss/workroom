import Foundation
import WorkroomDomain
import XCTest

@testable import Workroom

/// The file-system checks `check-main-actor-fs.py` once let through as unfixed (`docs/macapp-perf-
/// facts.md`): each runs off the main actor under a timeout, so a stat stuck on a stalled mount
/// leaves every window responsive and falls back as a missing path does. Each stuck stat waits on
/// a gate with a bound of its own, so a regression that stats on the main actor fails rather than
/// hangs the suite, and every stuck path is unique, so its late result reaches no other test.
@MainActor
final class MainActorFileSystemTests: XCTestCase {
  private var gate: DispatchSemaphore!
  private var scratch: URL!

  override func setUp() async throws {
    try await super.setUp()
    gate = DispatchSemaphore(value: 0)
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("main-actor-fs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    // Lets the stuck reads go, so no GCD thread outlives the test for long.
    for _ in 0..<8 { gate.signal() }
    try? FileManager.default.removeItem(at: scratch)
    try await super.tearDown()
  }

  /// A stat stuck until the test ends, or 10 s at most.
  private func stuck<T>(_ value: T) -> @Sendable () -> T where T: Sendable {
    let gate = gate!
    return {
      _ = gate.wait(timeout: .now() + 10)
      return value
    }
  }

  /// `work`'s result, failing when the main actor stalls while it runs: a main-actor hop the test
  /// makes meanwhile must land at once, not when the stuck stat lets go.
  private func whileMainActorStaysFree<T: Sendable>(
    _ work: @escaping @MainActor () async -> T, file: StaticString = #filePath, line: UInt = #line
  ) async -> T {
    let task = Task { @MainActor in await work() }
    let started = ContinuousClock.now
    try? await Task.sleep(for: .milliseconds(200))
    let woke = ContinuousClock.now - started
    XCTAssertLessThan(
      woke, .seconds(3), "the main actor stalled \(woke) behind a stuck stat", file: file,
      line: line)
    return await task.value
  }

  // MARK: Quick Terminal's folder

  /// Value: protects=a new terminal picking its folder never stats it on the main actor, and an
  /// unreachable "New terminals open in" opens the home folder, as a missing one does;
  /// fails_when=workingDirectory(for:) stats synchronously, or a timed-out check keeps the folder;
  /// why_new=check-main-actor-fs grandfathered entry; seam=FolderPresence with a stuck stat;
  /// no_claim=the Settings picker
  func testAStuckFolderNeverStallsANewTerminalAndOpensHome() async {
    let path = scratch.appendingPathComponent("stalled").path
    let presence = FolderPresence(timeout: 0.5, stat: { [stat = stuck(true)] _ in stat() })

    let started = ContinuousClock.now
    XCTAssertEqual(
      QuickTerminalController.workingDirectory(for: path, presence: presence), path,
      "not checked yet: taken as there while its check runs")
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "read without the disk")

    let checked = await whileMainActorStaysFree {
      await QuickTerminalController.checkedWorkingDirectory(for: path, presence: presence)
    }
    XCTAssertEqual(checked, NSHomeDirectory(), "unreachable opens home")
    XCTAssertEqual(
      QuickTerminalController.workingDirectory(for: path, presence: presence), NSHomeDirectory(),
      "a new tab then opens home too")
  }

  // MARK: Quick Terminal restore

  private func makeQuickTerminal() -> QuickTerminalController {
    let controller = QuickTerminalController()
    controller.section = TerminalsSection()
    controller.makeSurface = {
      GhosttySurfaceView(workingDirectory: $0, command: $1, spawnsSurface: false)
    }
    let service = PersistentSessionService(
      probe: { _ in .notBundled }, ownership: { _ in .notOwned })
    _ = service.backend
    controller.sessionServiceOverride = service
    controller.hidesWhenUnfocused = { false }
    return controller
  }

  private var savedPanel: TargetSession {
    TargetSession(
      targetID: TargetID.quickTerminal.encoded,
      tabs: [
        TabSession(
          key: "a", kind: TabSession.terminalKind,
          terminal: TerminalPayload(defaultTitle: "Terminal 1", sessionID: UUID().uuidString))
      ])
  }

  /// `restore` over `controller`, with what its recovery was told about reattaching.
  private func restore(_ controller: QuickTerminalController) async -> Bool? {
    let told = Told()
    controller.recoverSessions = { _, predicate in told.reattaches = predicate(.quickTerminal) }
    let saved = savedPanel
    await controller.restore(saved)
    return told.reattaches
  }

  private final class Told {
    var reattaches: Bool?
  }

  /// Value: protects=a stalled mount under the panel's folder never freezing launch, and its
  /// restored panes starting fresh rather than reattaching; fails_when=restore stats the folder on
  /// the main actor (the recovery predicate did), or a timeout reattaches; why_new=check-main-
  /// actor-fs grandfathered entry; seam=restoreStat; no_claim=the folder chosen (above)
  func testAStuckPanelFolderNeverStallsItsRestore() async throws {
    let controller = makeQuickTerminal()
    defer { controller.close() }
    controller.restoreStatTimeout = 0.5
    controller.restoreStat = { [stat = stuck(true)] _ in stat() }

    let reattaches = await whileMainActorStaysFree { await self.restore(controller) }

    XCTAssertEqual(reattaches, false, "an unreachable folder doesn't reattach")
    let host = try XCTUnwrap(controller.host)
    XCTAssertEqual(host.terminals.allTabs(for: host.target).count, 1, "its panes come back")
  }

  /// The healthy path: the panel's folder (home, unless set) is there, so its panes reattach.
  func testAPanelWhoseFolderIsThereReattaches() async {
    let controller = makeQuickTerminal()
    defer { controller.close() }
    let reattaches = await restore(controller)
    XCTAssertEqual(reattaches, true)
  }

  // MARK: Saved-layout recovery

  private func storeWithATab() throws -> (AppStore, TerminalTarget.ID) {
    let store = AppStore()
    store.projectStore.projects = [Project(path: scratch.path, vcs: "git", workrooms: [])]
    let id = TargetID.root(project: scratch.path)
    _ = store.terminals.addTab(for: try XCTUnwrap(store.terminalTarget(forID: id)), focus: false)
    return (store, id)
  }

  /// Value: protects=session recovery never statting a restored target's folder on the main
  /// actor, and a target on a stalled mount starting fresh shells; fails_when=reattachesLocally
  /// stats synchronously (once per tab, three times), or a timeout reattaches; why_new=check-main-
  /// actor-fs grandfathered entry; seam=AppStore.reattachStat; no_claim=a live helper
  func testAStuckTargetFolderNeverStallsRecovery() async throws {
    let (store, id) = try storeWithATab()
    store.reattachStatTimeout = 0.5
    store.reattachStat = { [stat = stuck(true)] _ in stat() }

    let present = await whileMainActorStaysFree { await store.presentTargetPaths() }

    XCTAssertEqual(present, [])
    XCTAssertFalse(store.reattachesLocally(id, present: present))
  }

  /// The healthy path: a held local target whose folder is there reattaches, one that is gone
  /// doesn't.
  func testAHeldTargetWhoseFolderIsThereReattaches() async throws {
    let (store, id) = try storeWithATab()
    let present = await store.presentTargetPaths()
    XCTAssertEqual(present, [scratch.path])
    XCTAssertTrue(store.reattachesLocally(id, present: present))

    try FileManager.default.removeItem(at: scratch)
    let after = await store.presentTargetPaths()
    XCTAssertFalse(store.reattachesLocally(id, present: after), "gone")
  }

  // MARK: Install Command Line Tool

  /// Value: protects=the Install Command menu item never statting /usr/local/bin on the main
  /// actor; fails_when=status() is synchronous again; why_new=check-main-actor-fs grandfathered
  /// entry; seam=status(read:); no_claim=the install itself, which runs detached
  func testAStuckCommandStatusNeverStallsTheMenu() async {
    let path = scratch.appendingPathComponent("workroom").path
    let read = stuck(CommandLineInstaller.Status.installed)

    let status = await whileMainActorStaysFree {
      await CommandLineInstaller.status(at: path, timeout: 0.5, read: read)
    }

    XCTAssertNil(status, "unknown in time, so the menu installs (relinking changes nothing)")
  }

  /// The healthy path: a link to this app's CLI is installed, nothing is not, a file conflicts.
  func testCommandStatusReadsTheLink() async throws {
    let link = scratch.appendingPathComponent("workroom")
    let none = await CommandLineInstaller.status(at: link.path)
    XCTAssertEqual(none, .notInstalled)

    let file = scratch.appendingPathComponent("other")
    try Data().write(to: file)
    let conflict = await CommandLineInstaller.status(at: file.path)
    XCTAssertEqual(conflict, .conflict(file.path))

    let binary = try XCTUnwrap(try? WorkroomCLI.bundledBinaryURL(), "the app bundles its CLI")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    let installed = await CommandLineInstaller.status(at: link.path)
    XCTAssertEqual(installed, .installed)
  }

  // MARK: Files' home folder

  private func eventually(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("never happened", file: file, line: line)
  }

  /// Value: protects=Files never resolving the home folder on the main actor, and a stuck resolve
  /// still listing the tree against the literal home folder; fails_when=home is resolved on the
  /// main actor (the static let first read by updateWatchScope), or a stuck one holds the tree back
  /// for good; why_new=check-main-actor-fs grandfathered entry; seam=FileTreeModel(resolveHome:);
  /// no_claim=the watch's verdicts (FileTreeModel.watchVerdict's tests)
  func testAStuckHomeNeverStallsFiles() async throws {
    let folder = scratch.appendingPathComponent("plain")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent("notes.txt"))
    let model = FileTreeModel(
      diskReadTimeout: 0.5, resolveHome: stuck("/stuck/home"))

    await whileMainActorStaysFree { model.activate(root: .folder(folder.path)) }

    await eventually { model.state == .loaded && model.isWatching }
    XCTAssertEqual(model.home, NSHomeDirectory(), "the literal home folder")
  }

  /// The healthy path: the home folder resolves, symlinks and all, as the tree is first watched.
  func testFilesResolvesTheHomeFolder() async throws {
    let folder = scratch.appendingPathComponent("plain")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = FileTreeModel(resolveHome: { "/resolved/home" })

    model.activate(root: .folder(folder.path))

    await eventually { model.isWatching }
    XCTAssertEqual(model.home, "/resolved/home")
  }
}
