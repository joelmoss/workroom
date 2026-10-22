import DaemonConnection
import XCTest

@testable import Workroom

/// `Service::ProgramStatus` on the shared daemon connection (#358), against `FakeDaemon`.
final class ProgramStatusConnectionTests: XCTestCase {
  private let session = UUID()

  private func status(_ state: String, session: UUID) -> Data {
    let json = """
      {"event":"status","boot":"b","session":"\(session.uuidString.lowercased())","revision":1,\
      "reporting":true,"records":[{"id":"","state":"\(state)","kind":"permission","progress":-1,\
      "app":"claude-code","title":"","message":"Apply?","episode":1,"notify":true}]}
      """
    return Data([1]) + Data(json.utf8)
  }

  /// Events reach the subscriber, and an event this build cannot read neither reaches it nor fails
  /// the connection: VCS keeps answering after it.
  func testEventsReachTheSubscriberAndAnUnreadableOneIsDropped() async throws {
    let fake = try FakeDaemon(version: 8, programStatusResult: #"{"available":true}"#)
    defer { fake.stop() }
    let connection = try await DaemonVCSConnection.connect(
      host: .local, socketPath: fake.socketPath)
    let received = AsyncStream<ProgramStatusEvent>.makeStream()
    let availability = try await connection.subscribeProgramStatus {
      received.continuation.yield($0)
    }
    XCTAssertEqual(availability, .available)
    XCTAssertEqual(fake.receivedProgramStatusRequests.count, 1)
    XCTAssertTrue(fake.receivedProgramStatusRequests[0].contains(#""method":"subscribe""#))

    fake.push(service: 7, stream: 0, payload: Data([1]) + Data("not json".utf8))
    fake.push(service: 7, stream: 0, payload: status("blocked", session: session))
    var events = received.stream.makeAsyncIterator()
    guard case .status(_, let id, _, _, let records) = await events.next() else {
      return XCTFail("no status event")
    }
    XCTAssertEqual(id, session)
    XCTAssertEqual(records.map(\.state), [.blocked])
    _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
    await connection.close()
  }

  /// A protocol-7 daemon drops a ProgramStatus envelope unanswered, so it is never sent one.
  func testAnOlderAgentIsUnsupportedAndNeverSentAnEnvelope() async throws {
    let fake = try FakeDaemon(version: 7, programStatusResult: #"{"available":true}"#)
    defer { fake.stop() }
    let connection = try await DaemonVCSConnection.connect(
      host: .local, socketPath: fake.socketPath)
    let availability = try await connection.subscribeProgramStatus { _ in }
    XCTAssertEqual(availability, .unsupported)
    _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
    XCTAssertFalse(fake.receivedServices.contains(7))
    await connection.close()
  }

  func testAnAgentWithoutTerminalStateIsUnavailableWithItsReason() async throws {
    let fake = try FakeDaemon(
      version: 8, programStatusResult: #"{"available":false,"reason":"no terminal-state"}"#)
    defer { fake.stop() }
    let connection = try await DaemonVCSConnection.connect(
      host: .local, socketPath: fake.socketPath)
    let availability = try await connection.subscribeProgramStatus { _ in }
    XCTAssertEqual(availability, .unavailable("no terminal-state"))
    await connection.close()
  }

  /// The daemon going away hands the subscriber `.lost`, so the monitor keeps the host's records,
  /// marks them stale after the grace and reconnects.
  func testADroppedLinkHandsTheSubscriberLost() async throws {
    let fake = try FakeDaemon(version: 8, programStatusResult: #"{"available":true}"#)
    let connection = try await DaemonVCSConnection.connect(
      host: .local, socketPath: fake.socketPath)
    let lost = expectation(description: "lost")
    _ = try await connection.subscribeProgramStatus { event in
      if event == .lost { lost.fulfill() }
    }
    fake.stop()
    await fulfillment(of: [lost], timeout: 5)
    await connection.close()
  }
}
