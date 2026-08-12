import XCTest

@testable import Workroom

/// Offer state for restored panes (issue #145).
///
/// The two properties worth pinning are both about damage: an offer must not fight with a diagnosis
/// over one tab, and it must not be spendable twice — the action starts a **billed** agent session.
@MainActor
final class AgentResumeCoordinatorTests: XCTestCase {
  private var home: URL!
  private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUpWithError() throws {
    try super.setUpWithError()
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("agent-resume-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
    try super.tearDownWithError()
  }

  private func makeCoordinator() -> AgentResumeCoordinator {
    AgentResumeCoordinator(index: AgentSessionIndex(roots: AgentSessionIndex.Roots(home: home)))
  }

  private func seedClaude(cwd: String) throws {
    let url = home.appendingPathComponent(
      ".claude/projects/\(AgentSessionIndex.claudeSlugHint(for: cwd))/session.jsonl")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (#"{"type":"user","cwd":"\#(cwd)"}"# + "\n").write(
      to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: savedAt], ofItemAtPath: url.path)
  }

  private func pane(_ cwd: String) -> TerminalSessions.RestoredTerminal {
    TerminalSessions.RestoredTerminal(tabID: UUID(), targetID: "wr|/p|foo", cwd: cwd)
  }

  /// Discovery hops to a background queue and back, so wait for the offer rather than assuming.
  private func waitForOffer(
    _ coordinator: AgentResumeCoordinator, tab: TerminalTab.ID, timeout: TimeInterval = 5
  ) -> Set<AgentBackend>? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let offer = coordinator.offers[tab] { return offer }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return coordinator.offers[tab]
  }

  // MARK: Offers
  //
  // Every `settle()` call below deliberately uses the shared helper's default (no early-exit
  // condition): each one is proving a NEGATIVE ("no offer must land") — early-exiting on any
  // observable signal would risk stopping the wait before a real regression (an offer landing
  // late) has a chance to show up, which is exactly backwards for what these are checking.

  func testARestoredPaneWithHistoryGetsAnOffer() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)

    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertEqual(waitForOffer(coordinator, tab: restored.tabID), [.claude])
  }

  func testAPaneWithNoHistoryGetsNothing() {
    let coordinator = makeCoordinator()
    let restored = pane("/tmp/empty")

    coordinator.discover([restored], savedAt: savedAt)
    settle()
    XCTAssertNil(coordinator.offers[restored.tabID])
  }

  func testDiscoveringNothingIsANoOp() {
    let coordinator = makeCoordinator()
    coordinator.discover([], savedAt: savedAt)
    settle(0.1)
    XCTAssertTrue(coordinator.offers.isEmpty)
  }

  /// The fixture default: no index means discovery does nothing at all, which is what keeps the
  /// existing UI tests off the developer's real `~/.claude`.
  func testANilIndexDisablesDiscoveryEntirely() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = AgentResumeCoordinator(index: nil)
    let restored = pane(cwd)

    coordinator.discover([restored], savedAt: savedAt)
    settle()
    XCTAssertNil(coordinator.offers[restored.tabID])
  }

  // MARK: Spending the offer

  /// **CRITICAL REGRESSION.** `consume` removes the offer BEFORE returning the command.
  ///
  /// Without that, a double-click — or SwiftUI evaluating the button's action twice — starts two
  /// agent sessions, and agent sessions cost money. The second call returning nil is the button
  /// being spent, not a failure.
  func testConsumeIsAtomicSoADoubleClickCannotSpendTwice() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: restored.tabID))

    let first = coordinator.consume(tab: restored.tabID, backend: .claude)
    let second = coordinator.consume(tab: restored.tabID, backend: .claude)

    XCTAssertEqual(first?.arguments, ["--resume"])
    XCTAssertNil(second, "the offer is spent")
    XCTAssertNil(coordinator.offers[restored.tabID], "and the button is gone")
  }

  func testConsumingAnAgentThatWasNotOfferedReturnsNothing() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertEqual(waitForOffer(coordinator, tab: restored.tabID), [.claude])

    XCTAssertNil(coordinator.consume(tab: restored.tabID, backend: .codex))
    XCTAssertNotNil(coordinator.offers[restored.tabID], "and Claude's offer survives")
  }

  // MARK: Lifecycle

  /// **REGRESSION.** Discovery is async, so an offer can land after the user has started typing.
  /// Appending `claude --resume` plus Return to a half-typed line runs something nobody asked for.
  func testTypingInThePaneBeforeTheOfferLandsSuppressesIt() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)

    coordinator.discover([restored], savedAt: savedAt)
    coordinator.paneReceivedInput(tab: restored.tabID)
    settle()

    XCTAssertNil(coordinator.offers[restored.tabID], "a dirty input line must not be typed into")
  }

  func testTypingAfterTheOfferLandsRemovesIt() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: restored.tabID))

    coordinator.paneReceivedInput(tab: restored.tabID)
    XCTAssertNil(coordinator.offers[restored.tabID])
    XCTAssertNil(coordinator.consume(tab: restored.tabID, backend: .claude))
  }

  func testAClosedPaneDropsItsOfferAndCannotBeResurrectedByALateScan() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)

    coordinator.discover([restored], savedAt: savedAt)
    coordinator.tabClosed(restored.tabID)
    settle()

    XCTAssertNil(coordinator.offers[restored.tabID])
  }

  func testCancellingDiscoveryPublishesNothing() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)

    coordinator.discover([restored], savedAt: savedAt)
    coordinator.cancelDiscovery()
    settle()

    XCTAssertNil(coordinator.offers[restored.tabID])
  }

  /// **REGRESSION.** The suppression set is cleared once a scan lands.
  ///
  /// It only exists to stop `publish` re-offering a pane that closed mid-scan. `tabClosed` fires for
  /// EVERY tab closed in the process, not just restored ones, so never pruning it meant it grew for
  /// the life of the app — and the comment claiming otherwise was what hid that.
  func testClosingUnrelatedTabsAfterAScanDoesNotAccumulateState() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: restored.tabID))

    // Panes that have nothing to do with this restore, closed later in the session.
    for _ in 0..<50 { coordinator.tabClosed(UUID()) }

    // A fresh restore in the same process still offers — nothing stale is suppressing it.
    let second = pane(cwd)
    coordinator.discover([second], savedAt: savedAt)
    XCTAssertEqual(waitForOffer(coordinator, tab: second.tabID), [.claude])
  }

  /// **REGRESSION.** A pane whose directory moved since discovery does not resume.
  ///
  /// The offer was matched against the directory the pane was RESTORED into. A shell hook (`direnv`,
  /// a `cd` in `.zshrc`, a project activator) can move it before the user touches the keyboard, so
  /// nothing trips the pristine guard. Resuming there would open a picker listing another project's
  /// conversations — the confident wrong answer this whole feature refuses to give.
  func testAPaneThatChangedDirectorySinceDiscoveryDoesNotResume() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: restored.tabID))

    XCTAssertNil(
      coordinator.consume(tab: restored.tabID, backend: .claude, liveCwd: "/tmp/somewhere-else"),
      "a moved pane must not resume another directory's history")
    XCTAssertNil(coordinator.offers[restored.tabID], "and the offer is spent either way")
  }

  func testAPaneStillInItsRestoredDirectoryResumes() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: restored.tabID))

    XCTAssertEqual(
      coordinator.consume(tab: restored.tabID, backend: .claude, liveCwd: cwd)?.arguments,
      ["--resume"])
  }

  /// A pane that has not reported a cwd yet still resumes — the guard refuses a MOVE, not an
  /// unknown. Refusing on nil would make the button dead until shell integration reports in.
  func testAPaneWithNoReportedCwdStillResumes() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let restored = pane(cwd)
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: restored.tabID))

    XCTAssertNotNil(coordinator.consume(tab: restored.tabID, backend: .claude, liveCwd: nil))
  }

  // MARK: Independence from the diagnosis banner

  /// **CRITICAL REGRESSION.** An offer and a diagnosis are separate state, in both orders.
  ///
  /// The tempting design was a sixth `AgentBannerState` case. `TerminalAgentManager.banners` is one
  /// slot per tab, so that would mean: a restored pane offers Resume, the user runs a command, it
  /// fails, `commandFinished` overwrites the offer and it never comes back. And symmetrically — a
  /// scan finishing late would stomp a diagnosis the user is waiting on.
  func testAnOfferAndADiagnosisCoexistOnOneTabInEitherOrder() throws {
    let cwd = "/tmp/project"
    try seedClaude(cwd: cwd)
    let coordinator = makeCoordinator()
    let manager = TerminalAgentManager(
      runner: StubAgentRunner(envelope: ""), featureEnabled: { true })
    let restored = pane(cwd)
    let failure = FailedCommand(
      command: "npm test", cwd: cwd, exitCode: 1, shell: "zsh", output: "boom", isRunTab: false,
      isRemote: false)

    // Offer first, then a failing command.
    coordinator.discover([restored], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: restored.tabID))
    manager.commandFinished(tab: restored.tabID, target: restored.targetID, failure: failure)

    XCTAssertNotNil(manager.banners[restored.tabID], "the diagnosis is there")
    XCTAssertNotNil(coordinator.offers[restored.tabID], "and it did not evict the offer")

    // And the other way round: a second pane that fails first, then gets its offer.
    let other = pane(cwd)
    manager.commandFinished(tab: other.tabID, target: other.targetID, failure: failure)
    coordinator.discover([other], savedAt: savedAt)
    XCTAssertNotNil(waitForOffer(coordinator, tab: other.tabID))

    XCTAssertNotNil(manager.banners[other.tabID], "the late offer did not stomp the diagnosis")
    XCTAssertNotNil(coordinator.offers[other.tabID])
  }
}
