import AppKit
import DaemonConnection
import WorkroomDomain
import XCTest

@testable import Workroom

/// What the app does with `workroom new` and `workroom close` (#693): the Mac the daemon named,
/// holding the caller's pane, opens the new session as a split beside it when asked and it is on
/// screen, else as a tab; every other Mac, and every Mac when no pane shows the caller, lists it
/// with the detached sessions; a close closes every tab of the session, in every window.
@MainActor
final class TerminalRequestsTests: XCTestCase {
  private let caller = UUID(uuidString: "5A1E0F7E-0D6C-4C9F-9C3E-2B7F1D0A8E11")!
  private let created = UUID(uuidString: "C0FFEE00-1111-4222-8333-44445555BEEF")!
  private let workroomID = TargetID.workroom(project: "/p", name: "a")
  private let tab = UUID()

  private func request(
    split: TerminalOpenRequest.Split? = nil, hostname: String? = "laptop", by: UUID? = nil,
    label: String? = nil
  ) -> TerminalOpenRequest {
    TerminalOpenRequest(
      session: created, by: by ?? caller, split: split, hostname: hostname,
      workroom: workroomID.encoded, label: label, run: false)
  }

  private func placement(
    holder: Int = 0, tab: UUID? = nil, onScreen: Bool = true, key: Bool = false,
    poppedOut: Bool = false
  ) -> TerminalOpenPlacement {
    TerminalOpenPlacement(
      holder: holder, target: workroomID, tab: tab ?? self.tab, onScreen: onScreen, key: key,
      poppedOut: poppedOut)
  }

  // MARK: The rule

  /// Value: protects=a `new` with no split opens a tab on the Mac showing the caller (story 24);
  /// fails_when=it splits, or opens nothing; why_new=#693; seam=TerminalOpenRule; no_claim=drawing
  func testTheMacShowingTheCallersPaneOpensATab() {
    XCTAssertEqual(
      TerminalOpenRule.plan(request(), thisMac: "laptop", placements: [placement()]),
      .tab(holder: 0, target: workroomID))
  }

  /// A split asked for goes beside the caller's tab while it is on screen, on its right or below.
  func testASplitGoesBesideTheCallersPaneOnScreen() {
    XCTAssertEqual(
      TerminalOpenRule.plan(request(split: .right), thisMac: "laptop", placements: [placement()]),
      .split(holder: 0, target: workroomID, beside: tab, edge: .right))
    XCTAssertEqual(
      TerminalOpenRule.plan(request(split: .down), thisMac: "laptop", placements: [placement()]),
      .split(holder: 0, target: workroomID, beside: tab, edge: .bottom))
  }

  /// A split beside a pane no one sees, or one popped out into a window of its own where no split
  /// goes, is a tab of the caller's target instead.
  func testASplitBesideAPaneNotOnScreenOrPoppedOutIsATab() {
    for hidden in [placement(onScreen: false), placement(poppedOut: true)] {
      XCTAssertEqual(
        TerminalOpenRule.plan(request(split: .right), thisMac: "laptop", placements: [hidden]),
        .tab(holder: 0, target: workroomID), "\(hidden)")
    }
  }

  /// Value: protects=only the Mac the daemon named opens it; another Mac holding the caller's pane
  /// too lists it as detached (story 26); fails_when=both Macs open a tab; why_new=#693;
  /// seam=TerminalOpenRule; no_claim=the detached list's drawing
  func testAnotherMacsNewIsListedAsDetachedHere() {
    XCTAssertEqual(
      TerminalOpenRule.plan(
        request(split: .right), thisMac: "studio", placements: [placement(key: true)]),
      .detached)
  }

  /// With no caller pane on screen anywhere the daemon names no Mac, and nothing opens; from no
  /// pane nobody asked; and a Mac named that holds no tab of the caller has nowhere to open it.
  func testWithNoCallerPaneAnywhereEveryMacListsItAsDetached() {
    let none = TerminalOpenRequest(
      session: created, by: nil, split: nil, hostname: "laptop", workroom: nil, label: nil,
      run: false)
    for (asked, placements) in [
      (request(hostname: nil), [placement()]),
      (none, [placement()]),
      (request(), []),
    ] {
      XCTAssertEqual(
        TerminalOpenRule.plan(asked, thisMac: "laptop", placements: placements), .detached)
    }
    XCTAssertEqual(
      TerminalOpenRule.plan(request(), thisMac: nil, placements: [placement()]), .detached,
      "a Mac that can't read its own name can't tell it was named")
  }

  /// Of two windows holding the caller's pane, the one showing it opens it, the key one first; a
  /// window that only holds it opens a tab when none shows it.
  func testOfTwoWindowsTheOneShowingTheCallerOpensItTheKeyOneFirst() {
    let other = UUID()
    let hidden = placement(holder: 0, tab: other, onScreen: false, key: true)
    let shown = placement(holder: 1)
    let keyShown = placement(holder: 2, key: true)
    XCTAssertEqual(
      TerminalOpenRule.plan(
        request(split: .right), thisMac: "laptop", placements: [hidden, shown]),
      .split(holder: 1, target: workroomID, beside: tab, edge: .right))
    XCTAssertEqual(
      TerminalOpenRule.plan(
        request(split: .right), thisMac: "laptop", placements: [hidden, shown, keyShown]),
      .split(holder: 2, target: workroomID, beside: tab, edge: .right))
    XCTAssertEqual(
      TerminalOpenRule.plan(request(split: .right), thisMac: "laptop", placements: [hidden]),
      .tab(holder: 0, target: workroomID))
  }

  // MARK: Handling the events

  /// A holder of tabs that records what it is asked.
  @MainActor
  private final class Holder: TerminalRequestHolder {
    let terminals: TerminalPanes
    let target: TerminalTarget
    var showing = true
    var isKeyHolder = false
    var shown: [(UUID, String?, TerminalTab.ID?, PaneEdge?)] = []
    var closed: [TerminalTab.ID] = []

    init(target: TerminalTarget) {
      self.target = target
      terminals = TerminalPanes()
      terminals.makeView = { _, cwd, command in
        GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
      }
      terminals.recordUnrecognizedTool = { _ in }
      terminals.recency = SwitcherRecency()
    }

    func terminalTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget? {
      targetID == target.id ? target : nil
    }

    func isShowingTarget(_ targetID: TerminalTarget.ID) -> Bool { showing }

    func showRequestedSession(
      _ session: UUID, label: String?, in target: TerminalTarget, beside anchor: TerminalTab.ID?,
      on edge: PaneEdge?
    ) {
      shown.append((session, label, anchor, edge))
    }

    func closeRequestedTab(_ tabID: TerminalTab.ID, in target: TerminalTarget) {
      closed.append(tabID)
    }
  }

  private var target: TerminalTarget {
    TerminalTarget(id: workroomID, title: "a", path: "/tmp", isMissing: false)
  }

  private func requests(
    _ holders: [Holder], thisMac: String = "laptop",
    refreshed: @escaping (HostID, String?) -> Void = { _, _ in }
  ) -> TerminalRequests {
    let requests = TerminalRequests()
    requests.holders = { holders }
    requests.thisMac = { thisMac }
    requests.refreshDetached = refreshed
    return requests
  }

  /// Value: protects=a `new --split` from a pane opens beside that pane in the window showing it,
  /// and nowhere else (stories 25–26); fails_when=a hidden window or the wrong pane takes it;
  /// why_new=#693; seam=TerminalRequests over holders; no_claim=the split's geometry
  func testANewOpensBesideTheCallerInTheWindowShowingIt() {
    let hidden = Holder(target: target)
    hidden.showing = false
    let shown = Holder(target: target)
    _ = hidden.terminals.addTab(for: target, sessionID: caller)
    _ = shown.terminals.addTab(for: target, sessionID: UUID())
    let callerTab = shown.terminals.addTab(for: target, sessionID: caller)
    requests([hidden, shown]).handle(
      .opened(request(split: .right, label: "dev server")), from: .local)
    XCTAssertTrue(hidden.shown.isEmpty, "the window not showing the caller opens nothing")
    XCTAssertEqual(shown.shown.count, 1)
    XCTAssertEqual(shown.shown.first?.0, created)
    XCTAssertEqual(shown.shown.first?.1, "dev server")
    XCTAssertEqual(shown.shown.first?.2, callerTab.id, "beside the caller's own pane")
    XCTAssertEqual(shown.shown.first?.3, .right)
  }

  /// Another Mac's `new` opens nothing here, and reads its workroom's detached list again, so the
  /// session shows there at once.
  func testAnotherMacsNewReadsItsWorkroomsDetachedListAgain() {
    let holder = Holder(target: target)
    _ = holder.terminals.addTab(for: target, sessionID: caller)
    var refreshed: [(HostID, String?)] = []
    let remote = HostID.remote(UUID())
    requests([holder], thisMac: "studio") { refreshed.append(($0, $1)) }.handle(
      .opened(request()), from: remote)
    XCTAssertTrue(holder.shown.isEmpty)
    XCTAssertEqual(refreshed.count, 1)
    XCTAssertEqual(refreshed.first?.0, remote)
    XCTAssertEqual(refreshed.first?.1, workroomID.encoded)
  }

  /// Value: protects=`workroom close` closes the session's tab or split in every window that has
  /// one (story 27), and no other tab; fails_when=one window keeps its tab, or a neighbour closes;
  /// why_new=#693; seam=TerminalRequests over holders; no_claim=the close's animation
  func testACloseClosesEveryTabOfTheSessionInEveryWindow() {
    let first = Holder(target: target)
    let second = Holder(target: target)
    let kept = first.terminals.addTab(for: target, sessionID: UUID())
    let closedHere = first.terminals.addTab(for: target, sessionID: created)
    let closedThere = second.terminals.addTab(for: target, sessionID: created)
    requests([first, second]).handle(.closed(session: created), from: .local)
    XCTAssertEqual(first.closed, [closedHere.id])
    XCTAssertEqual(second.closed, [closedThere.id])
    XCTAssertFalse(first.closed.contains(kept.id))
  }

  // MARK: A window opening and closing them

  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private var retags: [(UUID, String)] = []

  private func makeStore() -> AppStore {
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
    let store = AppStore(projectStore: projects, terminalsSection: section)
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { [weak self] session, tag in
        self?.retags.append((session, tag))
        return true
      },
      endLocal: { _ in true })
    store.workroomPaneSpace = CGRect(x: 0, y: 0, width: 1400, height: 800)
    return store
  }

  /// Value: protects=a `new` in a workroom opens a tab with its session, named as asked, at the
  /// strip's end, and leaves the focus on the caller (stories 24, 29); fails_when=the tab takes
  /// focus, has a new session, or isn't named; why_new=#693; seam=AppStore; no_claim=drawing
  func testANewTabHasItsSessionAndNameAndLeavesTheFocusOnTheCaller() throws {
    let store = makeStore()
    let workroom = try XCTUnwrap(store.terminalTarget(forID: workroomID))
    let callerTab = store.terminals.addTab(for: workroom, sessionID: caller)
    store.showRequestedSession(
      created, label: "dev server", in: workroom, beside: nil, on: nil)
    let tabs = store.terminals.tabs(for: workroom)
    XCTAssertEqual(tabs.map(\.terminal?.sessionID), [caller, created])
    XCTAssertEqual(tabs.last?.terminal?.userTitle, "dev server")
    XCTAssertEqual(store.terminals.focusedTab(for: workroom)?.id, callerTab.id)
    XCTAssertNil(store.terminals.split(for: workroom), "a tab, not a split")
  }

  /// A split goes beside the caller's pane, its session the new one, and the focus stays on the
  /// caller.
  func testANewSplitIsBesideTheCallerAndLeavesTheFocusOnIt() throws {
    let store = makeStore()
    let workroom = try XCTUnwrap(store.terminalTarget(forID: workroomID))
    let callerTab = store.terminals.addTab(for: workroom, sessionID: caller)
    store.showRequestedSession(created, label: nil, in: workroom, beside: callerTab.id, on: .right)
    let split = try XCTUnwrap(store.terminals.split(for: workroom))
    XCTAssertEqual(split.tabIDs.count, 2)
    XCTAssertEqual(split.tabIDs.first, callerTab.id, "on the caller's right")
    let added = try XCTUnwrap(split.tabIDs.last)
    XCTAssertEqual(store.terminals.tab(added, for: workroom)?.terminal?.sessionID, created)
    XCTAssertEqual(store.terminals.focusedTab(for: workroom)?.id, callerTab.id)
  }

  /// Value: protects=a `new` in a standalone terminal makes an unnamed group of it and the new
  /// terminal, as a split does, and tags the new session with the group (story 55); fails_when=
  /// a second standalone terminal appears, or the new session keeps the standalone tag;
  /// why_new=#693; seam=AppStore over a shared section; no_claim=the row's drawing
  func testANewInAStandaloneTerminalMakesAGroupAndTagsTheNewSessionWithIt() async throws {
    let store = makeStore()
    let standalone = try XCTUnwrap(section.addStandalone(after: nil).sidebarID)
    let target = try XCTUnwrap(store.target(for: standalone))
    let callerTab = store.terminals.addTab(for: target, sessionID: caller)
    store.selectedTargetID = standalone
    store.showRequestedSession(created, label: nil, in: target, beside: callerTab.id, on: .bottom)
    await section.regroupsSettled()
    let group = try XCTUnwrap(store.selectedTargetID)
    guard case .terminalGroup = group else { return XCTFail("\(group) is no group") }
    let grouped = try XCTUnwrap(store.target(for: group))
    XCTAssertEqual(
      store.terminals.tabs(for: grouped).map(\.terminal?.sessionID), [caller, created])
    XCTAssertNotNil(store.terminals.split(for: grouped), "split below the caller")
    let tag = try XCTUnwrap(group.targetID).encoded
    XCTAssertEqual(retags.map(\.0), [caller, created], "the caller's moved, then the new one")
    XCTAssertEqual(retags.map(\.1), [tag, tag])
    XCTAssertFalse(
      section.entries.map(\.sidebarID).contains(standalone), "the group took its place")
  }

  /// A close takes the tab without asking, the shell having gone, through the window's own close.
  func testACloseClosesTheWindowsTabWithoutAsking() throws {
    let store = makeStore()
    let workroom = try XCTUnwrap(store.terminalTarget(forID: workroomID))
    let kept = store.terminals.addTab(for: workroom, sessionID: caller)
    let closing = store.terminals.addTab(for: workroom, sessionID: created)
    store.closeRequestedTab(closing.id, in: workroom)
    XCTAssertEqual(store.terminals.tabs(for: workroom).map(\.id), [kept.id])
  }
}
