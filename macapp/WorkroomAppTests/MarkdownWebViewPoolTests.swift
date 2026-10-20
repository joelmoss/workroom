import AppKit
import WebKit
import XCTest

@testable import Workroom

/// `MarkdownWebViewPool`: the booted page a preview opens on, and what happens to a closed
/// preview's page. Drives real `WKWebView`s against the bundled template, on pools of its own so
/// the app's shared spare is untouched.
@MainActor
final class MarkdownWebViewPoolTests: XCTestCase {

  // Value: protects=a closed preview's page is reused and comes back empty, scrolled to the top;
  // fails_when=give() stops keeping the page or stops clearing it, so the next file opens on the
  // last one's text; why_new=the pool is new; seam=none; no_claim=timing.
  func testAClosedPreviewsPageComesBackEmptyForTheNext() async throws {
    let page = try await loadedSpare(MarkdownWebViewPool())
    _ = try await page.callAsyncJavaScript(
      "window.__render(source); window.scrollTo(0, 400);",
      arguments: ["source": String(repeating: "Earlier file.\n\n", count: 400)],
      contentWorld: .page)

    let pool = MarkdownWebViewPool()  // empty, as after its spare was taken
    pool.give(page)
    let reused = try XCTUnwrap(pool.take())
    XCTAssertTrue(reused.webView === page, "the closed preview's page was not reused")
    XCTAssertTrue(reused.isLoaded)
    let text = try await page.evaluateJavaScript(
      "document.getElementById('content').textContent + '|' + window.scrollY")
    XCTAssertEqual(text as? String, "|0", "the reused page still shows the earlier file")
  }

  // Value: protects=a booted spare is kept over a returned page; fails_when=give() replaces a
  // loaded spare; why_new=the pool is new; seam=none; no_claim=which page is faster.
  func testALoadedSpareIsKeptOverAReturnedPage() async throws {
    let pool = MarkdownWebViewPool()
    let spare = try await loadedSpare(pool)
    pool.give(WKWebView(frame: .zero))
    XCTAssertTrue(pool.spare === spare)
  }

  /// Boots the pool's spare and waits for its template to finish loading.
  private func loadedSpare(_ pool: MarkdownWebViewPool) async throws -> WKWebView {
    pool.prewarm()
    for _ in 0..<200 where !pool.spareIsLoaded {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(pool.spareIsLoaded, "the spare never finished loading")
    return try XCTUnwrap(pool.spare)
  }
}
