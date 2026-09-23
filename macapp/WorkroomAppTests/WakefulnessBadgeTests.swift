import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The badge owns its polling. With no status yet, or after a failed poll cleared it, the badge
/// draws nothing, and its poll must still run: nothing else refreshes it. Pins that a `.task` on a
/// childless `Group` still runs (measured), which a review claimed it would not.
@MainActor
final class WakefulnessBadgeTests: XCTestCase {
  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  private struct NoAgent: Error {}

  func testABadgeWithNoStatusStillPolls() async throws {
    let requests = Counter()
    let model = WakefulnessModel(
      transport: .init(
        status: {
          requests.bump()
          throw NoAgent()
        },
        keep: {},
        prompts: { throw NoAgent() }))
    let hosting = NSHostingView(rootView: WakefulnessBadge(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    let deadline = Date().addingTimeInterval(5)
    while requests.count == 0, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThan(requests.count, 0, "a badge with no status never polled for one")
    XCTAssertNil(model.status)
  }
}
