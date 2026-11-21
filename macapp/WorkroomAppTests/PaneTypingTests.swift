import AppKit
import DaemonConnection
import Synchronization
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// Who is typing into which session, and the 3 s after their last keystroke (#696), on a clock the
/// test sets: no wall-clock waits.
final class PaneTypingStateTests: XCTestCase {
  private let pane = UUID()
  private let claude = UUID()
  private let codex = UUID()
  private let start = Date(timeIntervalSince1970: 1_000)

  private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  /// A typist stays 3 s after its last keystroke and not a moment longer; each keystroke restarts
  /// the 3 s.
  func testATypistStaysThreeSecondsAfterItsLastKeystroke() {
    var state = PaneTypingState()
    XCTAssertTrue(state.typed(into: pane, by: claude, at: at(0)))
    XCTAssertEqual(state.nextExpiry, at(3))
    XCTAssertEqual(state.expire(at: at(2.9)), [])
    XCTAssertEqual(state.typists(of: pane).map(\.sender), [claude])

    // Another keystroke at 2.5 s: the 3 s run from there.
    XCTAssertFalse(state.typed(into: pane, by: claude, at: at(2.5)), "the same typist")
    XCTAssertEqual(state.nextExpiry, at(5.5))
    XCTAssertEqual(state.expire(at: at(5.4)), [])
    XCTAssertEqual(state.typists(of: pane).count, 1)

    XCTAssertEqual(state.expire(at: at(5.5)), [pane])
    XCTAssertTrue(state.typists(of: pane).isEmpty)
    XCTAssertNil(state.nextExpiry)
    XCTAssertTrue(state.sessions.isEmpty)
  }

  /// Several senders: each has its own 3 s, and they keep the order they started typing in, so a
  /// marker naming the first holds still while the others interleave.
  func testSeveralSendersKeepTheOrderTheyStartedIn() {
    var state = PaneTypingState()
    state.typed(into: pane, by: claude, at: at(0))
    state.typed(into: pane, by: nil, at: at(1))
    state.typed(into: pane, by: codex, at: at(2))
    state.typed(into: pane, by: claude, at: at(2.5))
    XCTAssertEqual(state.typists(of: pane).map(\.sender), [claude, nil, codex])

    // The one from no pane went quiet first.
    XCTAssertEqual(state.expire(at: at(4)), [pane])
    XCTAssertEqual(state.typists(of: pane).map(\.sender), [claude, codex])
    XCTAssertEqual(state.nextExpiry, at(5))
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
    state.typed(into: pane, by: claude, at: at(2))
    state.typed(into: pane, by: claude, at: at(1))
    XCTAssertEqual(state.nextExpiry, at(5))
  }
}

/// A sleep the test ends by hand, recording how long each was asked to be.
private final class ManualSleeper: Sendable {
  private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
  private let asked = Mutex<[TimeInterval]>([])

  var requested: [TimeInterval] { asked.withLock { $0 } }
  var pending: Int { waiting.withLock { $0.count } }

  func sleep(_ seconds: TimeInterval) async {
    await withCheckedContinuation { continuation in
      asked.withLock { $0.append(seconds) }
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
  let availability: TerminalInputAvailability

  init(availability: TerminalInputAvailability = .available) { self.availability = availability }

  var subscribed: Bool { handler.withLock { $0 != nil } }
  func push(_ event: TerminalInputEvent) { handler.withLock { $0 }?(event) }

  func reader(context: RepositoryContext) throws -> VCSProviding { throw VCSError.io("unused") }
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting {
    throw VCSError.io("unused")
  }
  func subscribeTerminalInput(
    onEvent: @escaping @Sendable (TerminalInputEvent) -> Void
  ) async throws -> TerminalInputAvailability {
    handler.withLock { $0 = onEvent }
    return availability
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
    var now = Date(timeIntervalSince1970: 0)
    monitor.now = { now }
    let sleeper = ManualSleeper()
    monitor.sleep = { await sleeper.sleep($0) }
    var heard: [Set<UUID>] = []
    _ = monitor.addListener { heard.append($0) }

    monitor.typed(into: pane, by: sender)
    XCTAssertEqual(monitor.typists(of: pane).map(\.sender), [sender])
    XCTAssertEqual(heard, [[pane]])
    await until(sleeper.pending == 1)
    XCTAssertEqual(sleeper.requested, [3])

    // A keystroke 2 s in: told, and the timer already set is kept.
    now = Date(timeIntervalSince1970: 2)
    monitor.typed(into: pane, by: sender)
    XCTAssertEqual(heard.count, 2)
    XCTAssertEqual(sleeper.requested, [3], "no second timer")

    // The first timer fires at 3 s: the typist typed 1 s ago, so it stays, until 5 s.
    now = Date(timeIntervalSince1970: 3)
    sleeper.wake()
    await until(sleeper.requested.count == 2)
    XCTAssertEqual(sleeper.requested.last, 2)
    XCTAssertEqual(monitor.typists(of: pane).count, 1)
    XCTAssertEqual(heard.count, 2, "nothing changed at 3 s")

    now = Date(timeIntervalSince1970: 5)
    sleeper.wake()
    await until(monitor.typists(of: pane).isEmpty)
    XCTAssertEqual(heard.last, [pane])
    XCTAssertEqual(sleeper.pending, 0, "no timer with nobody typing")

    // A session typing into itself tells nobody.
    monitor.typed(into: pane, by: pane)
    XCTAssertEqual(heard.count, 3)
  }

  /// The host's `session.input` events reach the monitor; a dropped subscription is subscribed
  /// again, and a daemon that predates the terminal API is simply not followed.
  func testTheHostsEventsReachTheMonitorAndALostLinkSubscribesAgain() async {
    let monitor = PaneTypingMonitor()
    monitor.watchesHosts = true
    monitor.backoff = { _ in }
    monitor.reconnected = { _ in
      while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }
    let first = FakeTerminalInputConnection()
    let second = FakeTerminalInputConnection()
    let queue = Mutex<[FakeTerminalInputConnection]>([first, second])
    monitor.connect = { _ in
      while true {
        if let next = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    monitor.watch(.local)
    await until(first.subscribed)
    first.push(.input(session: pane, sender: sender))
    await until(monitor.typists(of: pane).map(\.sender) == [sender])

    first.push(.lost)
    await until(second.subscribed)
    second.push(.input(session: pane, sender: nil))
    await until(monitor.typists(of: pane).count == 2)
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
    senders.enumerated().map { index, sender in
      let at = Date(timeIntervalSince1970: TimeInterval(index))
      return PaneTypingState.Typist(sender: sender, started: at, lastTyped: at)
    }
  }

  private var places: [UUID: PaneTypingPlace] {
    [
      pane: PaneTypingPlace(target: here, targetName: "uitest-room", tab: 1, agent: nil),
      claude: PaneTypingPlace(target: here, targetName: "uitest-room", tab: 2, agent: .claude),
      shell: PaneTypingPlace(target: here, targetName: "uitest-room", tab: 3, agent: nil),
      codex: PaneTypingPlace(target: elsewhere, targetName: "fix-auth", tab: 2, agent: .codex),
      popped: PaneTypingPlace(target: here, targetName: "uitest-room", tab: nil, agent: .claude),
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
    XCTAssertEqual(marker.help, "Claude in tab 2 is typing into this pane.")
  }

  /// A program that is no coding agent is "Terminal", never its title (the send command itself).
  func testAnyOtherProgramIsTheTerminalInItsTab() throws {
    let marker = try XCTUnwrap(marker([shell]))
    XCTAssertEqual(marker.icon, .terminal)
    XCTAssertEqual(marker.text, "Terminal · tab 3")
    XCTAssertEqual(marker.help, "The terminal in tab 3 is typing into this pane.")
  }

  /// A tab in another workroom says which; a pane popped out of its strip is in its own window.
  func testATabElsewhereSaysWhereAndAPoppedOutPaneIsInItsOwnWindow() throws {
    let codex = try XCTUnwrap(marker([self.codex]))
    XCTAssertEqual(codex.text, "Codex · tab 2 in fix-auth")
    XCTAssertEqual(codex.help, "Codex in tab 2 in fix-auth is typing into this pane.")
    let popped = try XCTUnwrap(marker([self.popped]))
    XCTAssertEqual(popped.text, "Claude · own window")
    XCTAssertEqual(popped.help, "Claude in its own window is typing into this pane.")
  }

  /// A send from no pane, and one from a terminal no window here has open.
  func testASenderInNoTabSaysSo() throws {
    let outside = try XCTUnwrap(marker([nil]))
    XCTAssertEqual(outside.icon, .terminal)
    XCTAssertEqual(outside.text, "Outside Workroom")
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
/// mouse input, and goes once the monitor drops the typist.
@MainActor
final class PaneTypingMarkerOverlayTests: XCTestCase {
  func testTheMarkerShowsWithItsTooltipAndGoesWithTheTypist() async throws {
    let pane = UUID()
    let claude = UUID()
    let monitor = PaneTypingMonitor()
    var now = Date(timeIntervalSince1970: 0)
    monitor.now = { now }
    let sleeper = ManualSleeper()
    monitor.sleep = { await sleeper.sleep($0) }
    let surface = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    let overlay = PaneTypingMarkerOverlay(surface: surface) { pane }
    overlay.monitor = monitor
    let target = TerminalTarget.ID.workroom(project: "/p", name: "room")
    overlay.locate = { session in
      session == claude
        ? PaneTypingPlace(target: target, targetName: "room", tab: 2, agent: .claude)
        : PaneTypingPlace(target: target, targetName: "room", tab: 1, agent: nil)
    }
    overlay.start()
    XCTAssertNil(overlay.host, "nothing is added to a terminal nobody types into")

    // Typing into another pane is not this one's.
    monitor.typed(into: UUID(), by: claude)
    XCTAssertNil(overlay.model.marker)

    monitor.typed(into: pane, by: claude)
    XCTAssertEqual(overlay.model.marker?.text, "Claude · tab 2")
    let host = try XCTUnwrap(overlay.host)
    XCTAssertTrue(host.superview === surface)
    XCTAssertEqual(host.frame.maxY, surface.bounds.maxY, "across the top of the terminal")
    XCTAssertEqual(host.frame.width, surface.bounds.width)
    XCTAssertNil(host.hitTest(CGPoint(x: 300, y: 390)), "clicks reach the terminal")
    let tooltip = overlay.view(
      surface, stringForToolTip: 0, point: CGPoint(x: 300, y: 380), userData: nil)
    XCTAssertEqual(tooltip, "Claude in tab 2 is typing into this pane.")

    now = Date(timeIntervalSince1970: 3)
    await until(sleeper.pending == 1)
    sleeper.wake()
    await until(overlay.model.marker == nil)
    XCTAssertNil(overlay.help, "no tooltip once nobody types")
    overlay.stop()
    XCTAssertNil(overlay.host)
  }

  private func until(
    _ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}
