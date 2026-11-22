import DaemonConnection
import DaemonConnectionTestSupport
import Synchronization
import WorkroomWire
import XCTest

@testable import Workroom

/// The terminal API's `events.subscribe` on the shared daemon connection (#696), against
/// `FakeDaemon`: a stream of replies on one stream, which must never disturb the connection's
/// other services, and which the client ends here and on the daemon whenever it stops listening.
final class TerminalInputConnectionTests: XCTestCase {
  private let session = "c0ffee00-1111-4222-8333-44445555beef"
  private let sender = "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11"

  private func reply(_ event: String, more: Bool = true) -> String {
    #"{"revision":1,"more":\#(more),"result":\#(event)}"#
  }

  private var snapshotComplete: String {
    reply(#"{"event":"snapshot-complete","boot":"b","revision":3,"sessions":[]}"#)
  }

  private func input(sender: String?) -> Data {
    let sender = sender.map { #""\#($0)""# } ?? "null"
    let event =
      #"{"event":"session.input","boot":"b","revision":4,"session":"\#(session)","#
      + #""scope":null,"sender":\#(sender),"bytes":5}"#
    return Data([1]) + Data(reply(event).utf8)
  }

  private func connect(_ fake: FakeDaemon) async throws -> DaemonClient {
    try await DaemonClient.connect(host: .local, socketPath: fake.socketPath)
  }

  /// The connection still answers VCS: nothing on the reply stream failed it.
  private func stillAnswers(_ connection: DaemonClient) async throws {
    _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
  }

  private func subscription(_ availability: TerminalInputAvailability)
    -> TerminalInputSubscription?
  {
    if case .available(let subscription) = availability { return subscription }
    return nil
  }

  /// Waits up to 3 s for `condition`, then asserts it.
  private func until(
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), message(), file: file, line: line)
  }

  /// Subscribed once the snapshot's first reply comes; then each send reaches the subscriber, as
  /// many replies on the one stream as the daemon sends, and VCS goes on answering beside them.
  func testEachSendReachesTheSubscriberAndTheConnectionGoesOn() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await connect(fake)
    let received = AsyncStream<TerminalInputEvent>.makeStream()
    let availability = try await connection.subscribeTerminalInput {
      received.continuation.yield($0)
    }
    XCTAssertNotNil(subscription(availability), "\(availability)")
    XCTAssertEqual(fake.receivedTerminalAPIRequests.count, 1)
    XCTAssertTrue(fake.receivedTerminalAPIRequests[0].contains(#""method":"events.subscribe""#))
    let stream = try XCTUnwrap(fake.terminalAPIStreams.first)
    XCTAssertEqual(subscription(availability)?.stream, stream)

    fake.push(service: 8, stream: stream, payload: input(sender: sender))
    fake.push(service: 8, stream: stream, payload: input(sender: nil))
    var events = received.stream.makeAsyncIterator()
    let id = try XCTUnwrap(UUID(uuidString: session))
    let first = await events.next()
    XCTAssertEqual(first, .input(session: id, sender: UUID(uuidString: sender)))
    let second = await events.next()
    XCTAssertEqual(second, .input(session: id, sender: nil))
    try await stillAnswers(connection)
    await connection.close()
  }

  /// A reply split across envelopes is read whole, as every other service's is.
  func testAReplyInChunksIsReadWhole() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await connect(fake)
    let received = AsyncStream<TerminalInputEvent>.makeStream()
    _ = try await connection.subscribeTerminalInput { received.continuation.yield($0) }
    let stream = try XCTUnwrap(fake.terminalAPIStreams.first)
    let whole = input(sender: sender).dropFirst()
    let half = whole.count / 2
    fake.push(service: 8, stream: stream, payload: Data([0]) + whole.prefix(half))
    fake.push(service: 8, stream: stream, payload: Data([1]) + whole.dropFirst(half))
    var events = received.stream.makeAsyncIterator()
    let event = await events.next()
    XCTAssertEqual(
      event,
      .input(session: try XCTUnwrap(UUID(uuidString: session)), sender: UUID(uuidString: sender)))
    await connection.close()
  }

  /// A daemon before the terminal API fails the whole connection on its service byte, so it is
  /// never sent one.
  func testAnOlderDaemonIsUnsupportedAndNeverSentAnEnvelope() async throws {
    let fake = try FakeDaemon(version: 11, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await connect(fake)
    let availability = try await connection.subscribeTerminalInput { _ in }
    XCTAssertEqual(availability, .unsupported)
    try await stillAnswers(connection)
    XCTAssertFalse(fake.receivedServices.contains(8))
    await connection.close()
  }

  /// A daemon of protocol 12 from before `session.input` refuses the type as bad input: it has no
  /// typing to tell, as an older one has none.
  func testADaemonThatRefusesTheTypeHasNoTypingToTell() async throws {
    let fake = try FakeDaemon(
      version: 12,
      terminalAPIReplies: [
        #"{"revision":1,"more":false,"error":{"kind":"InvalidRequest","message":"no such type"}}"#
      ])
    defer { fake.stop() }
    let connection = try await connect(fake)
    let availability = try await connection.subscribeTerminalInput { _ in }
    XCTAssertEqual(availability, .unsupported)
    try await stillAnswers(connection)
    await connection.close()
  }

  // Value: protects=a daemon from before `session.labelled` still tells typing, `new` and `close`
  // (#694 review); fails_when=one type it lacks costs the whole subscription; why_new=#694 asked
  // for a type older protocol-12 daemons refuse; seam=FakeDaemon answering by method
  /// A daemon that refuses one of the types is asked which it knows, and subscribed to those: its
  /// typing reaches the subscriber.
  func testADaemonWithoutOneTypeIsSubscribedToTheOthers() async throws {
    let refused =
      #"{"revision":1,"more":false,"error":{"kind":"InvalidRequest","message":"unknown type"}}"#
    let described =
      #"{"revision":1,"more":false,"result":{"revision":1,"methods":[{"name":"events.subscribe","#
      + #""input":{"type":"object","properties":{"types":{"type":"array","items":{"type":"string","#
      + #""enum":["session.created","session.ended","session.input","client.attached"]}}}}}]}}"#
    let complete = snapshotComplete
    let fake = try FakeDaemon(
      version: 12,
      terminalAPIReplying: { request in
        if request.contains("api.describe") { return [described] }
        return request.contains("session.labelled") ? [refused] : [complete]
      })
    defer { fake.stop() }
    let connection = try await connect(fake)
    let received = AsyncStream<TerminalInputEvent>.makeStream()
    let availability = try await connection.subscribeTerminalInput {
      received.continuation.yield($0)
    }
    XCTAssertNotNil(subscription(availability), "\(availability)")
    let requests = fake.receivedTerminalAPIRequests
    XCTAssertEqual(requests.count, 3, "\(requests)")
    let last = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(requests.last).utf8))
        as? [String: Any])
    XCTAssertEqual(
      (last["params"] as? [String: Any])?["types"] as? [String],
      ["session.input", "session.created", "session.ended"])
    let stream = try XCTUnwrap(fake.terminalAPIStreams.last)
    fake.push(service: 8, stream: stream, payload: input(sender: sender))
    var events = received.stream.makeAsyncIterator()
    let event = await events.next()
    XCTAssertEqual(
      event,
      .input(session: try XCTUnwrap(UUID(uuidString: session)), sender: UUID(uuidString: sender)))
    try await stillAnswers(connection)
    await connection.close()
  }

  /// A refusal (past the daemon's subscription limits, or a reply too large) says why, and what
  /// the daemon still sends on that stream is dropped, never failing the connection.
  func testARefusalSaysWhyAndItsStreamIsSilenced() async throws {
    for kind in ["Busy", "TooLarge"] {
      let fake = try FakeDaemon(
        version: 12,
        terminalAPIReplies: [
          #"{"revision":1,"more":false,"error":{"kind":"\#(kind)","message":"no"}}"#
        ])
      defer { fake.stop() }
      let connection = try await connect(fake)
      let availability = try await connection.subscribeTerminalInput { _ in }
      XCTAssertEqual(availability, .refused("no"), kind)
      let stream = try XCTUnwrap(fake.terminalAPIStreams.first)
      fake.push(service: 8, stream: stream, payload: input(sender: sender))
      try await stillAnswers(connection)
      XCTAssertTrue(fake.receivedUnsubscribes.isEmpty, "the daemon ended it already")
      await connection.close()
    }
  }

  /// A subscription given up on (its first reply too late) is ended on the daemon and frees its
  /// slot here, so retries are never refused for dead ones, and what the daemon still sends on it
  /// is dropped unread rather than failing the connection.
  func testASubscriptionGivenUpOnIsEndedOnTheDaemonAndItsLateRepliesAreDropped() async throws {
    let fake = try FakeDaemon(version: 12)
    defer { fake.stop() }
    let connection = try await connect(fake)
    // Past the connection's 4 slots: each one timed out, none refused for want of a slot.
    for _ in 0..<6 {
      do {
        _ = try await connection.subscribeTerminalInput(timeout: 0.2) { _ in }
        XCTFail("a daemon that never answers subscribed")
      } catch {
        XCTAssertEqual(error as? HostConnectionError, .requestTimedOut)
      }
    }
    await until("\(fake.receivedUnsubscribes)") { fake.receivedUnsubscribes.count == 6 }
    let streams = fake.terminalAPIStreams
    for (stream, request) in zip(streams, fake.receivedUnsubscribes) {
      XCTAssertTrue(request.contains(#""stream":\#(stream)"#), request)
    }
    fake.push(service: 8, stream: try XCTUnwrap(streams.first), payload: input(sender: sender))
    try await stillAnswers(connection)
    await connection.close()
  }

  /// A subscriber that stops waiting (its task cancelled) ends the subscription on the daemon too.
  func testCancellingTheSubscribeEndsItOnTheDaemon() async throws {
    let fake = try FakeDaemon(version: 12)
    defer { fake.stop() }
    let connection = try await connect(fake)
    let task = Task { try await connection.subscribeTerminalInput { _ in } }
    await until { !fake.terminalAPIStreams.isEmpty }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("a cancelled subscribe subscribed")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    await until { fake.receivedUnsubscribes.count == 1 }
    let stream = try XCTUnwrap(fake.terminalAPIStreams.first)
    fake.push(service: 8, stream: stream, payload: input(sender: sender))
    try await stillAnswers(connection)
    await connection.close()
  }

  /// Ending a live subscription ends it on the daemon, stops its events, and drops what was
  /// already on its way.
  func testEndingALiveSubscriptionStopsItsEvents() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await connect(fake)
    let heard = Mutex(0)
    let availability = try await connection.subscribeTerminalInput { event in
      if case .input = event { heard.withLock { $0 += 1 } }
    }
    let subscription = try XCTUnwrap(subscription(availability))
    subscription.end()
    await until { fake.receivedUnsubscribes.count == 1 }
    fake.push(service: 8, stream: subscription.stream, payload: input(sender: sender))
    try await stillAnswers(connection)
    XCTAssertEqual(heard.withLock { $0 }, 0)
    await connection.close()
  }

  /// A reply that can't be read ends its stream here and on the daemon, and the subscriber hears
  /// it end; what follows on it is dropped.
  func testAnUnreadableReplyEndsTheStreamNotTheConnection() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await connect(fake)
    let lost = Mutex(false)
    _ = try await connection.subscribeTerminalInput { event in
      if event == .lost { lost.withLock { $0 = true } }
    }
    let stream = try XCTUnwrap(fake.terminalAPIStreams.first)
    fake.push(service: 8, stream: stream, payload: Data([1]) + Data("not json".utf8))
    await until { lost.withLock { $0 } }
    await until { fake.receivedUnsubscribes.count == 1 }
    fake.push(service: 8, stream: stream, payload: input(sender: sender))
    try await stillAnswers(connection)
    await connection.close()
  }

  /// A reply past the 16 MiB ceiling ends its stream here and on the daemon, not the connection.
  func testAReplyPastTheCeilingEndsTheStreamNotTheConnection() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await connect(fake)
    let lost = Mutex(false)
    _ = try await connection.subscribeTerminalInput { event in
      if event == .lost { lost.withLock { $0 = true } }
    }
    let stream = try XCTUnwrap(fake.terminalAPIStreams.first)
    let chunk = Data([0]) + Data(repeating: 0x20, count: (1 << 20) - 1)
    for _ in 0..<17 { fake.push(service: 8, stream: stream, payload: chunk) }
    fake.push(service: 8, stream: stream, payload: Data([1]) + Data("}".utf8))
    await until { lost.withLock { $0 } }
    await until { fake.receivedUnsubscribes.count == 1 }
    try await stillAnswers(connection)
    await connection.close()
  }

  /// The daemon going away hands the subscriber `.lost`, so the monitor subscribes again on the
  /// next connection.
  func testADroppedLinkHandsTheSubscriberLost() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    let connection = try await connect(fake)
    let lost = expectation(description: "lost")
    _ = try await connection.subscribeTerminalInput { event in
      if event == .lost { lost.fulfill() }
    }
    fake.stop()
    await fulfillment(of: [lost], timeout: 5)
    await connection.close()
  }
}

/// The same against a real `workroomd`, with its real limits (8 subscriptions a connection): a
/// link that gives up on far more subscriptions than that is never refused `Busy`, because each
/// one it gives up on is ended on the daemon too (`events.unsubscribe`).
final class TerminalInputLiveDaemonTests: XCTestCase {
  func testGivingUpOnSubscriptionsNeverReachesTheDaemonsLimit() async throws {
    let daemon = try DaemonHarness.start()
    defer { daemon.stop() }
    let connection = try await DaemonClient.connect(host: .local, socketPath: daemon.socketPath)
    for attempt in 0..<12 {
      // Given up on at once, before or after the daemon answers: either way it ends.
      do {
        let availability = try await connection.subscribeTerminalInput(timeout: 0) { _ in }
        guard case .available(let subscription) = availability else {
          return XCTFail("attempt \(attempt) was refused: \(availability)")
        }
        subscription.end()
      } catch {
        XCTAssertEqual(error as? HostConnectionError, .requestTimedOut, "attempt \(attempt)")
      }
      // Its place is given back once the daemon has read the unsubscribe; the next subscribe
      // goes out after it, on the same connection, in order.
    }
    let availability = try await connection.subscribeTerminalInput(timeout: 15) { _ in }
    guard case .available(let subscription) = availability else {
      return XCTFail("refused after giving up on 12: \(availability)")
    }
    subscription.end()
    await connection.close()
  }

  // Value: protects=a renamed tab's name reaching its session's label on a real daemon, and the
  // label coming back to every subscriber once (#694); fails_when=the app's request or the event
  // it reads drifts from the daemon's wire, or the daemon tells an unchanged label (an echo loop);
  // why_new=labels never changed after creation; seam=none
  /// `labelSession` labels a real session, which the session list then names it by, and the
  /// subscription hears `session.labelled` once; the same label again changes nothing and is told
  /// nothing. The snapshot that starts a subscription says each session's label.
  func testALabelReachesTheDaemonAndComesBackToTheSubscriberOnce() async throws {
    let daemon = try DaemonHarness.start()
    defer { daemon.stop() }
    let session = UUID()
    try daemon.startSession(
      identifier: session, metadata: [(SessionMetadataKey.title, "Terminal 1")])
    let connection = try await DaemonClient.connect(host: .local, socketPath: daemon.socketPath)
    for _ in 0..<100 {
      if try await connection.sessions().contains(where: { $0.identifier.uuid == session }) {
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let received = AsyncStream<TerminalInputEvent>.makeStream()
    let availability = try await connection.subscribeTerminalInput(timeout: 15) {
      received.continuation.yield($0)
    }
    guard case .available(let subscription) = availability else {
      return XCTFail("not subscribed: \(availability)")
    }
    var events = received.stream.makeAsyncIterator()
    let listed = await events.next()
    XCTAssertEqual(listed, .listed(session: session, label: "Terminal 1"))

    let first = try await connection.labelSession(session, label: "web")
    XCTAssertEqual(first, .labelled(changed: true))
    let told = await events.next()
    XCTAssertEqual(told, .labelled(session: session, label: "web"))
    let again = try await connection.labelSession(session, label: "web")
    XCTAssertEqual(again, .labelled(changed: false))
    let cleared = try await connection.labelSession(session, label: nil)
    XCTAssertEqual(cleared, .labelled(changed: true))
    let next = await events.next()
    XCTAssertEqual(next, .labelled(session: session, label: nil), "the same label told nothing")
    let gone = try await connection.labelSession(UUID(), label: "x")
    guard case .refused(kind: "TargetNotFound", _) = gone else {
      return XCTFail("a session the daemon doesn't hold: \(gone)")
    }
    let listedNow = try await connection.sessions().first { $0.identifier.uuid == session }
    XCTAssertNil(listedNow?.value(forMetadataKey: SessionMetadataKey.title))
    subscription.end()
    await connection.close()
  }
}
