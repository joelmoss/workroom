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
      section.group(.quickTerminal) != nil, "a group's delete spares it")
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
  func testItsStartingFolderFollowsTheGroupRules() async throws {
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
    // Once its folder is checked again, off the main actor (`FolderPresence`).
    await section.folderPresence.check(folder.path)
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

    let name = TerminalState.programAndFolder(
      program: TerminalState.shellName, folder: panel.target.path
    ).text
    XCTAssertEqual(section.terminalNames(of: .quickTerminal), [name, name], "never numbered")
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

  /// Value: protects=the built-in group outlives its last terminal, though every other group goes
  /// with its own; fails_when=closing the panel's last terminal, or settling its group, drops it;
  /// why_new=the owner's "a group goes with its last terminal"; seam=the panel over the shared
  /// section; no_claim=the panel hiding (QuickTerminalControllerTests)
  func testClosingItsLastTerminalKeepsTheGroup() async {
    let panel = makePanel()
    let store = makeStore()
    let tab = panel.terminals.addTab(for: panel.target)

    panel.terminals.closeTab(tab.id, for: panel.target)
    section.settleGroup(.quickTerminal)
    await section.regroupsSettled()

    XCTAssertEqual(panel.terminals.tabCount(forTargetID: .quickTerminal), 0)
    XCTAssertNotNil(section.group(.quickTerminal))
    XCTAssertEqual(section.rows.first?.sidebarID, builtIn)
    XCTAssertNotNil(store.target(for: builtIn))
  }

  /// Value: protects=one of the panel's terminals listed under its row in a window slides the
  /// panel in on that terminal (story 10); fails_when=the click opens it in the window, or slides
  /// the panel in on another terminal; why_new=#652 review P8; seam=AppStore.revealTerminal;
  /// no_claim=the slide and focus themselves (QuickTerminalController.reveal(tab:))
  func testClickingOneOfItsTerminalsRowsSlidesThePanelInOnIt() {
    let panel = makePanel()
    let first = panel.terminals.addTab(for: panel.target)
    _ = panel.terminals.addTab(for: panel.target)
    var revealed: [TerminalTab.ID?] = []
    panel.onReveal = { revealed.append($0) }
    let store = makeStore()
    store.selectedTargetID = workroom

    store.revealTerminal(first.id, at: builtIn)

    XCTAssertEqual(revealed, [first.id], "the panel slides in on that terminal")
    XCTAssertEqual(store.selectedTargetID, workroom, "the window's selection stays")
    XCTAssertEqual(store.terminals.tabCount(forTargetID: .quickTerminal), 0)
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
      groups.first?.choices.prefix(2).map(\.title), ["Standalone Terminal", "Quick Terminal"],
      "in the Terminals section's places, right after Standalone Terminal")
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

  /// Value: protects=a terminal's tab dropped on the Quick Terminal's row moving it into the
  /// panel, keeping its shell, and sliding the panel in (stories 29, 37); fails_when=the row
  /// refuses the drop, or the window adopts the pane under the built-in group as a second holder;
  /// why_new=the row refused every tab (P1 of the #652 review); seam=AppStore.dropPane;
  /// no_claim=hit-testing the pointer (QuickTerminalUITests)
  func testATabDroppedOnTheQuickTerminalsRowMovesIntoThePanel() async throws {
    let panel = makePanel()
    var revealed: [TerminalTab.ID?] = []
    panel.onReveal = { revealed.append($0) }
    let store = makeStore()
    let target = try XCTUnwrap(store.target(for: workroom))
    let tab = store.terminals.addTab(for: target)
    let session = UUID()
    store.terminals.giveSession(session, toTab: tab.id, in: target)
    store.selectedTargetID = workroom

    XCTAssertTrue(store.canDropPane(tab.id, of: target, on: .target(builtIn)))
    let dropped = await store.dropPane(tab.id, of: target, on: .target(builtIn))

    XCTAssertTrue(dropped)
    XCTAssertNotNil(panel.terminals.tab(tab.id, for: panel.target), "it arrives in the panel")
    XCTAssertEqual(panel.terminals.sessionID(forTab: tab.id, inTarget: .quickTerminal), session)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: target.id), 0, "and leaves the window")
    XCTAssertEqual(store.terminals.tabCount(forTargetID: .quickTerminal), 0, "no second holder")
    XCTAssertEqual(revealed, [tab.id], "the panel slides in on it")
  }

  /// Value: protects=the Quick Terminal's row taking no pane the window can't hand over: one in a
  /// remote workroom, and none at all while no panel holds the group; and the window itself never
  /// adopting a pane under the built-in group (ADR 0077: the panel is its one holder);
  /// fails_when=a remote shell moves into the panel, or a direct move into `.quickTerminal` lands
  /// in the window; why_new=the row now takes a tab (P1); seam=AppStore; no_claim=none
  func testTheQuickTerminalsRowRefusesARemoteTerminalAndTheWindowNeverHoldsTheGroup() async throws {
    let panel = makePanel()
    let store = makeStore()
    let target = try XCTUnwrap(store.target(for: workroom))
    let tab = store.terminals.addTab(for: target)

    let intoWindow = await PaneMove.move(
      tab.id, of: target, source: store.terminals, notifications: registry.notifications,
      to: store, into: .quickTerminal)
    XCTAssertFalse(intoWindow, "a window takes no pane under the built-in group")
    XCTAssertNotNil(store.terminals.tab(tab.id, for: target))

    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [
          Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: []),
          Workroom(
            name: "far", path: "/p/far", vcsName: "workroom/far", warnings: [],
            host: HostDescriptor(id: UUID())),
        ])
    ]
    let remote = SidebarID.workroom(project: "/p", name: "far")
    let far = try XCTUnwrap(store.target(for: remote))
    let farTab = store.terminals.addTab(for: far)
    XCTAssertFalse(store.canDropPane(farTab.id, of: far, on: .target(builtIn)))
    let dropped = await store.dropPane(farTab.id, of: far, on: .target(builtIn))
    XCTAssertFalse(dropped)
    XCTAssertNotNil(store.terminals.tab(farTab.id, for: far))
    XCTAssertEqual(panel.terminals.tabCount(forTargetID: .quickTerminal), 0)
  }

  /// Value: protects=Move to… → Standalone, or a group, from a panel's terminal making it in the
  /// front window (P9 of the #652 review); fails_when=it lands in the first window listed
  /// whichever is in front; why_new=the panel's pane has no window of its own, so `windows.first`
  /// took it; seam=PaneMove.choices; no_claim=which window is key on screen (WindowRegistry)
  func testAPanelTerminalMovesToStandaloneOrAGroupInTheFrontWindow() async throws {
    let panel = makePanel()
    let behind = makeStore()
    let front = makeStore()
    let group = try XCTUnwrap(front.newTerminalGroup(named: "Ops"))
    let first = panel.terminals.addTab(for: panel.target)
    let second = panel.terminals.addTab(for: panel.target)

    let places = panel.paneMoveChoices(
      first.id, of: panel.target, windows: [behind, front], front: front)[0].choices
    try XCTUnwrap(places.first { $0.title == "Standalone Terminal" }).move()
    for _ in 0..<100 where panel.terminals.tab(first.id, for: panel.target) != nil {
      await Task.yield()
    }
    let standalone = try XCTUnwrap(
      section.rows.first { if case .standalone = $0.sidebarID { true } else { false } })
    let into = try XCTUnwrap(front.target(for: standalone.sidebarID))
    XCTAssertNotNil(front.terminals.tab(first.id, for: into), "standalone in the front window")
    XCTAssertEqual(behind.terminals.tabCount(forTargetID: into.id), 0)

    let again = panel.paneMoveChoices(
      second.id, of: panel.target, windows: [behind, front], front: front)[0].choices
    try XCTUnwrap(again.first { $0.title == "Ops" }).move()
    let ops = try XCTUnwrap(front.target(for: group))
    for _ in 0..<100 where front.terminals.tab(second.id, for: ops) == nil { await Task.yield() }
    XCTAssertNotNil(front.terminals.tab(second.id, for: ops), "the group's, in the front window")
    XCTAssertEqual(behind.terminals.tabCount(forTargetID: ops.id), 0)
  }

  /// The app's Quick Terminal controller, its panel over this test's section with no real
  /// sessions, joined to this test's registry as the app's is to the shared one.
  private func joinedController() -> QuickTerminalController {
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
    registry.quickTerminal = controller
    return controller
  }

  /// Value: protects=a pane popped out of the panel docking back from the Window menu's "Move back
  /// to main window", and a drop over its window naming the panel as its owner (P2 of the #652
  /// review, story 39), while the panel stays out of the registry's windows (ADR 0064);
  /// fails_when=the owner lookup reads only registered windows, so the dock does nothing and the
  /// drop over the pane's window reads as empty desktop; why_new=the panel's panes pop out since
  /// #661; seam=WindowRegistry; no_claim=the menu item's rendering (QuickTerminalUITests)
  func testAPanePoppedOutOfThePanelDocksBackThroughTheRegistry() throws {
    let controller = joinedController()
    let panel = controller.ensureHost()
    var revealed: [TerminalTab.ID?] = []
    panel.onReveal = { revealed.append($0) }
    let store = makeStore()
    let tab = panel.terminals.addTab(for: panel.target)
    panel.togglePaneWindow(tab.id, targetID: .quickTerminal)
    let window = try XCTUnwrap(panel.detachedPanes.window(for: tab.id))

    guard case .quickTerminal(let owner) = registry.dropWindow(resolving: window) else {
      return XCTFail("a drop over the popped-out pane names the panel as its owner")
    }
    XCTAssertTrue(owner === panel)
    XCTAssertTrue(registry.allStores.isEmpty, "the panel registers as no window")

    XCTAssertTrue(registry.dockDetachedPane(tab.id))

    XCTAssertTrue(panel.terminals.detachedTabIDs.isEmpty, "docked back")
    XCTAssertNotNil(panel.terminals.tab(tab.id, for: panel.target), "into the panel")
    XCTAssertNil(panel.detachedPanes.window(for: tab.id), "its window went")
    XCTAssertEqual(revealed, [tab.id], "and the panel slides in on it")
    XCTAssertEqual(store.terminals.tabCount(forTargetID: .quickTerminal), 0)
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
