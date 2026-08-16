import Darwin
import XCTest

@testable import WorkroomSessionProtocol

/// `SessionByteQueue`'s `drain` is normally exercised only indirectly, through whatever
/// `SessionConnection`/`PTYSession` traffic happens to touch it — this drives its `wouldBlock`
/// admission path directly against a real, unread pipe (the actual condition it exists to handle:
/// a peer that's fallen behind), rather than a descriptor that always accepts.
final class SessionByteQueueTests: XCTestCase {
  private func makePipe() -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&descriptors), 0)
    // Both ends non-blocking: the write end so `drain` sees a real `wouldBlock` instead of
    // stalling the test, and the read end so draining "whatever's currently buffered" in a loop
    // can observe `.wouldBlock`/no-more-data instead of parking the test host in a blocking
    // `read()` forever once the buffer's momentarily empty.
    SessionIO.setNonBlocking(descriptors[0])
    SessionIO.setNonBlocking(descriptors[1])
    return (descriptors[0], descriptors[1])
  }

  func testDrainFlushesWithoutBlockingWhenTheReaderKeepsUp() {
    let (readFD, writeFD) = makePipe()
    defer {
      SessionIO.close(readFD)
      SessionIO.close(writeFD)
    }

    var queue = SessionByteQueue()
    queue.enqueue(Array("hello".utf8))
    XCTAssertTrue(queue.hasPendingOutput)

    XCTAssertEqual(queue.drain(to: writeFD), .wrote(0))
    XCTAssertFalse(queue.hasPendingOutput)
    XCTAssertEqual(queue.pendingByteCount, 0)

    guard case .bytes(let read) = SessionIO.read(readFD) else { return XCTFail("expected bytes") }
    XCTAssertEqual(read, Array("hello".utf8))
  }

  /// The admission path this suite exists to cover: enqueue far more than a pipe will ever buffer
  /// unread, drain once (a real short write followed by a real `EAGAIN`), then confirm the queue
  /// left itself correctly positioned to finish once the reader catches up.
  func testDrainReportsWouldBlockThenFinishesOnceTheReaderCatchesUp() {
    let (readFD, writeFD) = makePipe()
    defer {
      SessionIO.close(readFD)
      SessionIO.close(writeFD)
    }

    var queue = SessionByteQueue()
    let payload = [UInt8](repeating: 0x42, count: 8 * 1024 * 1024)
    queue.enqueue(payload)

    XCTAssertEqual(queue.drain(to: writeFD), .wouldBlock)
    XCTAssertTrue(queue.hasPendingOutput, "a short write must leave the remainder queued")
    let pendingAfterFirstDrain = queue.pendingByteCount
    XCTAssertGreaterThan(pendingAfterFirstDrain, 0)
    XCTAssertLessThan(
      pendingAfterFirstDrain, payload.count, "the pipe must have accepted a real, nonzero prefix")

    var received = 0
    var iterations = 0
    while queue.hasPendingOutput {
      iterations += 1
      XCTAssertLessThan(iterations, 10_000, "drain/read never converged")
      while case .bytes(let chunk) = SessionIO.read(readFD) {
        received += chunk.count
      }
      queue.drain(to: writeFD)
    }

    while case .bytes(let chunk) = SessionIO.read(readFD) {
      received += chunk.count
    }
    XCTAssertEqual(received, payload.count)
  }

  func testClearDiscardsPendingBytesWithoutWriting() {
    let (readFD, writeFD) = makePipe()
    defer {
      SessionIO.close(readFD)
      SessionIO.close(writeFD)
    }

    var queue = SessionByteQueue()
    queue.enqueue([UInt8](repeating: 0x01, count: 8 * 1024 * 1024))
    XCTAssertEqual(queue.drain(to: writeFD), .wouldBlock)
    XCTAssertTrue(queue.hasPendingOutput)

    queue.clear()
    XCTAssertFalse(queue.hasPendingOutput)
    XCTAssertEqual(queue.pendingByteCount, 0)
  }
}
