import CoreGraphics
import XCTest

@testable import Workroom

/// `SnapshotCache` (issue #132, T12): bounded by count and bytes, with an injected clock, and stale on
/// a theme change rather than wrong.
final class SnapshotCacheTests: XCTestCase {

  /// A real `CGImage` of a known size, so the byte accounting is measured rather than asserted.
  private func image(_ side: Int = 8) -> CGImage {
    let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
  }

  private func paneKey(_ n: Int) -> SnapshotKey {
    // A UUID per index, stable within the test.
    .pane(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
  }

  func testStoreAndFetch() {
    let cache = SnapshotCache()
    cache.store(image(), for: paneKey(1), themeGeneration: 3)
    XCTAssertNotNil(cache.snapshot(for: paneKey(1), themeGeneration: 3))
    XCTAssertEqual(cache.count, 1)
  }

  func testAMissIsNil() {
    XCTAssertNil(SnapshotCache().snapshot(for: paneKey(9), themeGeneration: 1))
  }

  func testAStaleThemeEntryIsDroppedNotReturned() {
    // The terminal's own colours changed, so the cached picture is of a theme that is no longer on
    // screen. Returning it would show the old theme inside the new one.
    let cache = SnapshotCache()
    cache.store(image(), for: paneKey(1), themeGeneration: 3)
    XCTAssertNil(cache.snapshot(for: paneKey(1), themeGeneration: 4), "stale ⇒ miss")
    XCTAssertEqual(cache.count, 0, "and evicted, so it can't linger")
  }

  func testTheClockIsInjected() {
    let fixed = Date(timeIntervalSince1970: 1_000_000)
    let cache = SnapshotCache(now: { fixed })
    cache.store(image(), for: paneKey(1), themeGeneration: 1)
    XCTAssertEqual(cache.snapshot(for: paneKey(1), themeGeneration: 1)?.capturedAt, fixed)
  }

  func testEvictionIsLeastRecentlyUsedNotInsertionOrder() {
    let cache = SnapshotCache()
    for n in 0..<SnapshotCache.maxEntries {
      cache.store(image(), for: paneKey(n), themeGeneration: 1)
    }
    // Re-read the oldest, making it most-recent — it must now SURVIVE the next insert.
    _ = cache.snapshot(for: paneKey(0), themeGeneration: 1)
    cache.store(image(), for: paneKey(999), themeGeneration: 1)
    XCTAssertEqual(cache.count, SnapshotCache.maxEntries)
    XCTAssertNotNil(cache.snapshot(for: paneKey(0), themeGeneration: 1), "recently used, kept")
    XCTAssertNil(
      cache.snapshot(for: paneKey(1), themeGeneration: 1), "least recently used, evicted")
  }

  func testTheCountCapHolds() {
    let cache = SnapshotCache()
    for n in 0..<(SnapshotCache.maxEntries * 2) {
      cache.store(image(), for: paneKey(n), themeGeneration: 1)
    }
    XCTAssertEqual(cache.count, SnapshotCache.maxEntries)
  }

  func testTheByteCapHolds() {
    let cache = SnapshotCache()
    // ~4 MB each: a handful blows the byte cap well before the count cap.
    let big = image(1024)
    for n in 0..<20 { cache.store(big, for: paneKey(n), themeGeneration: 1) }
    XCTAssertLessThanOrEqual(cache.byteSize, SnapshotCache.maxBytes)
    XCTAssertLessThan(cache.count, 20, "bytes bound before the count does")
    XCTAssertGreaterThanOrEqual(cache.count, 1, "never evicts down to empty")
  }

  func testForgetPanesDropsClosedTabs() {
    let cache = SnapshotCache()
    cache.store(image(), for: paneKey(1), themeGeneration: 1)
    cache.store(image(), for: paneKey(2), themeGeneration: 1)
    guard case .pane(let id1) = paneKey(1) else { return XCTFail("key shape") }
    cache.forgetPanes([id1])
    XCTAssertNil(cache.snapshot(for: paneKey(1), themeGeneration: 1))
    XCTAssertNotNil(cache.snapshot(for: paneKey(2), themeGeneration: 1), "siblings untouched")
  }

  func testTheSameWorkroomInTwoWindowsGetsTwoEntries() {
    // The whole reason a workroom key carries a WindowToken: co-displayed workrooms are two different
    // pictures, and one must not overwrite the other.
    let cache = SnapshotCache()
    let sid = SidebarID.workroom(project: "/p", name: "fox")
    let a = SnapshotKey.workroom(sid, WindowToken())
    let b = SnapshotKey.workroom(sid, WindowToken())
    cache.store(image(), for: a, themeGeneration: 1)
    cache.store(image(), for: b, themeGeneration: 1)
    XCTAssertEqual(cache.count, 2)
    XCTAssertNotNil(cache.snapshot(for: a, themeGeneration: 1))
    XCTAssertNotNil(cache.snapshot(for: b, themeGeneration: 1))
  }

  func testRemoveAll() {
    let cache = SnapshotCache()
    cache.store(image(), for: paneKey(1), themeGeneration: 1)
    cache.removeAll()
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.byteSize, 0)
  }
}
