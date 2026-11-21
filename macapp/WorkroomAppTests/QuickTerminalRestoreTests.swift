import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Quick Terminal's terminals survive a quit (#661, ADR 0077): every quit path keeps them and
/// their sessions, the panel's layout is saved additively in `session.json` and comes back at
/// launch, hidden, and the launch sweep ends only an older build's Quick Terminal sessions. Every
/// test works over a temp session file.
@MainActor
final class QuickTerminalRestoreTests: XCTestCase {
  private var directory: URL!
  private var sessionURL: URL!

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("qt-restore-\(UUID().uuidString)", isDirectory: true)
    sessionURL = directory.appendingPathComponent("session.json")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func makeController(section: TerminalsSection = TerminalsSection())
    -> QuickTerminalController
  {
    let controller = QuickTerminalController()
    controller.section = section
    controller.makeSurface = {
      GhosttySurfaceView(workingDirectory: $0, command: $1, spawnsSurface: false)
    }
    let service = PersistentSessionService(
      probe: { _ in .notBundled }, ownership: { _ in .notOwned })
    _ = service.backend
    controller.sessionServiceOverride = service
    controller.hidesWhenUnfocused = { false }
    controller.recoverSessions = { _, _ in }
    return controller
  }

  private func makeCoordinator(_ controller: QuickTerminalController) -> SavedLayoutCoordinator {
    SavedLayoutCoordinator(
      store: SavedLayoutStore(url: sessionURL), debounce: 0.05, ceiling: 0.2, capture: { [] },
      captureQuickTerminal: { controller.captureSession() })
  }

  /// A panel with two terminals side by side, each with a session.
  private func makePanel(_ controller: QuickTerminalController) throws -> [UUID] {
    controller.toggle()
    let host = try XCTUnwrap(controller.host)
    controller.perform(.splitRight)
    let sessions = [UUID(), UUID()]
    for (tab, session) in zip(host.terminals.allTabs(for: host.target), sessions) {
      host.terminals.giveSession(session, toTab: tab.id, in: host.target)
    }
    return sessions
  }

  /// Value: protects=the Quick Terminal's terminals surviving every quit path: ⌘Q's, a signal's
  /// and a fixture's all begin a quit and flush, then AppKit may close the panel (story 36);
  /// fails_when=a quit ends its sessions, closes its tabs, or skips the registry's terminating
  /// flag that keeps standalone rows; why_new=its end-at-quit is gone (#661); seam=the quit
  /// steps; no_claim=the process exiting
  func testAQuitKeepsItsTerminalsAndSessions() throws {
    let controller = makeController()
    defer { controller.close() }
    let sessions = try makePanel(controller)
    let registry = WindowRegistry()
    let coordinator = makeCoordinator(controller)

    AppDelegate.beginQuit(registry)
    coordinator.flushAndFreeze()
    controller.close()

    XCTAssertTrue(registry.isTerminating, "every path marks the quit")
    let host = try XCTUnwrap(controller.host)
    XCTAssertEqual(
      host.terminals.allTabs(for: host.target).compactMap {
        host.terminals.sessionID(forTab: $0.id, inTarget: .quickTerminal)
      }, sessions, "its tabs and sessions are kept")
    guard case .restored(let file, _) = SavedLayoutStore(url: sessionURL).read() else {
      return XCTFail("nothing written")
    }
    XCTAssertEqual(file.quickTerminal?.sessionIDs, Set(sessions))
  }

  /// Value: protects=the panel's layout (terminals, split, focus) coming back at launch, hidden,
  /// with the same sessions to reattach to (story 44); fails_when=its entry isn't written or read,
  /// a terminal or the split drops, or it shows itself; why_new=#661; seam=quit-and-restore over
  /// session.json; no_claim=a live helper reattaching
  func testItsLayoutComesBackAfterAQuitHidden() async throws {
    let before = makeController()
    let sessions = try makePanel(before)
    makeCoordinator(before).flushAndFreeze()
    before.close()

    let after = makeController()
    defer { after.close() }
    let saved = SavedLayoutCoordinator(store: SavedLayoutStore(url: sessionURL), capture: { [] })
      .savedQuickTerminal()
    await after.restore(saved)

    let host = try XCTUnwrap(after.host)
    XCTAssertFalse(after.hasWindow, "restored hidden, until it is summoned")
    let tabs = host.terminals.allTabs(for: host.target)
    XCTAssertEqual(
      tabs.compactMap { host.terminals.sessionID(forTab: $0.id, inTarget: .quickTerminal) },
      sessions)
    XCTAssertEqual(host.terminals.split(for: host.target)?.tabIDs.count, 2, "side by side")
    after.toggle()
    XCTAssertEqual(host.terminals.allTabs(for: host.target).count, 2, "a summon opens no extra one")
  }

  /// Value: protects=a save before the panel's restore lands writing its saved layout back as it
  /// was read; fails_when=an early save drops the entry; why_new=#661; seam=the coordinator's
  /// capture; no_claim=launch timing
  func testASaveBeforeItsRestoreKeepsItsLayout() throws {
    let saved = TargetSession(
      targetID: TargetID.quickTerminal.encoded,
      tabs: [
        TabSession(
          key: "a", kind: TabSession.terminalKind,
          terminal: TerminalPayload(defaultTitle: "Terminal 1", sessionID: UUID().uuidString))
      ])
    let controller = makeController()
    controller.restoreAtLaunch(saved)

    XCTAssertEqual(controller.captureSession(), saved)
  }

  /// The entry is additive: a panel with no terminals writes nothing, so a file reads as before.
  func testAnEmptyPanelWritesNoEntry() throws {
    let controller = makeController()
    makeCoordinator(controller).flushAndFreeze()
    let text = try String(contentsOf: sessionURL, encoding: .utf8)
    XCTAssertFalse(text.contains("quickTerminal"), text)
  }

  /// A malformed panel entry loses only itself: the windows still restore.
  func testABadPanelEntryLeavesTheWindows() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let file = SessionFile(savedAt: Date(), windows: [WindowSession(windowKey: "w")])
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoder.encode(file)) as? [String: Any])
    json["quickTerminal"] = 42
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json).write(to: sessionURL)

    guard case .restored(let read, _) = SavedLayoutStore(url: sessionURL).read() else {
      return XCTFail("the windows should restore")
    }
    XCTAssertEqual(read.windows.map(\.windowKey), ["w"])
    XCTAssertNil(read.quickTerminal)
  }

  /// Value: protects=the Quick Terminal group's starting folder and fold kept in `terminals.json`,
  /// and an untouched one writing nothing, so the file reads as before (#661); fails_when=they
  /// drop on reload, or the built-in group is written unasked; why_new=#661; seam=the file;
  /// no_claim=none
  func testItsFolderAndFoldAreKeptAndAnUntouchedOneWritesNothing() throws {
    let url = TerminalsSectionFile.beside(sessionURL: sessionURL)
    let section = TerminalsSection(file: TerminalsSectionFile(url: url))
    section.addStandalone()
    section.flush()
    XCTAssertFalse(
      try String(contentsOf: url, encoding: .utf8).contains(
        TargetID.quickTerminalGroupID.uuidString))

    section.setStartingFolder(.quickTerminal, to: "~/ops")
    section.setFolded(.quickTerminal, true)
    section.flush()

    let reloaded = TerminalsSection(file: TerminalsSectionFile(url: url))
    XCTAssertEqual(reloaded.quickTerminal.startingFolder, "~/ops")
    XCTAssertTrue(reloaded.quickTerminal.isFolded)
    XCTAssertEqual(reloaded.quickTerminal.name, "Quick Terminal")
    XCTAssertEqual(reloaded.entries.count, 1, "the built-in group is no entry")
    XCTAssertEqual(reloaded.rows.first?.targetID, .quickTerminal)
  }

  /// Value: protects=the launch sweep sparing the built-in group's sessions and ending an older
  /// build's Quick Terminal sessions only (story 45); fails_when=today's Quick Terminal sessions
  /// read as orphans, or the legacy tag resolves; why_new=#661; seam=the sweep's resolvers;
  /// no_claim=the daemon ending them (TerminalPersistentSessionPolicyTests)
  func testTheLaunchSweepSparesItAndEndsTheLegacyTag() {
    let store = AppStore(terminalsSection: TerminalsSection())
    let tag = TargetID.quickTerminal.encoded
    XCTAssertTrue(store.sessionSurvivesSweep(tag, in: []))
    XCTAssertTrue(store.sessionSurvivesSweep(tag, in: UITestFixture.projects()))
    XCTAssertTrue(QuickTerminalController.sweepResolves(tag))
    XCTAssertFalse(QuickTerminalController.sweepResolves(TargetID.legacyQuickTerminalTag))
  }
}
