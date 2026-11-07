import DaemonConnection
import TerminalModel
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// One window's terminal tabs, held as plain values for a pane collaborator (`PaneLiveState`,
/// `ProgramStatusBinding`, `RemotePaneLinks`) to drive with no `TerminalPanes`: the states by
/// tab, and the events the collaborator raised.
@MainActor
private final class FakePaneTabs {
  private(set) var held: [TerminalTab.ID: (target: TerminalTarget.ID, state: TerminalState)] = [:]
  private(set) var events: [TerminalPanes.Event] = []

  func add(
    to target: TerminalTarget.ID, launch: TerminalLaunch = .shell, sessionID: UUID? = nil
  ) -> TerminalTab.ID {
    let id = UUID()
    held[id] = (
      target,
      TerminalState(
        defaultTitle: "Terminal", launch: launch, launchDirectory: "/start", sessionID: sessionID)
    )
    return id
  }

  /// The tab leaves the window: closed, reaped or handed to another.
  func remove(_ id: TerminalTab.ID) { held[id] = nil }

  func state(_ id: TerminalTab.ID) -> TerminalState? { held[id]?.state }

  var access: TerminalTabAccess {
    TerminalTabAccess(
      state: { [weak self] tabID, targetID in
        self?.held[tabID].flatMap { $0.target == targetID ? $0.state : nil }
      },
      holds: { [weak self] tabID, targetID in self?.held[tabID]?.target == targetID },
      mutate: { [weak self] tabID, targetID, body in
        guard var entry = self?.held[tabID], entry.target == targetID else { return }
        body(&entry.state)
        self?.held[tabID] = entry
      },
      terminals: { [weak self] in
        (self?.held ?? [:]).map { (target: $0.value.target, tab: $0.key, state: $0.value.state) }
      },
      surface: { _ in nil },
      raise: { [weak self] event in self?.events.append(event) })
  }
}

/// Holds whoever waits until it is opened.
private actor OpenGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

@MainActor
private func isolatedSessionService() -> PersistentSessionService {
  PersistentSessionService(
    probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned })
}

/// Long enough for a released read's task to land its answer, if it is going to. Keeps `owner`, the
/// collaborator, alive meanwhile, as its window's sessions do: one freed early drops its reads for
/// that reason alone, and these tests would then pass against code that cancels nothing.
private func waitForLateAnswers(keeping owner: AnyObject) async throws {
  try await Task.sleep(for: .milliseconds(100))
  withExtendedLifetime(owner) {}
}

@MainActor
final class PaneLiveStateTests: XCTestCase {
  private let target = TerminalTarget.ID.quickTerminal

  private func makeLiveState(_ tabs: FakePaneTabs) -> PaneLiveState {
    let live = PaneLiveState(
      access: tabs.access, codingAgentManager: TerminalCodingAgentManager(),
      sessionService: isolatedSessionService())
    live.readsPaneBranches = true
    live.recordUnrecognizedTool = { _ in }
    return live
  }

  /// Value: protects=a branch read in flight for a tab that left the window (close, reap, hand-off)
  /// lands nowhere; fails_when=`forget` stops cancelling the tab's branch read; why_new=the read
  /// is owned by `PaneLiveState` now, with no `TerminalPanes` to drop the tab first;
  /// seam=`resolveBranch` held on a gate. The tab is still held, so only the cancel can drop it.
  func testAForgottenTabsBranchReadLandsNowhere() async throws {
    let tabs = FakePaneTabs()
    let live = makeLiveState(tabs)
    let gate = OpenGate()
    live.resolveBranch = { path in
      await gate.wait()
      return "branch\(path)"
    }
    let tab = tabs.add(to: target)

    live.refreshBranch(forTab: tab, target: target)
    live.forget(tab)
    await gate.open()
    try await waitForLateAnswers(keeping: live)

    XCTAssertNil(tabs.state(tab)?.liveBranch, "a forgotten tab's branch read still landed")
  }

  /// Negative control for the test above: the same read, not forgotten, lands.
  func testABranchReadLandsOnItsTab() async {
    let tabs = FakePaneTabs()
    let live = makeLiveState(tabs)
    live.resolveBranch = { "branch\($0)" }
    let tab = tabs.add(to: target)

    live.refreshBranch(forTab: tab, target: target)
    await live.branchRead(forTab: tab)

    XCTAssertEqual(tabs.state(tab)?.liveBranch, "branch/start")
  }

  /// Value: protects=a slow branch read for a folder the pane has left never lands on top of the
  /// newer folder's; fails_when=a newer read stops replacing an older one; why_new=covered only
  /// through `TerminalPanes` before; seam=the first folder's read held on a gate.
  func testANewerFoldersBranchWinsOverAnOlderSlowerRead() async throws {
    let tabs = FakePaneTabs()
    let live = makeLiveState(tabs)
    let gate = OpenGate()
    live.resolveBranch = { path in
      if path == "/start" { await gate.wait() }
      return "branch\(path)"
    }
    let tab = tabs.add(to: target)

    live.refreshBranch(forTab: tab, target: target)
    live.cwdChanged("/elsewhere", tab: tab, target: target)
    await live.branchRead(forTab: tab)
    XCTAssertEqual(tabs.state(tab)?.liveBranch, "branch/elsewhere")

    await gate.open()
    try await waitForLateAnswers(keeping: live)
    XCTAssertEqual(tabs.state(tab)?.liveBranch, "branch/elsewhere", "the older read landed last")
  }
}

@MainActor
final class ProgramStatusBindingTests: XCTestCase {
  private let target = TerminalTarget.ID.workroom(project: "/p", name: "foo")

  /// Value: protects=a session's rollup lands on the tabs attached to it and no other, by way of
  /// the monitor's listener; fails_when=`follow` stops listening, or the rollup lands by target
  /// rather than by session; why_new=the binding can now be driven alone; seam=a seeded monitor.
  func testASessionsRollupLandsOnlyOnTheTabsAttachedToIt() {
    let tabs = FakePaneTabs()
    let binding = ProgramStatusBinding(
      access: tabs.access, sessionService: isolatedSessionService())
    let monitor = ProgramStatusMonitor()
    binding.monitor = monitor
    let session = UUID()
    let attached = tabs.add(to: target, sessionID: session)
    let other = tabs.add(to: target, sessionID: UUID())
    binding.follow(.local)

    monitor.seed(session, records: [ProgramStatusRecord(id: "", state: .done)])

    XCTAssertEqual(tabs.state(attached)?.programStatus, monitor.rollup(for: session))
    XCTAssertNotNil(tabs.state(attached)?.programStatus?.done)
    XCTAssertNil(tabs.state(other)?.programStatus)
  }

  /// Value: protects=a run tab is reported gone only from its own host's snapshot (#522), never
  /// from another host's or from an event that does not name it; fails_when=the host or
  /// snapshot check goes; why_new=the binding can now be driven alone; seam=an empty monitor.
  func testARunTabIsGoneOnlyWhenItsOwnHostsSnapshotLeavesItOut() {
    let tabs = FakePaneTabs()
    let binding = ProgramStatusBinding(
      access: tabs.access, sessionService: isolatedSessionService())
    binding.monitor = ProgramStatusMonitor()
    let run = tabs.add(to: target, launch: .runSession, sessionID: UUID())
    _ = tabs.add(to: target, sessionID: UUID())

    binding.applyRunStatus(
      .init(host: .remote(UUID()), sessions: [], isLaunchSnapshot: false, isSnapshot: true))
    binding.applyRunStatus(.init(host: .local, sessions: [], isLaunchSnapshot: false))
    XCTAssertEqual(tabs.events, [])

    binding.applyRunStatus(
      .init(host: .local, sessions: [], isLaunchSnapshot: false, isSnapshot: true))
    XCTAssertEqual(tabs.events, [.runSessionGone(target, run)])
  }
}

@MainActor
final class RemotePaneLinksTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "remote"), title: "remote", path: "/home/workroom/repo",
    unavailability: .remote, remoteHost: UUID())

  private func hostFiles(_ location: RepositoryLocation) -> FileProviding {
    HostFiles(
      context: FileContext(location: location, sharedLocation: nil),
      files: ["a.rb": Data("a\n".utf8), "b.rb": Data("b\n".utf8)])
  }

  /// Waits for `opened` to hold something, for up to two seconds.
  private func waitForAnOpen(_ opened: () -> [String]) async throws {
    for _ in 0..<200 where opened().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
  }

  /// Value: protects=a ⌘-click whose pane closed while the host answered opens nothing (#254);
  /// fails_when=the answer stops checking that the pane is still held; why_new=the click is
  /// owned by `RemotePaneLinks` now; seam=the host's answer held on a gate.
  func testAClickWhosePaneClosedWhileTheHostAnsweredOpensNothing() async throws {
    let tabs = FakePaneTabs()
    var opened: [String] = []
    let links = RemotePaneLinks(access: tabs.access) { file, _ in opened.append(file.path) }
    let gate = OpenGate()
    links.remoteFiles = { location in
      await gate.wait()
      return self.hostFiles(location)
    }
    let tab = tabs.add(to: target.id, sessionID: UUID())

    links.open("a.rb", tab: tab, target: target)
    tabs.remove(tab)
    await gate.open()
    try await waitForLateAnswers(keeping: links)

    XCTAssertEqual(opened, [], "a closed pane's click opened a file")
  }

  /// Negative control for the test above: the same click, from a pane still open, opens.
  func testAClickFromAnOpenPaneOpensTheFile() async throws {
    let tabs = FakePaneTabs()
    var opened: [String] = []
    let links = RemotePaneLinks(access: tabs.access) { file, _ in opened.append(file.path) }
    links.remoteFiles = { self.hostFiles($0) }
    let tab = tabs.add(to: target.id, sessionID: UUID())

    links.open("a.rb", tab: tab, target: target)
    try await waitForAnOpen { opened }

    XCTAssertEqual(opened, ["a.rb"])
  }

  /// Value: protects=a slow answer never retargets the preview after a newer click's;
  /// fails_when=a newer click stops replacing the one in flight; why_new=the click is owned by
  /// `RemotePaneLinks` now; seam=the first click's answer held on a gate.
  func testANewerClickReplacesAnOlderSlowerOne() async throws {
    let tabs = FakePaneTabs()
    var opened: [String] = []
    let links = RemotePaneLinks(access: tabs.access) { file, _ in opened.append(file.path) }
    let gate = OpenGate()
    var asks = 0
    links.remoteFiles = { location in
      asks += 1
      if asks == 1 { await gate.wait() }
      return self.hostFiles(location)
    }
    let tab = tabs.add(to: target.id, sessionID: UUID())

    links.open("a.rb", tab: tab, target: target)
    links.open("b.rb", tab: tab, target: target)
    try await waitForAnOpen { opened }
    await gate.open()
    try await waitForLateAnswers(keeping: links)

    XCTAssertEqual(opened, ["b.rb"])
  }
}
