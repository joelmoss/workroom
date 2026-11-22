import AppKit
import DaemonConnection
import Synchronization
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// Who is typing into which session, and the 3 s after their last keystroke (#696), on times the
/// test picks: no wall-clock waits.
final class PaneTypingStateTests: XCTestCase {
  private let pane = UUID()
  private let claude = UUID()
  private let codex = UUID()
  private let start = ContinuousClock.now

  private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    start + .milliseconds(milliseconds)
  }

  /// A typist stays 3 s after its last keystroke and not a moment longer; each keystroke restarts
  /// the 3 s.
  func testATypistStaysThreeSecondsAfterItsLastKeystroke() {
    var state = PaneTypingState()
    XCTAssertTrue(state.typed(into: pane, by: claude, at: at(0)))
    XCTAssertEqual(state.nextExpiry, at(3000))
    XCTAssertEqual(state.expire(at: at(2900)), [])
    XCTAssertEqual(state.typists(of: pane).map(\.sender), [claude])

    // Another keystroke at 2.5 s: the 3 s run from there.
    XCTAssertFalse(state.typed(into: pane, by: claude, at: at(2500)), "the same typist")
    XCTAssertEqual(state.nextExpiry, at(5500))
    XCTAssertEqual(state.expire(at: at(5400)), [])
    XCTAssertEqual(state.typists(of: pane).count, 1)

    XCTAssertEqual(state.expire(at: at(5500)), [pane])
    XCTAssertTrue(state.typists(of: pane).isEmpty)
    XCTAssertNil(state.nextExpiry)
    XCTAssertTrue(state.sessions.isEmpty)
  }

  /// Several senders: each has its own 3 s, and they keep the order they started typing in, so a
  /// marker naming the first holds still while the others interleave.
  func testSeveralSendersKeepTheOrderTheyStartedIn() {
    var state = PaneTypingState()
    state.typed(into: pane, by: claude, at: at(0))
    state.typed(into: pane, by: nil, at: at(1000))
    state.typed(into: pane, by: codex, at: at(2000))
    state.typed(into: pane, by: claude, at: at(2500))
    XCTAssertEqual(state.typists(of: pane).map(\.sender), [claude, nil, codex])

    // The one from no pane went quiet first.
    XCTAssertEqual(state.expire(at: at(4000)), [pane])
    XCTAssertEqual(state.typists(of: pane).map(\.sender), [claude, codex])
    XCTAssertEqual(state.nextExpiry, at(5000))
  }

  /// A session typing into itself (`--allow-self`) is nobody else's typing; other panes' typing
  /// is their own.
  func testASessionTypingIntoItselfMarksNothing() {
    var state = PaneTypingState()
    XCTAssertFalse(state.typed(into: pane, by: pane, at: at(0)))
    XCTAssertTrue(state.typists(of: pane).isEmpty)
    let other = UUID()
    state.typed(into: other, by: claude, at: at(0))
    XCTAssertTrue(state.typists(of: pane).isEmpty)
    XCTAssertEqual(state.sessions, [other])
  }

  /// A keystroke that arrives out of order never moves a typist's 3 s back.
  func testALateKeystrokeNeverShortensTheThreeSeconds() {
    var state = PaneTypingState()
    state.typed(into: pane, by: claude, at: at(2000))
    state.typed(into: pane, by: claude, at: at(1000))
    XCTAssertEqual(state.nextExpiry, at(5000))
  }
}

/// A sleep the test ends by hand, recording how long each was asked to be.
private final class ManualSleeper: Sendable {
  private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
  private let asked = Mutex<[Duration]>([])

  var requested: [Duration] { asked.withLock { $0 } }
  var pending: Int { waiting.withLock { $0.count } }

  func sleep(_ duration: Duration) async {
    await withCheckedContinuation { continuation in
      asked.withLock { $0.append(duration) }
      waiting.withLock { $0.append(continuation) }
    }
  }

  func wake() {
    let woken = waiting.withLock { list in
      defer { list.removeAll() }
      return list
    }
    for continuation in woken { continuation.resume() }
  }
}

/// A host connection that speaks only the terminal API's typing events, pushed by the test.
private final class FakeTerminalInputConnection: HostServiceConnection, Sendable {
  let disconnection = AsyncStream<Void> { _ in }
  private let handler = Mutex<(@Sendable (TerminalInputEvent) -> Void)?>(nil)
  private let ends = Mutex(0)
  private let subscribes = Mutex(0)
  let refusal: TerminalInputAvailability?

  /// `refusal` answers every subscribe instead of a live subscription.
  init(refusal: TerminalInputAvailability? = nil) { self.refusal = refusal }

  var subscribed: Bool { handler.withLock { $0 != nil } }
  /// How many subscriptions were ended by their subscriber.
  var ended: Int { ends.withLock { $0 } }
  var subscribeCount: Int { subscribes.withLock { $0 } }
  func push(_ event: TerminalInputEvent) { handler.withLock { $0 }?(event) }

  func reader(context: RepositoryContext) throws -> VCSProviding { throw VCSError.io("unused") }
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting {
    throw VCSError.io("unused")
  }
  func subscribeTerminalInput(
    onEvent: @escaping @Sendable (TerminalInputEvent) -> Void
  ) async throws -> TerminalInputAvailability {
    subscribes.withLock { $0 += 1 }
    if let refusal { return refusal }
    handler.withLock { $0 = onEvent }
    return .available(TerminalInputSubscription(stream: 1) { self.ends.withLock { $0 += 1 } })
  }
  func close() async {}
}

@MainActor
final class PaneTypingMonitorTests: XCTestCase {
  private let pane = UUID()
  private let sender = UUID()

  private func until(
    _ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  /// The marker's whole life on the monitor's clock: told at the first keystroke and at each one
  /// after, kept while the keystrokes come, and dropped 3 s after the last, with one timer set for
  /// the earliest expiry.
  func testATypistIsDroppedThreeSecondsAfterItsLastKeystroke() async {
    let monitor = PaneTypingMonitor()
    let start = ContinuousClock.now
    var now = start
    monitor.now = { now }
    let sleeper = ManualSleeper()
    monitor.sleep = { await sleeper.sleep($0) }
    var heard: [Set<UUID>] = []
    _ = monitor.addListener { heard.append($0) }

    monitor.typed(into: pane, by: sender)
    XCTAssertEqual(monitor.typists(of: pane).map(\.sender), [sender])
    XCTAssertEqual(heard, [[pane]])
    await until(sleeper.pending == 1)
    XCTAssertEqual(sleeper.requested, [.seconds(3)])

    // A keystroke 2 s in: told, and the timer already set is kept.
    now = start + .seconds(2)
    monitor.typed(into: pane, by: sender)
    XCTAssertEqual(heard.count, 2)
    XCTAssertEqual(sleeper.requested, [.seconds(3)], "no second timer")

    // The first timer fires at 3 s: the typist typed 1 s ago, so it stays, until 5 s.
    now = start + .seconds(3)
    sleeper.wake()
    await until(sleeper.requested.count == 2)
    XCTAssertEqual(sleeper.requested.last, .seconds(2))
    XCTAssertEqual(monitor.typists(of: pane).count, 1)
    XCTAssertEqual(heard.count, 2, "nothing changed at 3 s")

    now = start + .seconds(5)
    sleeper.wake()
    await until(monitor.typists(of: pane).isEmpty)
    XCTAssertEqual(heard.last, [pane])
    XCTAssertEqual(sleeper.pending, 0, "no timer with nobody typing")

    // A session typing into itself tells nobody.
    monitor.typed(into: pane, by: pane)
    XCTAssertEqual(heard.count, 3)
  }

  private func monitor(
    _ connections: [FakeTerminalInputConnection], reconnected: @escaping @Sendable () async -> Void
  ) -> PaneTypingMonitor {
    let monitor = PaneTypingMonitor()
    monitor.watchesHosts = true
    monitor.backoff = { _ in }
    monitor.reconnected = { _ in await reconnected() }
    let queue = Mutex(connections)
    monitor.connect = { _ in
      while true {
        if let next = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    return monitor
  }

  private static let never: @Sendable () async -> Void = {
    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
  }

  /// The host's `session.input` events reach the monitor; a dropped subscription is subscribed
  /// again, and forgetting the host ends its subscription on the daemon too.
  func testTheHostsEventsReachTheMonitorAndForgettingTheHostEndsItsSubscription() async {
    let first = FakeTerminalInputConnection()
    let second = FakeTerminalInputConnection()
    let monitor = monitor([first, second], reconnected: Self.never)
    monitor.watch(.local)
    await until(first.subscribed)
    first.push(.input(session: pane, sender: sender))
    await until(monitor.typists(of: pane).map(\.sender) == [sender])

    first.push(.lost)
    await until(second.subscribed)
    XCTAssertEqual(first.ended, 0, "a stream that ended on its own needs no ending")
    second.push(.input(session: pane, sender: nil))
    await until(monitor.typists(of: pane).count == 2)

    monitor.forget(.local)
    await until(second.ended == 1)
  }

  /// A daemon with no typing to tell (before the terminal API, or before `session.input`) is not
  /// asked again on a timer, only on a new connection.
  func testADaemonWithNoTypingIsAskedAgainOnlyOnANewConnection() async {
    let old = FakeTerminalInputConnection(refusal: .unsupported)
    let newer = FakeTerminalInputConnection()
    let link = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let monitor = monitor([old, newer]) {
      await withCheckedContinuation { continuation in link.withLock { $0 = continuation } }
    }
    monitor.watch(.local)
    await until(old.subscribeCount == 1)
    await until(link.withLock { $0 != nil })
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(old.subscribeCount, 1, "asked again with no new connection")
    XCTAssertFalse(newer.subscribed)

    link.withLock { $0 }?.resume()
    await until(newer.subscribed)
    monitor.forget(.local)
  }

  // Value: protects=a subscription this Mac's old daemon refused is asked again of the program a
  // hand-off replaced it with (#694 review); fails_when=`hostReconnected(.local)` never returns,
  // so typing, `new`, `close` and labels stay off until the app restarts; why_new=a new event type
  // made old daemons refuse; seam=LocalDaemonHandOffs
  /// This Mac's daemon "reconnects" when a hand-off completes, and only then: the subscription its
  /// old program refused is asked of the new one.
  func testAfterALocalHandOffTheSubscriptionIsAskedAgain() async {
    XCTAssertTrue(DaemonHandOff.handedOff("exit 0: handed off"))
    XCTAssertFalse(DaemonHandOff.handedOff("exit 0: current"))
    XCTAssertFalse(DaemonHandOff.handedOff("exit 92: the daemon did not greet"))
    let old = FakeTerminalInputConnection(refusal: .unsupported)
    let newer = FakeTerminalInputConnection()
    let before = LocalDaemonHandOffs.shared.waiters
    let monitor = monitor([old, newer]) { await ProgramStatusMonitor.hostReconnected(.local) }
    monitor.watch(.local)
    await until(old.subscribeCount == 1)
    await until(LocalDaemonHandOffs.shared.waiters > before)
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(newer.subscribed, "asked again with no hand-off")
    LocalDaemonHandOffs.shared.completed()
    await until(newer.subscribed)
    monitor.forget(.local)
  }
}

/// What the marker says (#696): the sender as the app names it, its tab as the user sees it, and
/// the tooltip naming every sender.
@MainActor
final class PaneTypingMarkerTests: XCTestCase {
  private let pane = UUID()
  private let here = TerminalTarget.ID.workroom(project: "/p", name: "uitest-room")
  private let elsewhere = TerminalTarget.ID.workroom(project: "/p", name: "fix-auth")
  private let claude = UUID()
  private let shell = UUID()
  private let codex = UUID()
  private let popped = UUID()

  private func typists(_ senders: [UUID?]) -> [PaneTypingState.Typist] {
    let start = ContinuousClock.now
    return senders.enumerated().map { index, sender in
      let at = start + .seconds(index)
      return PaneTypingState.Typist(sender: sender, started: at, lastTyped: at)
    }
  }

  private var places: [UUID: PaneTypingPlace] {
    [
      pane: PaneTypingPlace(target: here, targetName: "uitest-room", tab: 1, agent: nil),
      claude: PaneTypingPlace(target: here, targetName: "uitest-room", tab: 2, agent: .claude),
      shell: PaneTypingPlace(target: here, targetName: "uitest-room", tab: 3, agent: nil),
      codex: PaneTypingPlace(target: elsewhere, targetName: "fix-auth", tab: 2, agent: .codex),
      popped: PaneTypingPlace(target: elsewhere, targetName: "fix-auth", tab: nil, agent: .claude),
    ]
  }

  private func marker(_ senders: [UUID?]) -> PaneTypingMarker? {
    let places = places
    return PaneTypingMarker.make(
      typists: typists(senders), receiver: places[pane], locate: { places[$0] })
  }

  func testNobodyTypingIsNoMarker() {
    XCTAssertNil(marker([]))
  }

  /// "Claude · tab 2", with Claude's logo: the ticket's own example.
  func testACodingAgentInAnotherTabIsNamedWithItsTab() throws {
    let marker = try XCTUnwrap(marker([claude]))
    XCTAssertEqual(marker.icon, .agent(.claude))
    XCTAssertEqual(marker.text, "Claude · tab 2")
    XCTAssertEqual(marker.tab, "tab 2")
    XCTAssertNil(marker.workroom, "this pane's own workroom goes unsaid")
    XCTAssertEqual(marker.help, "Claude in tab 2 is typing into this pane.")
  }

  /// A program that is no coding agent is "Terminal", never its title (the send command itself).
  func testAnyOtherProgramIsTheTerminalInItsTab() throws {
    let marker = try XCTUnwrap(marker([shell]))
    XCTAssertEqual(marker.icon, .terminal)
    XCTAssertEqual(marker.text, "Terminal · tab 3")
    XCTAssertEqual(marker.help, "The terminal in tab 3 is typing into this pane.")
  }

  /// A tab in another workroom says which, in a part of its own the pill can truncate apart from
  /// the tab; a pane popped out of its strip is in its own window, whatever its workroom.
  func testATabElsewhereSaysWhereAndAPoppedOutPaneIsInItsOwnWindow() throws {
    let codex = try XCTUnwrap(marker([self.codex]))
    XCTAssertEqual(codex.text, "Codex · tab 2 in fix-auth")
    XCTAssertEqual(codex.tab, "tab 2")
    XCTAssertEqual(codex.workroom, "fix-auth")
    XCTAssertEqual(codex.help, "Codex in tab 2 in fix-auth is typing into this pane.")
    let popped = try XCTUnwrap(marker([self.popped]))
    XCTAssertEqual(popped.text, "Claude · own window")
    XCTAssertNil(popped.workroom)
    XCTAssertEqual(popped.help, "Claude in its own window is typing into this pane.")
  }

  /// A send from no pane, and one from a terminal no window here has open.
  func testASenderInNoTabSaysSo() throws {
    let outside = try XCTUnwrap(marker([nil]))
    XCTAssertEqual(outside.icon, .terminal)
    XCTAssertEqual(outside.text, "Outside Workroom")
    XCTAssertNil(outside.tab)
    XCTAssertEqual(outside.help, "A program outside Workroom is typing into this pane.")
    let unknown = try XCTUnwrap(marker([UUID()]))
    XCTAssertEqual(unknown.text, "Another terminal")
    XCTAssertEqual(unknown.help, "A terminal that isn't open in Workroom is typing into this pane.")
  }

  /// Several at once: one marker naming the first to start, "+N" for the rest, every one in the
  /// tooltip.
  func testSeveralSendersNameTheFirstAndCountTheRest() throws {
    let two = try XCTUnwrap(marker([claude, shell]))
    XCTAssertEqual(two.text, "Claude · tab 2 +1")
    XCTAssertEqual(
      two.help, "Claude in tab 2 and the terminal in tab 3 are typing into this pane.")
    let three = try XCTUnwrap(marker([claude, shell, nil]))
    XCTAssertEqual(three.others, 2)
    XCTAssertEqual(
      three.help,
      "Claude in tab 2, the terminal in tab 3 and a program outside Workroom are typing into "
        + "this pane.")
  }
}

/// The marker over a terminal (#696): it appears with its tooltip when someone types, takes no
/// mouse input and changes no cursor, is announced once per run while it can be seen, comes back
/// whole from a keystroke during its fade, and keeps clear of a pane notice.
@MainActor
final class PaneTypingMarkerOverlayTests: XCTestCase {
  private let pane = UUID()
  private let claude = UUID()
  private var monitor: PaneTypingMonitor!
  private var now = ContinuousClock.now
  private var sleeper: ManualSleeper!
  private var announced: [String] = []
  private var onScreen = true
  private var noticeBottom: CGFloat = 0
  /// The terminal the overlay floats over, held for the test: the overlay holds it weakly.
  private var surface: NSView?
  /// The overlay's wait for its fade-out to end, which the test ends by hand.
  private var fadeSleeper: ManualSleeper!

  private func overlay() -> (PaneTypingMarkerOverlay, NSView) {
    monitor = PaneTypingMonitor()
    monitor.now = { [unowned self] in self.now }
    let sleeper = ManualSleeper()
    self.sleeper = sleeper
    monitor.sleep = { await sleeper.sleep($0) }
    let surface = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    self.surface = surface
    let pane = pane
    let overlay = PaneTypingMarkerOverlay(
      surface: surface, session: { pane }, isOnScreen: { [unowned self] in self.onScreen },
      noticeBottom: { [unowned self] in self.noticeBottom })
    overlay.monitor = monitor
    let fadeSleeper = ManualSleeper()
    self.fadeSleeper = fadeSleeper
    overlay.sleep = { await fadeSleeper.sleep($0) }
    let target = TerminalTarget.ID.workroom(project: "/p", name: "room")
    let claude = claude
    overlay.locate = { session in
      session == claude
        ? PaneTypingPlace(target: target, targetName: "room", tab: 2, agent: .claude)
        : PaneTypingPlace(target: target, targetName: "room", tab: 1, agent: nil)
    }
    overlay.announce = { [unowned self] _, text in self.announced.append(text) }
    overlay.start()
    return (overlay, surface)
  }

  private func expire(after seconds: Int) async {
    now += .seconds(seconds)
    await until(sleeper.pending == 1)
    sleeper.wake()
  }

  func testTheMarkerShowsWithItsTooltipAndGoesWithTheTypist() async throws {
    let (overlay, surface) = overlay()
    XCTAssertNil(overlay.host, "nothing is added to a terminal nobody types into")

    // Typing into another pane is not this one's.
    monitor.typed(into: UUID(), by: claude)
    XCTAssertNil(overlay.model.marker)

    monitor.typed(into: pane, by: claude)
    XCTAssertEqual(overlay.model.marker?.text, "Claude · tab 2")
    XCTAssertTrue(overlay.model.visible)
    let host = try XCTUnwrap(overlay.host)
    XCTAssertTrue(host.superview === surface)
    XCTAssertEqual(host.frame.maxY, surface.bounds.maxY, "across the top of the terminal")
    XCTAssertEqual(host.frame.width, surface.bounds.width)
    XCTAssertNil(host.hitTest(CGPoint(x: 300, y: 390)), "clicks reach the terminal")
    let tooltip = overlay.view(
      surface, stringForToolTip: 0, point: CGPoint(x: 300, y: 380), userData: nil)
    XCTAssertEqual(tooltip, "Claude in tab 2 is typing into this pane.")

    await expire(after: 3)
    await until(!overlay.model.visible)
    XCTAssertNil(overlay.help, "no tooltip once nobody types")
    XCTAssertFalse(overlay.hasToolTip)
    overlay.stop()
    XCTAssertNil(overlay.host)
  }

  /// No tracking area and no cursor rect, whatever SwiftUI asks for: the terminal's cursor is the
  /// only one over the band.
  func testTheHostChangesNoCursorAndTakesNoMouse() throws {
    let (overlay, _) = overlay()
    monitor.typed(into: pane, by: claude)
    let host = try XCTUnwrap(overlay.host)
    host.addTrackingArea(
      NSTrackingArea(
        rect: host.bounds, options: [.cursorUpdate, .activeAlways, .mouseMoved], owner: host))
    host.updateTrackingAreas()
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(host.trackingAreas.isEmpty, "\(host.trackingAreas)")
    XCTAssertFalse(host.acceptsFirstResponder)
  }

  /// A keystroke during the fade-out brings the one marker back, without a second announcement.
  func testAKeystrokeDuringTheFadeBringsItBackAnnouncedOnce() async {
    let (overlay, _) = overlay()
    monitor.typed(into: pane, by: claude)
    XCTAssertEqual(announced, ["Claude in tab 2 is typing into this pane."])
    await expire(after: 3)
    await until(!overlay.model.visible)
    XCTAssertNotNil(overlay.model.marker, "still there while it fades")

    monitor.typed(into: pane, by: claude)
    XCTAssertTrue(overlay.model.visible)
    XCTAssertEqual(overlay.model.marker?.text, "Claude · tab 2")
    XCTAssertNotNil(overlay.help)
    XCTAssertEqual(announced.count, 1, "announced again for the same run")

    // The interrupted fade's end leaves it be.
    await until(fadeSleeper.pending == 1)
    fadeSleeper.wake()
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertNotNil(overlay.model.marker, "a fade a keystroke interrupted removed the marker")

    // A fade that runs its course removes it, and the next run is announced afresh.
    await expire(after: 3)
    await until(fadeSleeper.pending == 1)
    fadeSleeper.wake()
    await until(overlay.model.marker == nil)
    monitor.typed(into: pane, by: claude)
    XCTAssertEqual(announced.count, 2)
  }

  /// A pane nobody can see (its tab not selected, its window hidden) is not announced; once it
  /// can be seen, the next keystroke of the run is.
  func testOnlyAPaneThatCanBeSeenIsAnnounced() {
    onScreen = false
    let (overlay, _) = overlay()
    monitor.typed(into: pane, by: claude)
    XCTAssertTrue(announced.isEmpty)
    onScreen = true
    monitor.typed(into: pane, by: claude)
    monitor.typed(into: pane, by: claude)
    XCTAssertEqual(announced.count, 1)
    withExtendedLifetime(overlay) {}
  }

  /// With a pane notice showing, the pill sits below its card; without, at the top.
  func testThePillKeepsClearOfAPaneNotice() throws {
    let (overlay, surface) = overlay()
    monitor.typed(into: pane, by: claude)
    XCTAssertEqual(overlay.model.topInset, PaneTypingMarkerMetrics.topInset)
    noticeBottom = 70
    overlay.layout()
    XCTAssertEqual(overlay.model.topInset, 70 + PaneTypingMarkerMetrics.noticeGap)
    let host = try XCTUnwrap(overlay.host)
    XCTAssertEqual(host.frame.height, PaneTypingMarkerMetrics.band(topInset: 78))
    XCTAssertEqual(host.frame.maxY, surface.bounds.maxY)
    noticeBottom = 0
    overlay.layout()
    XCTAssertEqual(overlay.model.topInset, PaneTypingMarkerMetrics.topInset)
  }

  private func until(
    _ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}
