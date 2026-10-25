import AppKit
import XCTest

@testable import Workroom

/// Opt-in: plays three chimes/bells and measures caller CPU and elapsed time separately.
@MainActor
final class FeedbackBenchmarkTests: XCTestCase {
  private func timing(_ operation: () -> Void) -> [String: Double] {
    let wall = DispatchTime.now().uptimeNanoseconds
    let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    operation()
    return [
      "cpu_ms": Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000,
      "wall_ms": Double(DispatchTime.now().uptimeNanoseconds - wall) / 1_000_000,
    ]
  }

  func testFeedbackCallerTimings() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-feedback")
    var chimes: [[String: Double]] = []
    var bells: [[String: Double]] = []
    var probes: [[String: Double]] = []
    var slowProbes: [[String: Double]] = []
    var chimeMainTurn: [Double] = []
    var preparedAccess: [[String: Double]] = []
    var preparationWait: [[String: Double]] = []
    var preparationMainTurn: [Double] = []
    for _ in 0..<3 {
      let mainTurnStart = DispatchTime.now().uptimeNanoseconds
      var chime: Task<Void, Never>?
      chimes.append(timing { chime = NotificationSound.play() })
      let nextMainTurn = Task { @MainActor in
        Double(DispatchTime.now().uptimeNanoseconds - mainTurnStart) / 1_000_000
      }
      await chime?.value
      chimeMainTurn.append(await nextMainTurn.value)
      var bell: Task<Void, Never>?
      bells.append(timing { bell = SoundFeedback.shared.request(.terminalBell) })
      await bell?.value
      probes.append(
        timing {
          XCTAssertTrue(SessionBackendProbe.probe(.daemon).isReady, "measure the bundled daemon")
        })
      let service = PersistentSessionService(
        probe: { _ in
          Thread.sleep(forTimeInterval: 0.2)
          return .ready(version: "delayed fixture")
        }, ownership: { _ in .notOwned })
      slowProbes.append(timing { XCTAssertEqual(service.backend, .daemon) })
      let prepared = PersistentSessionService(
        probe: { _ in
          Thread.sleep(forTimeInterval: 0.2)
          return .ready(version: "delayed fixture")
        }, ownership: { _ in .notOwned })
      let preparationWall = DispatchTime.now().uptimeNanoseconds
      let preparationCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      let preparationPulse = Task { @MainActor in
        Double(DispatchTime.now().uptimeNanoseconds - preparationWall) / 1_000_000
      }
      await prepared.prepareBackend()
      preparationWait.append([
        "cpu_ms": Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - preparationCPU)
          / 1_000_000,
        "wall_ms": Double(DispatchTime.now().uptimeNanoseconds - preparationWall) / 1_000_000,
      ])
      preparationMainTurn.append(await preparationPulse.value)
      preparedAccess.append(timing { XCTAssertEqual(prepared.backend, .daemon) })
      try await Task.sleep(for: .milliseconds(600))
    }
    try BenchmarkFixtures.write(
      [
        "configuration": "Debug", "notification_chime": chimes, "terminal_bell": bells,
        "chime_next_main_turn_ms": chimeMainTurn,
        "bundled_protocol_probe": probes, "delayed_first_backend": slowProbes,
        "prepared_backend_access": preparedAccess, "preparation_wait": preparationWait,
        "preparation_next_main_turn_ms": preparationMainTurn,
      ], to: BenchmarkFixtures.reportURL(named: "feedback"))
  }
}
