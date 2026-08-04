import AppKit
import Defaults
import XCTest

@testable import Workroom

/// `QuickSwitcherController` (issue #132, T10): the reducer wired to the world — the modifier poll, the
/// VoiceOver bypass (D16), the D17 hover threshold, item reconciliation and the commit.
///
/// Every seam is injected, so none of this waits on a real 30 ms timer or needs a window on screen:
/// `flagsProvider` fakes the hardware modifier snapshot, `startTimers` is neutered and `poll()` /
/// `revealTimerFired()` are called directly, and the rail seam is captured as recorded calls.
@MainActor
final class QuickSwitcherControllerTests: XCTestCase {

  private var recency = SwitcherRecency()
  private var registry = WindowRegistry()
  /// `WindowRegistry` holds windows weakly and prunes dead entries, so the test must keep them alive.
  private var windows: [NSWindow] = []

  override func setUp() {
    super.setUp()
    Defaults[.switcherWorkroomModifier] = .option
    Defaults[.switcherPaneModifier] = .control
    recency = SwitcherRecency()
    registry = WindowRegistry()
    windows = []
  }

  override func tearDown() {
    Defaults.reset(.switcherWorkroomModifier, .switcherPaneModifier)
    super.tearDown()
  }

  /// A controller with every real-world seam replaced. `held` is the fake hardware modifier state.
  private func makeController(
    held: NSEvent.ModifierFlags = [.option], voiceOver: Bool = false
  ) -> (QuickSwitcherController, Recorder) {
    let recorder = Recorder()
    let controller = QuickSwitcherController()
    controller.flagsProvider = { recorder.held }
    controller.voiceOverEnabled = { voiceOver }
    controller.startTimers = { _ in }  // no real timers: the tests drive poll()/revealTimerFired()
    // Pinned, so D17's threshold is never measured against wherever the real mouse happens to sit.
    controller.pointerProvider = { .zero }
    controller.announce = { recorder.announcements.append($0) }
    controller.onReveal = { items, cursor in recorder.reveals.append((items.count, cursor)) }
    // Both land on `show(items:cursor:)` in production, so they land in one list here too.
    controller.onItemsChanged = { items, cursor in recorder.reveals.append((items.count, cursor)) }
    controller.onCursorMoved = { recorder.cursorMoves.append($0) }
    controller.onEnd = { recorder.ends += 1 }
    recorder.held = held
    return (controller, recorder)
  }

  private final class Recorder {
    var held: NSEvent.ModifierFlags = []
    var reveals: [(count: Int, cursor: Int)] = []
    var cursorMoves: [Int] = []
    var ends = 0
    var announcements: [String] = []
  }

  /// Register a store against its own retained window, the way a real app window would be.
  private func attach(_ store: AppStore) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: true)
    windows.append(window)
    registry.register(window: window, store: store)
  }

  /// A store with a live terminal in each of `workrooms`. The tab is what makes it *displayed* —
  /// `displayedWorkroomTargets` only lists targets that actually have tabs, so without one there is
  /// nothing for the switcher to collect (same fixture shape as `QuickSwitcherTests`).
  private func makeStore(workrooms: [String], panes: Int = 1) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: workrooms.map {
          Workroom(name: $0, path: "/p/\($0)", vcsName: "workroom/\($0)", warnings: [])
        })
    ]
    for name in workrooms {
      guard let target = store.target(for: .workroom(project: "/p", name: name)) else { continue }
      for _ in 0..<panes { store.terminals.addTab(for: target) }
    }
    return store
  }

  // MARK: VoiceOver bypass (D16)

  func testVoiceOverNeverOpensASession() {
    let store = makeStore(workrooms: ["fox", "owl"])
    let (controller, recorder) = makeController(voiceOver: true)
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    // The whole point of D16: ⌃⌥ is VoiceOver's own modifier pair and a non-key panel can never hold
    // VoiceOver focus, so there must be no session and no rail at all — just the stage-1 flip.
    XCTAssertFalse(controller.isLive, "no session under VoiceOver")
    XCTAssertTrue(recorder.reveals.isEmpty, "and no rail")
  }

  /// VoiceOver switched on **mid-gesture** (⌘F5 is one keystroke). AppKit ships no VoiceOver-status
  /// notification — `isVoiceOverEnabled` is KVO-only — so the controller watches it that way and ends the
  /// session, because D16's answer to "a panel that can't take VoiceOver focus" is to have no panel. It
  /// must end WITHOUT committing: the user is mid-hold on a rail that just became invisible to them.
  func testVoiceOverComingOnMidSessionEndsTheRailWithoutCommitting() {
    let store = makeStore(workrooms: ["fox", "owl"])
    store.selectedTargetID = .workroom(project: "/p", name: "fox")
    attach(store)
    let (controller, recorder) = makeController()
    var voiceOverRunning = false
    controller.voiceOverEnabled = { voiceOverRunning }
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    XCTAssertTrue(controller.isRevealed)

    controller.voiceOverStatusChanged()
    XCTAssertTrue(controller.isLive, "the status changed to still-off — nothing to do")

    voiceOverRunning = true
    controller.voiceOverStatusChanged()
    XCTAssertFalse(controller.isLive, "VoiceOver on ⇒ the session ends")
    XCTAssertEqual(recorder.ends, 1)
    XCTAssertEqual(
      store.selectedTargetID, .workroom(project: "/p", name: "fox"),
      "cancelled, not committed — the rail was steering a choice the user can no longer see")
  }

  func testNonVoiceOverDoesOpenASession() {
    let store = makeStore(workrooms: ["fox", "owl"])
    store.selectedTargetID = .workroom(project: "/p", name: "fox")
    attach(store)
    let (controller, _) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    XCTAssertTrue(controller.isLive)
    XCTAssertFalse(controller.isRevealed, "pending — the rail waits out the reveal delay")
  }

  // MARK: Modifier poll

  func testPollEndsTheSessionOnceTheModifierIsReleased() {
    let store = seededStore()
    let (controller, recorder) = makeController(held: [.option])
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    XCTAssertTrue(controller.isLive)
    controller.poll()
    XCTAssertTrue(controller.isLive, "still held — the poll must not end it")
    recorder.held = []
    controller.poll()
    XCTAssertFalse(controller.isLive, "released ⇒ committed and ended")
    XCTAssertEqual(recorder.ends, 1)
  }

  func testPollWatchesTheConfiguredModifierNotAHardcodedOne() throws {
    Defaults[.switcherPaneModifier] = .commandControl
    let store = seededStore()
    let (controller, recorder) = makeController(held: [.command, .control])
    _ = controller.handleTrigger(
      .panes, reverse: false, in: store, registry: registry, recency: recency)
    try XCTSkipUnless(controller.isLive, "no second pane to switch to in this fixture")
    recorder.held = [.control]  // ⌘ let go — the chord is broken
    controller.poll()
    XCTAssertFalse(controller.isLive, "a partial chord counts as released")
  }

  func testPollIgnoresExtraModifiersHeldAlongside() {
    let store = seededStore()
    let (controller, recorder) = makeController(held: [.option])
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    recorder.held = [.option, .shift]  // ⇧ for a reverse step — ⌥ is still down
    controller.poll()
    XCTAssertTrue(controller.isLive, "the trigger is still held; extra modifiers are not a release")
  }

  func testPollWhileIdleIsHarmless() {
    let (controller, recorder) = makeController(held: [])
    controller.poll()
    XCTAssertEqual(recorder.ends, 0)
  }

  // MARK: Reveal

  func testRevealTimerRevealsAndReportsTheCursor() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    XCTAssertTrue(controller.isRevealed)
    XCTAssertEqual(recorder.reveals.count, 1)
    XCTAssertEqual(
      recorder.reveals.first?.cursor, 1, "the rail opens with the previous item selected")
  }

  func testASecondTriggerRevealsWithoutWaiting() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    XCTAssertTrue(controller.isRevealed, "⌥Tab⌥Tab shows the rail immediately")
    XCTAssertEqual(recorder.reveals.count, 1)
  }

  // MARK: Hover threshold (D17)

  func testHoverIsIgnoredUntilThePointerActuallyMoves() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    // The pointer hasn't moved since the reveal: the panel appeared *under* it, so this hover is an
    // artefact of where the cursor already was, not a choice (D17).
    controller.point(index: 0, pointer: .zero)
    XCTAssertTrue(recorder.cursorMoves.isEmpty, "a stationary pointer must not steer the selection")
    // Past the 4pt threshold ⇒ real movement, hover now steers.
    controller.point(index: 0, pointer: NSPoint(x: 40, y: 40))
    XCTAssertEqual(recorder.cursorMoves, [0])
  }

  func testAMinusculePointerJitterDoesNotArmHover() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    controller.point(index: 0, pointer: NSPoint(x: 2, y: 2))  // ~2.8pt — inside the threshold
    XCTAssertTrue(recorder.cursorMoves.isEmpty, "hand tremor is not intent")
  }

  // MARK: Escape / cancel

  func testEscapeEndsWithoutCommitting() {
    let store = seededStore()
    let selected = store.selectedTargetID
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    XCTAssertTrue(controller.handleEscape())
    XCTAssertFalse(controller.isLive)
    XCTAssertEqual(recorder.ends, 1)
    XCTAssertEqual(store.selectedTargetID, selected, "cancel must leave the selection alone")
  }

  func testEscapeWhileIdleIsNotConsumed() {
    let (controller, _) = makeController()
    XCTAssertFalse(
      controller.handleEscape(), "the monitor must pass Escape on when nothing is live")
  }

  func testArrowsAreOnlyConsumedWhileLive() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    XCTAssertFalse(controller.handleArrow(reverse: false), "not live — Escape/arrows pass through")
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    XCTAssertTrue(controller.handleArrow(reverse: false))
    // Two candidates: the rail opens on index 1, so one step forward wraps back to 0.
    XCTAssertEqual(recorder.cursorMoves.last, 0)
    XCTAssertTrue(controller.handleArrow(reverse: true))
    XCTAssertEqual(recorder.cursorMoves.last, 1, "and ← walks the other way")
  }

  func testArrowsArePassedOnBeforeTheRailIsRevealed() {
    // The 250 ms pending phase has nothing on screen to steer, so eating an arrow there both swallowed
    // the keystroke and popped the rail — ⌥Tab followed by ⌥← (word-back in a shell) did exactly that.
    let store = seededStore()
    let (controller, _) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    XCTAssertTrue(controller.isLive)
    XCTAssertFalse(controller.isRevealed)
    XCTAssertFalse(
      controller.handleArrow(reverse: false, flags: [.option]),
      "live but not revealed — the arrow belongs to whatever is focused")
  }

  func testArrowsCarryingExtraModifiersAreNotStolen() {
    // ⌥⌘←/→ cycles terminal tabs and ⇧⌥⌘←/→ cycles workroom tabs; ⌃⌘arrows moves pane focus. All three
    // need a modifier the user is *already* holding for the rail, so the branch has to check flags —
    // its comment claimed it did while the code matched on keyCode alone.
    let store = seededStore()
    let (controller, _) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    XCTAssertFalse(
      controller.handleArrow(reverse: false, flags: [.option, .command]),
      "⌥⌘→ belongs to the terminal-tab cycler, not the rail")
    XCTAssertFalse(controller.handleArrow(reverse: true, flags: [.option, .command, .shift]))
    XCTAssertTrue(
      controller.handleArrow(reverse: false, flags: [.option]), "the bare trigger still steers")
  }

  // MARK: Live-session ownership

  func testAPaneTriggerDoesNotStealAWorkroomSession() {
    // Release is a 30 ms poll, so a ⌃Tab landing just after ⌥ came up used to step the WORKROOM rail,
    // consume the key, and then commit a workroom nobody asked for.
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    XCTAssertEqual(recorder.reveals.count, 1)
    _ = controller.handleTrigger(
      .panes, reverse: false, in: store, registry: registry, recency: recency)
    XCTAssertEqual(
      recorder.ends, 1, "the workroom session was cancelled rather than steered by ⌃Tab")
    XCTAssertEqual(
      controller.reducer.kind, .panes, "and the new session is the one that was pressed")
  }

  // MARK: Click commit

  func testClickCommitsAndTheFollowingReleaseIsSwallowed() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    controller.clickCommit(index: 1)
    XCTAssertFalse(controller.isLive)
    XCTAssertEqual(recorder.ends, 1)
    recorder.held = []
    controller.poll()
    XCTAssertEqual(recorder.ends, 1, "the release after a click must not end a second time")
  }

  // MARK: Item reconciliation

  func testReconcileDropsDeadItemsAndClampsOrEnds() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    let before = controller.items.count
    XCTAssertGreaterThan(before, 1)
    // The whole window goes away (a sheet counts as dead too — you can't switch into a busy window).
    store.errorMessage = "a dialog went up"  // any `hasModalPresentation` source
    controller.reconcileItems()
    XCTAssertFalse(controller.isLive, "no live candidates left ⇒ end without committing")
    XCTAssertEqual(recorder.ends, 1)
  }

  func testReconcileKeepsTheCursorOnTheItemItWasTrackingAndRerendersTheRail() {
    // The bug this pins: `filter` compacts the array, so losing an item BEFORE the cursor shifts every
    // later item down one. The reducer used to only clamp, so the release committed the highlighted
    // card's neighbour — and the rail was never re-rendered, so a click indexed a stale card list.
    let a = makeStore(workrooms: ["fox"])
    let b = makeStore(workrooms: ["owl", "elk"])
    attach(a)
    attach(b)
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: b, registry: registry, recency: recency)
    controller.revealTimerFired()
    XCTAssertEqual(controller.items.count, 3, "fox + owl + elk")
    // The rail opens on index 1, and index 0 belongs to the OTHER window — so killing that window is
    // exactly the case where every later index shifts down one under the cursor.
    XCTAssertEqual(controller.reducer.cursor, 1)
    let tracked = controller.items[controller.reducer.cursor]
    let trackedID: WorkroomSlotID? = {
      guard case .workroom(let slot) = tracked else { return nil }
      return slot.id
    }()
    a.errorMessage = "a sheet went up in the other window"  // `hasModalPresentation` ⇒ fox is dead
    let revealsBefore = recorder.reveals.count
    controller.reconcileItems()

    XCTAssertTrue(controller.isLive, "two candidates remain — the session survives")
    XCTAssertEqual(controller.items.count, 2)
    guard case .workroom(let stillAt) = controller.items[controller.reducer.cursor] else {
      return XCTFail("cursor no longer on a workroom")
    }
    XCTAssertEqual(stillAt.id, trackedID, "the cursor followed the ITEM, not its old index")
    XCTAssertEqual(controller.reducer.cursor, 0, "which is now index 0, one lower than before")
    XCTAssertGreaterThan(
      recorder.reveals.count, revealsBefore, "and the rail was re-rendered from the survivors")
    XCTAssertEqual(recorder.reveals.last?.count, 2)
  }

  func testReconcileWithNothingDeadLeavesTheRailAlone() {
    let store = seededStore()
    let (controller, recorder) = makeController()
    _ = controller.handleTrigger(
      .workrooms, reverse: false, in: store, registry: registry, recency: recency)
    controller.revealTimerFired()
    let reveals = recorder.reveals.count
    controller.reconcileItems()
    XCTAssertEqual(recorder.reveals.count, reveals, "no churn when nothing changed")
    XCTAssertTrue(controller.isLive)
  }

  func testReconcileWhileIdleIsHarmless() {
    let (controller, recorder) = makeController()
    controller.reconcileItems()
    XCTAssertEqual(recorder.ends, 0)
  }

  // MARK: Passthrough

  func testTriggerWithNothingToSwitchToIsNotConsumed() {
    let store = makeStore(workrooms: ["fox"])
    store.selectedTargetID = .workroom(project: "/p", name: "fox")
    attach(store)
    let (controller, _) = makeController(held: [.control])
    XCTAssertFalse(
      controller.handleTrigger(
        .panes, reverse: false, in: store, registry: registry, recency: recency),
      "one pane ⇒ nothing to switch to, so ⌃Tab must reach the TUI")
    XCTAssertFalse(controller.isLive)
  }

  // MARK: Fixture

  /// Two open workrooms in this test's own registry, MRU-seeded — the minimum for a session to open.
  private func seededStore() -> AppStore {
    let store = makeStore(workrooms: ["fox", "owl"], panes: 2)
    attach(store)
    store.selectedTargetID = .workroom(project: "/p", name: "fox")
    recency.recordWorkroom(store: store, sid: .workroom(project: "/p", name: "owl"))
    recency.recordWorkroom(store: store, sid: .workroom(project: "/p", name: "fox"))
    return store
  }
}
