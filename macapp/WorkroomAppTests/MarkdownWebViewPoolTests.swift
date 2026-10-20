import AppKit
import WebKit
import XCTest

@testable import Workroom

/// `MarkdownWebViewPool`: the booted page a preview opens on. Drives real `WKWebView`s against the
/// bundled template, on a pool of its own so the app's shared spare is untouched.
@MainActor
final class MarkdownWebViewPoolTests: XCTestCase {

  // Value: protects=a preview gets a booted page and the next one starts booting at once;
  // fails_when=take() stops refilling (every later preview boots from scratch) or hands out a
  // page as loaded before its template is; why_new=the pool is new; seam=none; no_claim=timing.
  func testTakingTheBootedPageStartsBootingTheNext() async throws {
    let pool = MarkdownWebViewPool()
    pool.prewarm()
    try await waitUntilLoaded(pool)
    let first = try XCTUnwrap(pool.spare)

    let taken = try XCTUnwrap(pool.take())
    XCTAssertTrue(taken.webView === first)
    XCTAssertTrue(taken.isLoaded)
    let next = try XCTUnwrap(pool.spare, "no page started booting for the next preview")
    XCTAssertFalse(next === first)
    try await waitUntilLoaded(pool)
    let content = try await next.evaluateJavaScript("typeof window.__render")
    XCTAssertEqual(content as? String, "function", "the next page did not load the template")
  }

  private func waitUntilLoaded(_ pool: MarkdownWebViewPool) async throws {
    for _ in 0..<200 where !pool.spareIsLoaded {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(pool.spareIsLoaded, "the spare never finished loading")
  }
}
