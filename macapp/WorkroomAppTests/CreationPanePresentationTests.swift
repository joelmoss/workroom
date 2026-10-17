import Foundation
import HostDrivers
import WorkroomDomain
import XCTest

@testable import Workroom

/// What the creation pane (#483) says, read off its run without drawing it: the timing column, the
/// captions, the header, the failure footer, the VoiceOver label of each row, keyboard routing and
/// when an open log follows new output.
@MainActor
final class CreationPanePresentationTests: XCTestCase {
  private typealias P = CreationPanePresentation
  private let start = Date(timeIntervalSinceReferenceDate: 1000)

  private func step(
    _ state: CreationStep.State, ran seconds: TimeInterval? = nil, title: String = "Create worktree"
  ) -> CreationStep {
    var step = CreationStep(id: "worktree", title: title)
    step.state = state
    if let seconds {
      step.startedAt = start
      if state != .running, state != .waitingForUser { step.endedAt = start + seconds }
    }
    return step
  }

  // MARK: Timing column

  /// Value: protects=D19, a finished step's duration reads "<1s" under a second, whole seconds
  /// under a minute, then minutes and seconds; fails_when="0s" for a quick step, fractions, or
  /// seconds past 59; no_claim=the column's drawing
  func testDurationsReadAsTheSpecWritesThem() {
    XCTAssertEqual(P.duration(0.4, finished: true), "<1s")
    XCTAssertEqual(P.duration(0.4, finished: false), "0s", "a running step ticks from 0s")
    XCTAssertEqual(P.duration(4.9, finished: true), "4s")
    XCTAssertEqual(P.duration(59.99, finished: true), "59s")
    XCTAssertEqual(P.duration(72, finished: true), "1m 12s")
    XCTAssertEqual(P.duration(3600, finished: true), "60m 0s")
  }

  /// Value: protects=the timing column per state, Skipped, Waiting for you, the live and the final
  /// duration, nothing for a pending step; fails_when=a pending step shows a time, a waiting step
  /// ticks, or a skipped one shows a duration; no_claim=the TimelineView's tick
  func testTheTimingColumnPerState() {
    XCTAssertNil(P.trailing(for: step(.pending), now: start))
    XCTAssertEqual(P.trailing(for: step(.running, ran: 0), now: start + 7.5), "7s")
    XCTAssertEqual(
      P.trailing(for: step(.waitingForUser, ran: 0), now: start + 30), "Waiting for you")
    XCTAssertEqual(P.trailing(for: step(.done, ran: 0.2), now: start + 100), "<1s")
    XCTAssertEqual(P.trailing(for: step(.warning("x"), ran: 4), now: start + 100), "4s")
    XCTAssertEqual(P.trailing(for: step(.failed, ran: 72), now: start + 100), "1m 12s")
    XCTAssertEqual(P.trailing(for: step(.skipped(reason: nil)), now: start), "Skipped")
    XCTAssertEqual(
      P.trailing(for: step(.skipped(reason: "No setup script")), now: start), "Skipped")
    XCTAssertNil(
      P.trailing(for: step(.failed), now: start), "a step failed before it began has no time")
  }

  // MARK: Captions and header

  /// Value: protects=D11, a skipped step with a reason and every warning show it as a caption;
  /// steps skipped implicitly and every other state show none; fails_when=an implicit skip gets an
  /// empty caption, or a warning's text is lost; no_claim=the caption's colour
  func testCaptionsAreTheReasonOrTheWarning() {
    XCTAssertEqual(
      P.caption(for: step(.skipped(reason: "No remote to fetch from"))), "No remote to fetch from")
    XCTAssertEqual(P.caption(for: step(.warning("origin unreachable"))), "origin unreachable")
    XCTAssertNil(P.caption(for: step(.skipped(reason: nil))))
    XCTAssertNil(P.caption(for: step(.skipped(reason: ""))))
    XCTAssertNil(P.caption(for: step(.warning(""))))
    for state: CreationStep.State in [.pending, .running, .waitingForUser, .done, .failed] {
      XCTAssertNil(P.caption(for: step(state)), "\(state)")
    }
  }

  /// Value: protects=D5, the header reads "New workroom" until the name lands, then the name, over
  /// "<project> · <destination>"; fails_when=the subtitle drops the destination or the title keeps
  /// "New workroom" after the name; no_claim=none beyond protects
  func testTheHeaderNamesTheWorkroomAndWhereItGoes() {
    let run = CreationRun(
      project: Project(path: "/code/acme-web", vcs: "git", workrooms: []), kind: .boxd,
      splitAnchor: nil, previousSelection: nil)
    XCTAssertEqual(P.title(of: run), "New workroom")
    XCTAssertEqual(P.subtitle(of: run), "acme-web · boxd")
    run.setName("quiet-otter")
    XCTAssertEqual(P.title(of: run), "quiet-otter")
    let local = CreationRun(
      project: Project(path: "/code/acme-web", vcs: "git", workrooms: []), kind: .local,
      splitAnchor: nil, previousSelection: nil)
    XCTAssertEqual(P.subtitle(of: local), "acme-web · This Mac")
  }

  // MARK: Accessibility

  /// Value: protects=each row's VoiceOver label is "<title>, <state>" plus its final duration once
  /// finished, and never the ticking time; fails_when=a running row's label changes every second, or
  /// a finished row omits its time; no_claim=what VoiceOver actually speaks
  func testEachRowsLabelIsItsTitleStateAndFinalDuration() {
    XCTAssertEqual(P.accessibilityLabel(for: step(.pending)), "Create worktree, not started")
    XCTAssertEqual(P.accessibilityLabel(for: step(.running, ran: 0)), "Create worktree, running")
    XCTAssertEqual(
      P.accessibilityLabel(for: step(.waitingForUser, ran: 0)), "Create worktree, waiting for you")
    XCTAssertEqual(
      P.accessibilityLabel(for: step(.done, ran: 0.3)), "Create worktree, done, under a second")
    XCTAssertEqual(
      P.accessibilityLabel(for: step(.warning("x"), ran: 1)),
      "Create worktree, done with a warning, 1 second")
    XCTAssertEqual(
      P.accessibilityLabel(for: step(.failed, ran: 72)),
      "Create worktree, failed, 1 minute 12 seconds")
    XCTAssertEqual(
      P.accessibilityLabel(for: step(.skipped(reason: "x"))), "Create worktree, skipped")
  }

  /// Value: protects=D17's three announcements, the setup sheet, a failure naming its step, and
  /// success naming the workroom; fails_when=a failure without a name says nothing useful or names
  /// the wrong step; no_claim=when they are posted (CreationFlowTests) or that VoiceOver speaks them
  func testTheThreeAnnouncements() {
    XCTAssertEqual(P.setupAnnouncement(for: .boxd), "boxd needs setting up")
    XCTAssertEqual(P.setupAnnouncement(for: .exeDev), "exe.dev needs setting up")
    let run = CreationRun(
      project: Project(path: "/p", vcs: "git", workrooms: []), kind: .local, splitAnchor: nil,
      previousSelection: nil)
    run.begin("worktree")
    run.fail(.failedBeforeWorkroom(message: "boom"))
    XCTAssertEqual(
      P.failureAnnouncement(for: run), "Couldn't create the workroom: Create worktree failed")
    run.setName("calm-river")
    XCTAssertEqual(
      P.failureAnnouncement(for: run), "Couldn't create calm-river: Create worktree failed")
    XCTAssertEqual(P.successAnnouncement(name: "calm-river"), "calm-river is ready")
  }

  // MARK: Failure footer

  /// Value: protects=D3/D12, each failure's reason headline, its buttons in order and its default;
  /// fails_when=a left-behind machine offers Try Again, a setup-script failure offers Close, or the
  /// headline loses the message; no_claim=the buttons' actions (CreationFlowTests)
  /// Value: protects=a failed setup script's footer says "setup script failed" once, with the CLI's
  /// own message (`errs.ErrSetup`, as in testdata/contracts/create-setup-failed.json); fails_when=the
  /// footer repeats it; no_claim=the footer's drawing
  func testASetupScriptFailureFromTheCLISaysSoOnce() {
    XCTAssertEqual(
      P.footer(
        for: .setupScriptFailed(
          message: "setup script failed: /Users/dev/src/app/scripts/workroom_setup returned a "
            + "non-zero exit code"))?.reason,
      "The setup script failed: /Users/dev/src/app/scripts/workroom_setup returned a non-zero "
        + "exit code")
  }

  func testEachFailureOffersItsOwnFooter() {
    XCTAssertNil(P.footer(for: .running))
    XCTAssertNil(P.footer(for: .succeeded))
    XCTAssertNil(P.footer(for: .cancelled))
    XCTAssertEqual(
      P.footer(for: .failedBeforeWorkroom(message: "worktree exists")),
      .init(
        reason: "Couldn't create the workroom: worktree exists", primary: .tryAgain,
        secondary: .close))
    XCTAssertEqual(
      P.footer(for: .setupScriptFailed(message: "exit status 1")),
      .init(
        reason: "The setup script failed: exit status 1", primary: .openAnyway,
        secondary: .deleteWorkroom))
    XCTAssertEqual(
      P.footer(for: .remoteFailed(message: "clone failed", leftBehind: false)),
      .init(
        reason: "Couldn't create the workroom: clone failed", primary: .tryAgain,
        secondary: .close))
    XCTAssertEqual(
      P.footer(for: .remoteFailed(message: "clone failed", leftBehind: true)),
      .init(
        reason: "Couldn't create the workroom, and its machine is still running: clone failed",
        primary: .deleteWorkroom, secondary: .close))
    XCTAssertEqual(
      [P.Action.tryAgain, .close, .openAnyway, .deleteWorkroom].map(\.title),
      ["Try Again", "Close", "Open Anyway", "Delete Workroom"])
  }

  /// Value: protects=D16, Escape answers only where Close is shown; fails_when=Escape triggers
  /// Delete Workroom or Open Anyway; no_claim=focus scoping (a view concern)
  func testEscapeAnswersOnlyAClose() {
    XCTAssertEqual(P.footer(for: .failedBeforeWorkroom(message: "x"))?.escapeAction, .close)
    XCTAssertNil(P.footer(for: .setupScriptFailed(message: "x"))?.escapeAction)
    XCTAssertEqual(
      P.footer(for: .remoteFailed(message: "x", leftBehind: true))?.escapeAction, .close)
  }

  // MARK: Keyboard

  /// Value: protects=D16 and D9, Up/Down move between rows without wrapping, Space toggles, Right
  /// expands (collapsing any other), Left collapses; fails_when=focus wraps, two rows end expanded,
  /// or Left collapses another row; no_claim=the focus ring
  func testKeysMoveFocusAndExpandOneRowAtATime() {
    let rows = ["fetch", "worktree", "script"]
    func key(_ key: P.Key, _ focused: String, _ expanded: String?) -> P.KeyResult {
      P.handle(key, focused: focused, expanded: expanded, rows: rows)
    }
    XCTAssertEqual(key(.down, "fetch", nil), .init(focused: "worktree", expanded: nil))
    XCTAssertEqual(key(.down, "script", nil), .init(focused: "script", expanded: nil))
    XCTAssertEqual(key(.up, "worktree", "script"), .init(focused: "fetch", expanded: "script"))
    XCTAssertEqual(key(.up, "fetch", nil), .init(focused: "fetch", expanded: nil))
    XCTAssertEqual(
      key(.space, "worktree", "fetch"), .init(focused: "worktree", expanded: "worktree"))
    XCTAssertEqual(key(.space, "worktree", "worktree"), .init(focused: "worktree", expanded: nil))
    XCTAssertEqual(key(.right, "script", "fetch"), .init(focused: "script", expanded: "script"))
    XCTAssertEqual(key(.right, "script", "script"), .init(focused: "script", expanded: "script"))
    XCTAssertEqual(key(.left, "script", "script"), .init(focused: "script", expanded: nil))
    XCTAssertEqual(key(.left, "script", "fetch"), .init(focused: "script", expanded: "fetch"))
  }

  // MARK: Sidebar

  /// Value: protects=5a's sidebar row, a failed create's step circle turns into the failed mark
  /// and a running one doesn't; fails_when=a failed create still reads as in progress; no_claim=the
  /// circle's drawing
  func testAFailedCreatesRowReadsAsFailed() {
    let store = AppStore()
    let run = CreationRun(
      project: Project(path: "/proj", vcs: "git", workrooms: []), kind: .boxd, splitAnchor: nil,
      previousSelection: nil)
    store.register(run)
    let pane = SidebarID.creation(project: "/proj", id: run.id)
    run.begin("repository")
    XCTAssertEqual(store.createStep(for: pane)?.failed, false)
    run.fail(.remoteFailed(message: "x", leftBehind: false))
    XCTAssertEqual(store.createStep(for: pane)?.failed, true)
    XCTAssertEqual(store.createStep(for: pane)?.label, "Check repository")
  }

  // MARK: Open log layout

  /// Value: protects=D9, an open log takes the pane's room left after the header and rows (so the
  /// column is exactly the pane's height and the rows below sit on its bottom edge), is only as tall
  /// as its lines when they are fewer, and in a short pane shrinks to its 3-line minimum, past which
  /// the column outgrows the pane and scrolls; fails_when=the log grows to its content and pushes
  /// the rows below out of the pane, or a short pane squeezes the log under its minimum;
  /// no_claim=the drawing (measured heights stand in for SwiftUI's layout)
  func testAnOpenLogFillsThePaneAndPinsTheRowsBelow() {
    let minimum: CGFloat = 68
    func layout(pane: CGFloat, fixed: CGFloat, lines: CGFloat) -> P.OpenLogLayout {
      P.openLogLayout(pane: pane, fixed: fixed, logContent: lines, minimum: minimum)
    }
    // A long log in a tall pane: the log takes the room, the column fills the pane exactly.
    XCTAssertEqual(
      layout(pane: 700, fixed: 300, lines: 5000), .init(column: 700, log: 400))
    // A short log: only as tall as its lines; the column still fills the pane, rows below pinned.
    XCTAssertEqual(layout(pane: 700, fixed: 300, lines: 120), .init(column: 700, log: 120))
    // Fewer than three lines: still the minimum.
    XCTAssertEqual(layout(pane: 700, fixed: 300, lines: 20), .init(column: 700, log: 68))
    // A short pane: the log stops at its minimum and the column outgrows the pane, so it scrolls.
    XCTAssertEqual(layout(pane: 330, fixed: 300, lines: 5000), .init(column: 368, log: 68))
  }

  // MARK: Following new output

  /// Value: protects=D10, an open log counts as at its bottom (so it follows) only within a couple of
  /// points of its end, and a log shorter than its frame is always at its bottom; fails_when=a log
  /// scrolled up keeps jumping down, or a short log shows Jump to latest; no_claim=the scroll itself
  func testALogFollowsOnlyAtItsBottom() {
    XCTAssertTrue(P.isAtBottom(offset: 0, visible: 200, content: 120))
    XCTAssertTrue(P.isAtBottom(offset: 800, visible: 200, content: 1000))
    XCTAssertTrue(P.isAtBottom(offset: 799, visible: 200, content: 1000))
    XCTAssertFalse(P.isAtBottom(offset: 700, visible: 200, content: 1000))
    XCTAssertFalse(P.isAtBottom(offset: 0, visible: 200, content: 1000))
  }
}
