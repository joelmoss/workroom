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
}
