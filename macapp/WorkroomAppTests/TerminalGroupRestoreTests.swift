import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Terminal groups survive a quit (#658, ADR 0077): the Terminals section's file and `session.json`
/// saved together come back as the same groups, with their names, starting folders and folds, and
/// the same terminals in them. Every test works over files in a temp directory.
@MainActor
final class TerminalGroupRestoreTests: XCTestCase {
  private var directory: URL!
  private var sessionURL: URL!
  private var sectionURL: URL { TerminalsSectionFile.beside(sessionURL: sessionURL) }
  private static let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("group-restore-\(UUID().uuidString)", isDirectory: true)
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

  /// Value: protects=groups, their names, starting folders, folds, order and terminals back after
  /// a quit (story 43); fails_when=a group, a field or a terminal drops on restore; why_new=#658;
  /// seam=quit-and-restore over both files; no_claim=the session reattaching to a live daemon
  func testGroupsComeBackAfterAQuit() throws {
    let before = makeSection()
    let window = makeStore(section: before, claims: false)
    window.newStandaloneTerminal()
    let ops = try XCTUnwrap(window.newTerminalGroup(named: "Ops"))
    window.newTerminalInSelectedTarget()
    window.setTerminalGroupStartingFolder(ops, to: directory.path)
    before.setFolded(try XCTUnwrap(ops.targetID), true)
    let servers = try XCTUnwrap(window.newTerminalGroup(named: "Servers"))
    window.renameTerminalGroup(servers, to: "")
    let rows = before.entries
    SavedLayoutStore(url: sessionURL).writeSynchronously(
      SessionFile(savedAt: Date(), windows: [window.captureWindowSession()]))
    before.flush()

    let after = makeSection()
    let relaunched = makeStore(section: after, claims: true)
    relaunched.claimSessionIfNeeded()
    relaunched.restorePersistedSessionIfPending(in: [])

    XCTAssertEqual(after.entries, rows, "the rows, in order, with every group's fields")
    XCTAssertEqual(relaunched.terminalGroup(ops)?.name, "Ops")
    XCTAssertEqual(relaunched.terminalGroup(ops)?.startingFolder, directory.path)
    XCTAssertEqual(relaunched.terminalGroup(ops)?.isFolded, true)
    XCTAssertNil(relaunched.terminalGroup(servers)?.name, "an unnamed group stays unnamed")
    XCTAssertEqual(relaunched.terminals.tabCount(forTargetID: try XCTUnwrap(ops.targetID)), 2)
    XCTAssertEqual(relaunched.terminals.tabCount(forTargetID: try XCTUnwrap(servers.targetID)), 1)
    let title = try XCTUnwrap(relaunched.target(for: servers)?.title)
    XCTAssertTrue(
      title.hasPrefix("\(TerminalState.shellName) "),
      "\(title) is named by its program and folder")
    XCTAssertEqual(
      relaunched.pendingRestoreSelection.flatMap(\.sidebarID).flatMap {
        relaunched.liveSelection($0, in: [])
      }, servers)
  }

  /// Value: protects=a quit never deletes a group: the windows' teardown and the saved-layout
  /// capture leave every group listed, and its terminals come back at launch, where the prune keeps
  /// it (ADR 0077, ADR 0058); fails_when=the teardown's closing tabs or unregistering windows reads
  /// a group as empty and drops it, or the relaunch's prune does; why_new=the owner's "a group goes
  /// with its last terminal"; seam=quit-and-restore over both files; no_claim=the live daemon
  func testAQuitKeepsEveryGroupAndItsTerminalsComeBack() async throws {
    let before = makeSection()
    let window = makeStore(section: before, claims: false)
    let ops = try XCTUnwrap(window.newTerminalGroup(named: "Ops"))
    let id = try XCTUnwrap(ops.targetID)

    WindowRegistry.shared.isTerminating = true
    let session = SessionFile(savedAt: Date(), windows: [window.captureWindowSession()])
    await window.terminals.reapAll()
    await window.endStandaloneTerminalsOnClose()
    await before.regroupsSettled()
    WindowRegistry.shared.isTerminating = false
    XCTAssertEqual(before.entries.map(\.sidebarID), [ops], "the quit left the group listed")
    SavedLayoutStore(url: sessionURL).writeSynchronously(session)
    before.flush()

    let after = makeSection()
    let relaunched = makeStore(section: after, claims: true)
    relaunched.claimSessionIfNeeded()
    relaunched.restorePersistedSessionIfPending(in: [])
    after.pruneUnheld()
    await after.regroupsSettled()

    XCTAssertEqual(after.entries.map(\.sidebarID), [ops])
    XCTAssertEqual(relaunched.terminalGroup(ops)?.name, "Ops")
    XCTAssertEqual(relaunched.terminals.tabCount(forTargetID: id), 1, "its terminal is back")
  }

  // MARK: The file

  /// Value: protects=the stored contract of a group in `terminals.json`; fails_when=a field
  /// renames, or an unset field is written; why_new=#658; seam=the file; no_claim=none
  func testAGroupIsStoredAsWritten() throws {
    let golden = """
      {
        "entries" : [
          {
            "folded" : true,
            "folder" : "~\\/ops",
            "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            "kind" : "group",
            "name" : "Ops"
          },
          {
            "id" : "00000000-0000-0000-0000-000000000001",
            "kind" : "group"
          }
        ],
        "schemaVersion" : 1
      }
      """
    let bare = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let file = TerminalsSectionFile(url: sectionURL)
    let entries: [TerminalsSection.Entry] = [
      .group(TerminalGroup(id: Self.id, name: "Ops", startingFolder: "~/ops", isFolded: true)),
      .group(TerminalGroup(id: bare)),
    ]
    file.write(entries)
    file.flush()

    XCTAssertEqual(try String(contentsOf: sectionURL, encoding: .utf8), golden)
    XCTAssertEqual(
      TerminalsSectionFile(url: sectionURL).read()?.entries.compactMap(\.entry), entries)
  }

  /// A field of the wrong type is read as unset, never dropping the group with it.
  func testABadFieldLeavesTheGroup() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = """
      {"schemaVersion": 1, "entries": [
        {"kind": "group", "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": 3, "folded": "yes"}
      ]}
      """
    try Data(file.utf8).write(to: sectionURL)

    XCTAssertEqual(makeSection().entries, [.group(TerminalGroup(id: Self.id))])
  }
}
