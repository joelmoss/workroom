import XCTest

@testable import Workroom

@MainActor
final class SoundFeedbackTests: XCTestCase {
  private actor Player {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [SoundFeedback.Kind] = []
    private let started: XCTestExpectation?

    init(started: XCTestExpectation? = nil) { self.started = started }

    func play(_ kind: SoundFeedback.Kind) async {
      calls.append(kind)
      await withCheckedContinuation {
        waiting.append($0)
        if let started, calls.count <= started.expectedFulfillmentCount { started.fulfill() }
      }
    }

    func finish() {
      let all = waiting
      waiting.removeAll()
      for continuation in all { continuation.resume() }
    }
  }

  func testTerminalFloodAdmitsOnlyOnePendingSound() async {
    let started = expectation(description: "audio operation started")
    let player = Player(started: started)
    let feedback = SoundFeedback(play: { await player.play($0) })
    let accepted = (0..<100).filter { _ in feedback.request(.terminalBell) != nil }.count
    XCTAssertEqual(accepted, 1, "a BEL burst must not enqueue one audio operation per byte")
    await fulfillment(of: [started], timeout: 2)
    let calls = await player.calls
    XCTAssertEqual(calls.count, 1)
    await player.finish()
  }

  func testNotificationAndBellHaveIndependentLimits() async {
    let started = expectation(description: "both audio kinds started")
    started.expectedFulfillmentCount = 2
    let player = Player(started: started)
    let feedback = SoundFeedback(play: { await player.play($0) })
    XCTAssertNotNil(feedback.request(.terminalBell))
    XCTAssertNotNil(feedback.request(.notification), "terminal output must not suppress a notice")
    XCTAssertNil(feedback.request(.notification))
    await fulfillment(of: [started], timeout: 2)
    await player.finish()
  }

  func testPendingOperationCannotAccumulateWorkAfterCooldown() async {
    var clock = 100.0
    let started = expectation(description: "first playback")
    let release = Player(started: started)
    let feedback = SoundFeedback(
      now: { clock },
      play: { kind in
        await release.play(kind)
      })
    let task = feedback.request(.notification)
    XCTAssertNotNil(task)
    await fulfillment(of: [started], timeout: 2)
    clock += 10
    XCTAssertNil(feedback.request(.notification), "slow audio must not build a queue")
    await release.finish()
    await task?.value
  }

  func testCooldownStillAppliesAfterAudioCallReturns() async {
    var clock = 100.0
    let feedback = SoundFeedback(now: { clock }, play: { _ in })
    let notification = feedback.request(.notification)
    let bell = feedback.request(.terminalBell)
    await notification?.value
    await bell?.value
    clock += 0.25
    XCTAssertNil(feedback.request(.notification))
    let nextBell = feedback.request(.terminalBell)
    XCTAssertNotNil(nextBell)
    await nextBell?.value
    clock += 0.25
    let nextNotification = feedback.request(.notification)
    XCTAssertNotNil(nextNotification)
    await nextNotification?.value
  }
}
