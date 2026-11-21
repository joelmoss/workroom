import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Quick Terminal is the built-in terminal group (#661, ADR 0077): listed first in the
/// Terminals section and never deleted, moved or renamed; its panel is the group's one holder, so a
/// window's row click slides the panel in, and Move to… → Quick Terminal moves a terminal there.
@MainActor
final class QuickTerminalGroupTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()
  private let workroom = SidebarID.workroom(project: "/p", name: "a")
  private let builtIn = SidebarID.terminalGroup(TargetID.quickTerminalGroupID)

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    isolate(store.terminals, service: retaggingService())
    return store
  }

  private func makePanel() -> QuickTerminalHost {
    makeQuickTerminalHost(
      notifications: registry.notifications, service: retaggingService(), section: section)
  }

  /// A session service with no helper, whose retag of a moved terminal succeeds.
  private func retaggingService() -> PersistentSessionService {
    PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
  }

  // MARK: The section's first row

  /// Value: protects=the Quick Terminal listed first in the Terminals section and never deleted,
  /// moved or renamed (stories 10, 38); fails_when=it is missing, not first, or a delete, drag or
  /// rename changes it; why_new=the built-in group (#661); seam=AppStore over the shared section;
  /// no_claim=the sidebar's drawing (QuickTerminalUITests)
  func testItIsListedFirstAndCantBeDeletedMovedOrRenamed() async {
    let store = makeStore()
    store.newStandaloneTerminal()
    let ops = store.newTerminalGroup(named: "Ops")
    XCTAssertEqual(section.rows.first?.sidebarID, builtIn)
    XCTAssertEqual(store.target(for: builtIn)?.title, "Quick Terminal")

    await store.deleteTerminalGroup(builtIn)
    section.remove(.quickTerminal)
    section.move(.quickTerminal, before: nil)
    store.renameTerminalGroup(builtIn, to: "Mine")
    if let ops, let id = ops.targetID { section.move(id, before: .quickTerminal) }

    XCTAssertEqual(section.rows.first?.sidebarID, builtIn, "still first")
    XCTAssertEqual(
      section.rows.dropFirst().first?.sidebarID, ops, "a row moved above it lands below")
    XCTAssertEqual(store.target(for: builtIn)?.title, "Quick Terminal", "its name is fixed")
    XCTAssertTrue(
      section.group(.quickTerminal)?.isKept == true, "an unnamed group's dissolve spares it")
  }

  /// A window with no projects and nothing in the section still shows its empty state: the
  /// built-in row is no terminal of the user's.
  func testItAloneIsNoSidebarContent() {
    let store = makeStore()
    projects.projects = []
    XCTAssertFalse(store.sidebarHasContent)
  }

  /// Value: protects=the Quick Terminal's starting folder following the group rules (story 40);
  /// fails_when=its new terminals ignore Set Starting Folder…, or a folder that has gone strands
  /// them; why_new=it was its own setting (#661); seam=the section; no_claim=the folder picker
  func testItsStartingFolderFollowsTheGroupRules() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("qt-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let panel = makePanel()

    let store = makeStore()
    store.setTerminalGroupStartingFolder(builtIn, to: folder.path)
    XCTAssertEqual(panel.target.path, folder.path)
    let tab = panel.terminals.addTab(for: panel.target)
    XCTAssertEqual(panel.terminals.surface(tab)?.workingDirectory, folder.path)

    try FileManager.default.removeItem(at: folder)
    XCTAssertEqual(panel.target.path, TerminalsSection.newTerminalDirectory(), "gone: the default")
    store.setTerminalGroupStartingFolder(builtIn, to: nil)
    XCTAssertEqual(panel.target.path, TerminalsSection.newTerminalDirectory())
  }

  // MARK: Its panel holds it

  /// Value: protects=the panel answering as the built-in group's holder, for group counts and
  /// raising (ADR 0077), while it stays out of WindowRegistry (ADR 0064); fails_when=its terminals
  /// aren't counted, another holder answers for them, or it registers as a window;
  /// why_new=#661; seam=the section's holder queries; no_claim=a group's delete (it has none)
  func testThePanelIsTheGroupsHolderAndNoWindow() async {
    let panel = makePanel()
    let store = makeStore()
    _ = panel.terminals.addTab(for: panel.target)
    _ = panel.terminals.addTab(for: panel.target)

    XCTAssertEqual(section.terminalNames(of: .quickTerminal), ["Terminal 1", "Terminal 2"])
    XCTAssertTrue(section.holder(of: .quickTerminal, other: store) === panel)
    let anchor = TargetID.standalone(UUID())
    let released = await panel.releaseTerminals(of: .quickTerminal, after: anchor)
    XCTAssertEqual(released, anchor, "never deleted, so it releases nothing")
    XCTAssertEqual(panel.terminals.tabCount(forTargetID: .quickTerminal), 2)
    XCTAssertTrue(registry.allStores.isEmpty, "no window registered")
  }

  /// Value: protects=clicking the Quick Terminal's row in a window sliding its panel in and
  /// leaving the window's selection alone (story 37); fails_when=the window selects it, opens a
  /// terminal of its own in it, or the panel isn't asked to show; why_new=#661; seam=AppStore
  /// selection; no_claim=the slide itself (QuickTerminalControllerTests)
  func testItsRowSlidesThePanelInAndKeepsTheSelection() throws {
    let panel = makePanel()
    var revealed = 0
    panel.onReveal = { _ in revealed += 1 }
    let store = makeStore()
    store.selectedTargetID = workroom

    store.selectedTargetID = builtIn

    XCTAssertEqual(store.selectedTargetID, workroom)
    XCTAssertEqual(revealed, 1)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: .quickTerminal), 0)

    store.revealQuickTerminal(newTerminal: true)
    XCTAssertEqual(revealed, 2)
    XCTAssertEqual(
      panel.terminals.tabCount(forTargetID: .quickTerminal), 1, "New Terminal in Group")
  }

  /// Value: protects=Move to… → Quick Terminal moving a window's terminal into the panel, keeping
  /// its shell, and sliding the panel in (stories 28, 37); fails_when=the choice is missing,
  /// disabled, or the terminal stays in the window; why_new=#661 adds it to the shared choices;
  /// seam=PaneMove.choices; no_claim=the menu rendering (#660)
  func testMoveToQuickTerminalMovesTheTerminalIntoThePanel() async throws {
    let panel = makePanel()
    var revealed: [TerminalTab.ID?] = []
    panel.onReveal = { revealed.append($0) }
    let store = makeStore()
    let target = try XCTUnwrap(store.target(for: workroom))
    let tab = store.terminals.addTab(for: target)
    let session = UUID()
    store.terminals.giveSession(session, toTab: tab.id, in: target)
    store.selectedTargetID = workroom

    let groups = store.paneMoveChoices(tab.id, of: target, windows: [store], quickTerminal: panel)
    XCTAssertEqual(
      groups.first?.choices.prefix(2).map(\.title), ["Standalone", "Quick Terminal"],
      "in the Terminals section's places, right after Standalone")
    let choice = try XCTUnwrap(groups.first?.choices.dropFirst().first)
    XCTAssertTrue(choice.enabled)
    choice.move()
    for _ in 0..<100 where panel.terminals.tab(tab.id, for: panel.target) == nil {
      await Task.yield()
    }

    XCTAssertNotNil(panel.terminals.tab(tab.id, for: panel.target), "it arrives")
    XCTAssertEqual(panel.terminals.sessionID(forTab: tab.id, inTarget: .quickTerminal), session)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: target.id), 0, "and leaves")
    XCTAssertEqual(revealed, [tab.id], "the panel slides in on it")

    let own = panel.paneMoveChoices(tab.id, of: panel.target, windows: [store])
    let ownPlace = own.first?.choices.first { $0.title == "Quick Terminal" }
    XCTAssertEqual(ownPlace?.enabled, false, "its own place is listed disabled")
  }

  /// Value: protects=popping a pane out of the panel and docking it back (story 39);
  /// fails_when=its panes can't leave the panel again, or the dock doesn't bring it back;
  /// why_new=the panel kept every pane in (#661); seam=the pane's Move to New Window;
  /// no_claim=the window's chrome (DetachedPaneUITests)
  func testAPanePopsOutOfThePanelAndDocksBack() {
    let panel = makePanel()
    var revealed: [TerminalTab.ID?] = []
    panel.onReveal = { revealed.append($0) }
    let tab = panel.terminals.addTab(for: panel.target)
    _ = panel.terminals.addTab(for: panel.target)

    panel.togglePaneWindow(tab.id, targetID: .quickTerminal)
    XCTAssertEqual(panel.terminals.detachedTabIDs, [tab.id])
    XCTAssertNotNil(panel.detachedWindowIsKey(forTab: tab.id), "it has a window of its own")

    panel.togglePaneWindow(tab.id, targetID: .quickTerminal)
    XCTAssertTrue(panel.terminals.detachedTabIDs.isEmpty)
    XCTAssertNil(panel.detachedWindowIsKey(forTab: tab.id))
    XCTAssertEqual(revealed, [tab.id], "docked back into the panel, which slides in")
  }
}
