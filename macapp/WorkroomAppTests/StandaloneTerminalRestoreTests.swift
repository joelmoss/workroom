import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Standalone terminals survive a quit (#655, ADR 0077): the Terminals section's file and
/// `session.json` saved together come back as the same rows, tabs and selection. Every test works
/// over files in a temp directory, never the developer's own.
@MainActor
final class StandaloneTerminalRestoreTests: XCTestCase {
  private var directory: URL!
  private var sessionURL: URL!
  private var sectionURL: URL { TerminalsSectionFile.beside(sessionURL: sessionURL) }

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("standalone-restore-\(UUID().uuidString)", isDirectory: true)
    sessionURL = directory.appendingPathComponent("session.json")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func makeSection() -> TerminalsSection {
    TerminalsSection(file: TerminalsSectionFile(url: sectionURL))
  }

  private func makeStore(section: TerminalsSection, claims: Bool) -> AppStore {
    let projectStore = ProjectStore()
    projectStore.sessionCoordinator = SavedLayoutCoordinator(
      store: SavedLayoutStore(url: sessionURL), debounce: 0.05, ceiling: 0.2, capture: { [] })
    let store = AppStore(projectStore: projectStore, terminalsSection: section)
    store.isRestoreWindow = claims
    store.claimsSavedSession = claims
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    return store
  }

  /// Value: protects=standalone terminals, their order and the selection back after a quit
  /// (story 43); fails_when=the section or a target drops on restore; why_new=#655;
  /// seam=quit-and-restore over both files; no_claim=the session reattaching to a live daemon
  func testStandaloneTerminalsComeBackAfterAQuit() throws {
    let before = makeSection()
    let window = makeStore(section: before, claims: false)
    window.newStandaloneTerminal()
    window.newStandaloneTerminal()
    let rows = before.entries.map(\.sidebarID)
    let selected = try XCTUnwrap(window.selectedTargetID)
    SavedLayoutStore(url: sessionURL).writeSynchronously(
      SessionFile(savedAt: Date(), windows: [window.captureWindowSession()]))
    before.flush()

    let after = makeSection()
    let relaunched = makeStore(section: after, claims: true)
    relaunched.claimSessionIfNeeded()
    relaunched.restorePersistedSessionIfPending(in: [])

    XCTAssertEqual(after.entries.map(\.sidebarID), rows, "the rows, in order")
    for sid in rows {
      XCTAssertEqual(
        relaunched.terminals.tabCount(forTargetID: try XCTUnwrap(sid.targetID)), 1, "\(sid)")
    }
    XCTAssertEqual(
      relaunched.pendingRestoreSelection.flatMap(\.sidebarID).flatMap {
        relaunched.liveSelection($0, in: [])
      }, selected)
    XCTAssertEqual(
      Set(relaunched.orderedWorkroomTargets().map(\.target.id)), Set(rows.compactMap(\.targetID)))
  }

  /// Value: protects=a standalone row is exactly one live terminal after a launch (#656);
  /// fails_when=a row no restored window holds stays and opens a fresh shell on selection;
  /// why_new=#656; seam=quit-and-restore over both files; no_claim=the daemon sessions
  func testARowNoRestoredWindowHoldsIsPrunedAtLaunch() throws {
    let before = makeSection()
    let window = makeStore(section: before, claims: false)
    window.newStandaloneTerminal()
    let held = try XCTUnwrap(window.selectedTargetID)
    // A crash that lost the window's layout of this one: its row is saved, its terminal is not.
    let lost = before.addStandalone()
    SavedLayoutStore(url: sessionURL).writeSynchronously(
      SessionFile(savedAt: Date(), windows: [window.captureWindowSession()]))
    before.flush()
    XCTAssertEqual(makeSection().entries.count, 2)

    let after = makeSection()
    let relaunched = makeStore(section: after, claims: true)
    relaunched.claimSessionIfNeeded()
    relaunched.restorePersistedSessionIfPending(in: [])

    XCTAssertEqual(after.entries.map(\.sidebarID), [held], "only the restored one is kept")
    XCTAssertFalse(after.contains(lost))
    after.flush()
    XCTAssertEqual(makeSection().entries.map(\.sidebarID), [held], "and the file says so")
  }

  /// A quit tears every window down; that must not read as the user closing the terminals.
  func testTheRowsAreWrittenAsTheyChangeNotAtQuit() throws {
    let section = makeSection()
    let window = makeStore(section: section, claims: false)
    window.newStandaloneTerminal()
    section.flush()

    XCTAssertEqual(makeSection().entries, section.entries, "a crash keeps them too")

    section.isFolded = true
    section.flush()
    XCTAssertTrue(makeSection().isFolded, "and the fold")
  }

  // MARK: The file

  /// Value: protects=the stored contract of `terminals.json`, and an older build reading a newer
  /// one's entries; fails_when=a field renames, or an unknown kind fails the whole file;
  /// why_new=#655; seam=the file; no_claim=groups' fields (TerminalGroupRestoreTests)
  func testTheFileReadsAsWrittenAndDropsAKindItDoesNotKnow() throws {
    let id = try XCTUnwrap(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    let golden = """
      {
        "entries" : [
          {
            "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            "kind" : "standalone"
          }
        ],
        "schemaVersion" : 1
      }
      """
    let file = TerminalsSectionFile(url: sectionURL)
    file.write([.standalone(id)])
    file.flush()
    XCTAssertEqual(try String(contentsOf: sectionURL, encoding: .utf8), golden)

    let newer = """
      {"schemaVersion": 1, "entries": [
        {"kind": "folder", "id": "00000000-0000-0000-0000-000000000001", "name": "ops"},
        {"kind": "standalone", "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF"}
      ]}
      """
    try Data(newer.utf8).write(to: sectionURL)
    XCTAssertEqual(
      TerminalsSectionFile(url: sectionURL).read()?.entries.compactMap(\.entry), [.standalone(id)])
  }

  /// A file from a newer schema is read but never written over.
  func testANewerSchemasFileIsNotOverwritten() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let newer = #"{"schemaVersion": 2, "entries": []}"#
    try Data(newer.utf8).write(to: sectionURL)

    let section = makeSection()
    section.addStandalone()
    section.flush()

    XCTAssertEqual(try String(contentsOf: sectionURL, encoding: .utf8), newer)
  }

  /// Under test the shared section writes nowhere unless a file is named.
  func testTheEnvironmentsFileIsDisabledUnderTest() {
    XCTAssertTrue(TerminalsSectionFile.forCurrentEnvironment().isDisabled)
  }

  // MARK: "New terminals open in"

  /// Value: protects=the Quick Terminal's "Opens in" folder carrying over to "New terminals open
  /// in"; fails_when=the folder is lost, or a later change is overwritten; why_new=#655;
  /// seam=the migration over its own suite; no_claim=the Settings view
  func testTheQuickTerminalsFolderBecomesNewTerminalsOpenIn() throws {
    let name = "standalone-migration-\(UUID().uuidString)"
    let suite = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    suite.set("/tmp/ops", forKey: "quickTerminalDirectory")

    TerminalsSection.migrateNewTerminalDirectory(suite)
    XCTAssertEqual(suite.string(forKey: "newTerminalDirectory"), "/tmp/ops")
    XCTAssertEqual(
      suite.string(forKey: "quickTerminalDirectory"), "/tmp/ops", "kept for an older build")

    suite.set("", forKey: "newTerminalDirectory")
    TerminalsSection.migrateNewTerminalDirectory(suite)
    XCTAssertEqual(suite.string(forKey: "newTerminalDirectory"), "", "once only")
  }
}
