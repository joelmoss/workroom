import AppKit
import DaemonConnection
import TerminalModel
import WorkroomDomain
import WorkroomWire
import XCTest

@testable import Workroom

/// A terminal's name and its session's label are one name (#694): a tab renamed here labels its
/// session on its host's daemon, and a label the daemon tells renames every tab of the session,
/// never told back; a snapshot catches a Mac up without clearing a name it has.
@MainActor
final class SessionLabelsTests: XCTestCase {
  private let session = UUID(uuidString: "C0FFEE00-1111-4222-8333-44445555BEEF")!
  private let workroomID = TargetID.workroom(project: "/p", name: "a")
  private let remoteHost = UUID(uuidString: "4C0F5F2E-2B49-4C4D-9C1E-6A1B2B3C0D4E")!

  /// What the daemon was asked: each `session.label`, in order.
  private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(HostID, UUID, String?)] = []
    /// The answers given in turn, the last one ever after.
    var answers: [Result<TerminalLabelOutcome, Error>] = [.success(.labelled(changed: true))]

    func record(_ host: HostID, _ session: UUID, _ label: String?) throws -> TerminalLabelOutcome {
      let answer = lock.withLock { () -> Result<TerminalLabelOutcome, Error> in
        calls.append((host, session, label))
        return answers.count > 1 ? answers.removeFirst() : answers[0]
      }
      return try answer.get()
    }

    var labels: [String?] { lock.withLock { calls.map(\.2) } }
    var hosts: [HostID] { lock.withLock { calls.map(\.0) } }
  }

  @MainActor
  private final class Holder: TerminalRequestHolder {
    let terminals: TerminalPanes
    let target: TerminalTarget
    var isKeyHolder = false

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

    func isShowingTarget(_ targetID: TerminalTarget.ID) -> Bool { true }

    func showRequestedSession(
      _ session: UUID, label: String?, caller: TerminalTab.ID, in target: TerminalTarget,
      split edge: PaneEdge?, unplaced: @escaping () -> Void
    ) {}

    func closeRequestedTab(_ tabID: TerminalTab.ID, in target: TerminalTarget) {}
  }

  private var target: TerminalTarget {
    TerminalTarget(id: workroomID, title: "a", path: "/tmp", isMissing: false)
  }

  private var sent = Sent()
  private var saved:
    (
      holders: () -> [any TerminalRequestHolder],
      send: @Sendable (HostID, UUID, String?) async throws -> TerminalLabelOutcome,
      sleep: @Sendable (Duration) async throws -> Void, watches: Bool
    )?

  /// `SessionLabels.shared`, which every window's renames reach, over `holders` and `sent`.
  private func labels(_ holders: [Holder]) -> SessionLabels {
    let labels = SessionLabels.shared
    if saved == nil {
      saved = (labels.holders, labels.send, labels.sleep, labels.watchesHosts)
    }
    labels.holders = { holders }
    let sent = self.sent
    labels.send = { host, session, label in try sent.record(host, session, label) }
    labels.sleep = { _ in }
    labels.watchesHosts = true
    return labels
  }

  override func tearDown() async throws {
    await SessionLabels.shared.settled()
    if let saved {
      SessionLabels.shared.holders = saved.holders
      SessionLabels.shared.send = saved.send
      SessionLabels.shared.sleep = saved.sleep
      SessionLabels.shared.watchesHosts = saved.watches
    }
    try await super.tearDown()
  }

  private func name(_ holder: Holder, _ tab: TerminalTab) -> String? {
    holder.terminals.tab(tab.id, for: holder.target)?.terminal?.userTitle
  }

  // MARK: The app to the daemon

  /// Value: protects=a tab renamed here labels its session on its host's daemon, and a cleared
  /// name clears it (story 29); fails_when=a rename stays this Mac's, or a clear sends a name;
  /// why_new=#694; seam=SessionLabels.send; no_claim=the wire (TerminalInputConnectionTests)
  func testARenameLabelsTheSessionAndAClearClearsIt() async {
    let holder = Holder(target: target)
    let labels = labels([holder])
    let tab = holder.terminals.addTab(for: target, sessionID: session)
    holder.terminals.setUserTitle("  web  ", forTab: tab.id, in: target)
    await labels.settled()
    holder.terminals.setUserTitle("", forTab: tab.id, in: target)
    await labels.settled()
    holder.terminals.setUserTitle("", forTab: tab.id, in: target)
    await labels.settled()
    XCTAssertEqual(sent.labels, ["web", nil], "trimmed; a name it has already sends nothing")
    XCTAssertEqual(sent.hosts, [.local, .local])
  }

  /// A remote workroom's tab labels its session on its host's daemon, not this Mac's.
  func testARemoteTabsRenameGoesToItsHost() async {
    var remote = target
    remote.remoteHost = remoteHost
    let holder = Holder(target: remote)
    let labels = labels([holder])
    let tab = holder.terminals.addTab(for: remote, sessionID: session)
    holder.terminals.setUserTitle("api", forTab: tab.id, in: remote)
    await labels.settled()
    XCTAssertEqual(sent.hosts, [.remote(remoteHost)])
    XCTAssertEqual(sent.labels, ["api"])
  }

  /// A rename the daemon refuses as busy (a hand-off under way) or can't be reached for is tried
  /// again; one for a session that has ended is not; and a later rename is told in place of an
  /// earlier one still waiting to be.
  func testARenameIsRetriedWhileTheDaemonIsBusyAndALaterOneWins() async {
    let holder = Holder(target: target)
    let labels = labels([holder])
    let tab = holder.terminals.addTab(for: target, sessionID: session)
    sent.answers = [
      .success(.refused(kind: "Busy", message: "handing off")),
      .failure(HostConnectionError.connectionLost),
      .success(.labelled(changed: true)),
    ]
    holder.terminals.setUserTitle("web", forTab: tab.id, in: target)
    await labels.settled()
    XCTAssertEqual(sent.labels, ["web", "web", "web"])

    sent.answers = [.success(.refused(kind: "TargetNotFound", message: "gone"))]
    holder.terminals.setUserTitle("api", forTab: tab.id, in: target)
    await labels.settled()
    XCTAssertEqual(sent.labels.count, 4, "an ended session isn't asked again")

    // The first is refused and waits out its retry, by which time the second has been asked:
    // only the second is told, and the first is never tried again.
    let gate = AsyncStream<Void>.makeStream()
    labels.sleep = { _ in for await _ in gate.stream { return } }
    sent.answers = [
      .success(.refused(kind: "Busy", message: "handing off")),
      .success(.labelled(changed: true)),
    ]
    holder.terminals.setUserTitle("one", forTab: tab.id, in: target)
    for _ in 0..<1000 where sent.labels.count < 5 { await Task.yield() }
    XCTAssertEqual(sent.labels.last, "one", "fixture: the first was tried")
    holder.terminals.setUserTitle("two", forTab: tab.id, in: target)
    for _ in 0..<1000 where sent.labels.count < 6 { await Task.yield() }
    gate.continuation.yield()
    gate.continuation.finish()
    await labels.settled()
    XCTAssertEqual(Array(sent.labels.dropFirst(4)), ["one", "two"])
  }

  /// A tab's session is made with its label: none for a fresh tab, which shows its default (never
  /// its numbered "Terminal 2"), and a renamed tab's surface makes it again under its new name.
  func testASessionIsMadeWithItsTabsLabel() {
    let holder = Holder(target: target)
    let tab = holder.terminals.addTab(for: target, sessionID: session)
    let title = {
      holder.terminals.surface(of: tab.id)?.attachment.metadata
        .first { $0.key == SessionMetadataKey.title }?.value
    }
    XCTAssertNil(title(), "a numbered default names nothing")
    holder.terminals.applySessionLabel("db", forTab: tab.id, in: target)
    XCTAssertEqual(title(), "db")
  }

  // MARK: The daemon to the app

  /// Value: protects=a label set through the API renames every tab of its session in every
  /// window, and is never told back (no loop); fails_when=a window keeps the old name, a tab of
  /// another host's session is renamed, or the app labels the session again; why_new=#694;
  /// seam=SessionLabels over holders; no_claim=drawing
  func testALabelRenamesEveryTabOfItsSessionAndIsNotToldBack() async {
    let first = Holder(target: target)
    let second = Holder(target: target)
    var remote = target
    remote.remoteHost = remoteHost
    let elsewhere = Holder(target: remote)
    let labels = labels([first, second, elsewhere])
    let one = first.terminals.addTab(for: target, sessionID: session)
    let two = second.terminals.addTab(for: target, sessionID: session)
    let other = first.terminals.addTab(for: target, sessionID: UUID())
    let theirs = elsewhere.terminals.addTab(for: remote, sessionID: session)
    labels.handle(.labelled(session: session, label: "api"), from: .local)
    XCTAssertEqual(name(first, one), "api")
    XCTAssertEqual(name(second, two), "api")
    XCTAssertEqual(first.terminals.tab(one.id, for: target)?.title, "api", "the tab shows it")
    XCTAssertNil(name(first, other))
    XCTAssertNil(name(elsewhere, theirs), "the same id on another host is another session")

    labels.handle(.labelled(session: session, label: nil), from: .local)
    XCTAssertNil(name(first, one), "cleared: its default shows")
    XCTAssertNil(name(second, two))
    await labels.settled()
    XCTAssertEqual(sent.labels, [], "nothing told back")
  }

  /// `workroom new --title` names its tab by the session's label, which the daemon has already.
  func testANewSessionsTitleNamesItsTabAndIsNotToldBack() async {
    let holder = Holder(target: target)
    let labels = labels([holder])
    let tab = holder.openRequestedPane(
      session, label: "dev server", in: target, beside: nil, on: nil)
    XCTAssertEqual(name(holder, tab), "dev server")
    await labels.settled()
    XCTAssertEqual(sent.labels, [])
  }

  /// Value: protects=a Mac that wasn't listening catches up from the snapshot, and a name only it
  /// has (a tab named before #694, whose label is still "Terminal 2") is kept and told, never
  /// cleared; fails_when=the snapshot wipes a name or ignores a newer one; why_new=#694;
  /// seam=SessionLabels over holders; no_claim=the snapshot's timing
  func testASnapshotCatchesUpAndNeverClearsANameOnlyThisMacHas() async {
    let holder = Holder(target: target)
    let labels = labels([holder])
    let tab = holder.terminals.addTab(for: target, sessionID: session)
    labels.handle(.listed(session: session, label: "api"), from: .local)
    XCTAssertEqual(name(holder, tab), "api", "a name the daemon has wins")
    await labels.settled()
    XCTAssertEqual(sent.labels, [])

    for none in ["Terminal 2", nil] as [String?] {
      labels.handle(.listed(session: session, label: none), from: .local)
      XCTAssertEqual(name(holder, tab), "api", "\(String(describing: none)) clears nothing")
      await labels.settled()
    }
    XCTAssertEqual(sent.labels, ["api", "api"], "the name told where the daemon has none")

    let unnamed = UUID()
    _ = holder.terminals.addTab(for: target, sessionID: unnamed)
    labels.handle(.listed(session: unnamed, label: nil), from: .local)
    await labels.settled()
    XCTAssertEqual(sent.labels.count, 2, "no name on either side: nothing to tell")
  }

  /// A snapshot is older than a rename of this Mac's still on its way, which it never undoes.
  func testASnapshotGivesWayToARenameOnItsWay() async {
    let holder = Holder(target: target)
    let labels = labels([holder])
    let tab = holder.terminals.addTab(for: target, sessionID: session)
    let gate = AsyncStream<Void>.makeStream()
    labels.send = { [sent] host, session, label in
      for await _ in gate.stream { break }
      return try sent.record(host, session, label)
    }
    holder.terminals.setUserTitle("mine", forTab: tab.id, in: target)
    labels.handle(.listed(session: session, label: "old"), from: .local)
    XCTAssertEqual(name(holder, tab), "mine")
    gate.continuation.yield()
    gate.continuation.finish()
    await labels.settled()
    XCTAssertEqual(sent.labels, ["mine"])
  }

  // MARK: The rule

  /// A tab's session label is the user's name, else a name the app shows ("Run"), never a
  /// numbered default; a label names a tab as it is, but the name it already shows unnamed.
  func testATabsLabelIsItsShownNameAndALabelNamesItSo() {
    func state(_ title: String, user: String? = nil) -> TerminalState {
      var state = TerminalState(
        defaultTitle: title, launch: TerminalLaunch(isRunSession: false, runsCommand: false),
        launchDirectory: "/tmp")
      state.userTitle = user
      return state
    }
    XCTAssertNil(state("Terminal 2").sessionLabel)
    XCTAssertEqual(state("Terminal 2", user: "web").sessionLabel, "web")
    XCTAssertEqual(state("Run").sessionLabel, "Run")
    XCTAssertEqual(state("Run", user: "dev").sessionLabel, "dev")

    XCTAssertEqual(state("Terminal 2").userTitle(forLabel: " web "), "web")
    XCTAssertNil(state("Terminal 2").userTitle(forLabel: ""))
    XCTAssertNil(state("Terminal 2").userTitle(forLabel: nil))
    XCTAssertEqual(
      state("Terminal 2").userTitle(forLabel: "Terminal 2"), "Terminal 2",
      "a numbered label set on purpose is a name")
    XCTAssertNil(state("Run").userTitle(forLabel: "Run"), "the name it shows unnamed")
  }
}
