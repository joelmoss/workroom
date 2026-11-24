import XCTest

@testable import Workroom

/// The bounded cache of recently followed repositories' last-known reads (#803, QA round 2).
final class RecentRepositoryCacheTests: XCTestCase {
  /// Value: protects=the cache's bound and order; fails_when=it grows past its capacity, or drops
  /// a repository used lately rather than the least recently used; why_new=QA round 2;
  /// seam=RecentRepositoryCache; no_claim=what callers keep in it
  func testItKeepsTheMostRecentlyUsedUpToItsCapacity() {
    var cache = RecentRepositoryCache<Int>(capacity: 8)
    for i in 0..<8 { cache.store(i, for: "/r\(i)") }
    XCTAssertEqual(cache.value(for: "/r0"), 0, "a read makes it the most recently used")
    cache.store(8, for: "/r8")

    XCTAssertNil(cache.value(for: "/r1"), "the least recently used goes first")
    XCTAssertEqual(cache.value(for: "/r0"), 0)
    XCTAssertEqual(cache.keys.count, 8)

    cache.store(80, for: "/r8")
    XCTAssertEqual(cache.value(for: "/r8"), 80, "a store replaces")
    XCTAssertEqual(cache.keys.count, 8)
    cache.remove("/r8")
    XCTAssertNil(cache.value(for: "/r8"))
    XCTAssertEqual(cache.keys.count, 7)
  }

  /// Value: protects=the dictionary-style access the per-window memories use (#812 F7): a read
  /// through the subscript counts as a use, a nil write forgets, and a filter drops matches;
  /// fails_when=a subscript read doesn't refresh recency, or removeAll keeps a match;
  /// why_new=#812 perf F7; seam=RecentCache; no_claim=what callers keep in it
  func testItReadsAndWritesLikeADictionary() {
    var cache = RecentCache<Int, String?>(capacity: 3)
    cache[1] = .some(nil)
    cache[2] = "b"
    cache[3] = "c"
    XCTAssertEqual(cache[1], .some(nil), "an optional value is kept as itself")
    cache[4] = "d"
    XCTAssertNil(cache[2], "the least recently used goes first")
    XCTAssertEqual(cache.keys, [3, 1, 4])

    cache[3] = nil
    XCTAssertEqual(cache.keys, [1, 4])
    cache.removeAll { key, _ in key == 4 }
    XCTAssertEqual(cache.keys, [1])
    XCTAssertEqual(cache.count, 1)
  }

  /// Value: protects=a remembered scroll costing O(1) per frame however full the memory is
  /// (#812 F7); fails_when=a write to a present key scans every entry; why_new=#812 perf F7;
  /// seam=RecentCache; no_claim=absolute speed of a cold insert
  func testRewritingAPresentKeyStaysFastAtCapacity() {
    var cache = RecentCache<Int, Double>(capacity: 4096)
    for i in 0..<4096 { cache[i] = Double(i) }
    let start = Date()
    for frame in 0..<100_000 { cache[frame % 4096] = Double(frame) }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(cache.count, 4096)
    XCTAssertLessThan(elapsed, 0.5, "100k rewrites took \(elapsed)s")
  }
}
