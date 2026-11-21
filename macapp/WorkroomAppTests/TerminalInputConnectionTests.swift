import DaemonConnection
import DaemonConnectionTestSupport
import XCTest

@testable import Workroom

/// The terminal API's `events.subscribe` on the shared daemon connection (#696), against
/// `FakeDaemon`: a stream of replies on one stream, which must never disturb the connection's
/// other services.
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

  /// Subscribed once the snapshot's first reply comes; then each send reaches the subscriber, as
  /// many replies on the one stream as the daemon sends, and VCS goes on answering beside them.
  func testEachSendReachesTheSubscriberAndTheConnectionGoesOn() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await DaemonClient.connect(host: .local, socketPath: fake.socketPath)
    let received = AsyncStream<TerminalInputEvent>.makeStream()
    let availability = try await connection.subscribeTerminalInput {
      received.continuation.yield($0)
    }
    XCTAssertEqual(availability, .available)
    XCTAssertEqual(fake.receivedTerminalAPIRequests.count, 1)
    XCTAssertTrue(fake.receivedTerminalAPIRequests[0].contains(#""method":"events.subscribe""#))
    let stream = try XCTUnwrap(fake.terminalAPIStreams.first)

    fake.push(service: 8, stream: stream, payload: input(sender: sender))
    fake.push(service: 8, stream: stream, payload: input(sender: nil))
    var events = received.stream.makeAsyncIterator()
    let id = try XCTUnwrap(UUID(uuidString: session))
    let first = await events.next()
    XCTAssertEqual(first, .input(session: id, sender: UUID(uuidString: sender)))
    let second = await events.next()
    XCTAssertEqual(second, .input(session: id, sender: nil))
    _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
    await connection.close()
  }

  /// A reply split across envelopes is read whole, as every other service's is.
  func testAReplyInChunksIsReadWhole() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    defer { fake.stop() }
    let connection = try await DaemonClient.connect(host: .local, socketPath: fake.socketPath)
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
    let connection = try await DaemonClient.connect(host: .local, socketPath: fake.socketPath)
    let availability = try await connection.subscribeTerminalInput { _ in }
    XCTAssertEqual(availability, .unsupported)
    _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
    XCTAssertFalse(fake.receivedServices.contains(8))
    await connection.close()
  }

  /// A refusal (past the daemon's subscription limits) says why, and the connection goes on.
  func testARefusalSaysWhy() async throws {
    let fake = try FakeDaemon(
      version: 12,
      terminalAPIReplies: [
        #"{"revision":1,"more":false,"error":{"kind":"Busy","message":"too many"}}"#
      ])
    defer { fake.stop() }
    let connection = try await DaemonClient.connect(host: .local, socketPath: fake.socketPath)
    let availability = try await connection.subscribeTerminalInput { _ in }
    XCTAssertEqual(availability, .refused("too many"))
    _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
    await connection.close()
  }

  /// The daemon going away hands the subscriber `.lost`, so the monitor subscribes again on the
  /// next connection.
  func testADroppedLinkHandsTheSubscriberLost() async throws {
    let fake = try FakeDaemon(version: 12, terminalAPIReplies: [snapshotComplete])
    let connection = try await DaemonClient.connect(host: .local, socketPath: fake.socketPath)
    let lost = expectation(description: "lost")
    _ = try await connection.subscribeTerminalInput { event in
      if event == .lost { lost.fulfill() }
    }
    fake.stop()
    await fulfillment(of: [lost], timeout: 5)
    await connection.close()
  }
}
