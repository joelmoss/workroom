import AppKit
import DesignSystem
import SwiftUI
import WebKit
import XCTest

@testable import Workroom

/// `MarkdownWebViewPool`: the booted page a preview opens on. Drives real `WKWebView`s against the
/// bundled template. Most use a pool of their own; the two that drive a real `MarkdownWebView` can
/// only reach the app's shared one, whose spare they take (it refills itself).
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

  // Value: protects=the pool refills after macOS kills the idle spare's process; fails_when=take()
  // stops booting a new spare when it has none, so every later preview boots from scratch until
  // relaunch; why_new=the refill on an empty take() is new; seam=none; no_claim=real OS jetsam.
  func testAPoolWhoseSpareWasKilledRefillsOnTheNextTake() throws {
    let pool = MarkdownWebViewPool()
    pool.prewarm()
    let killed = try XCTUnwrap(pool.spare)
    pool.webViewWebContentProcessDidTerminate(killed)
    XCTAssertNil(pool.spare)

    XCTAssertNil(pool.take(), "with no spare, the preview boots its own page")
    let next = try XCTUnwrap(pool.spare, "the pool never refilled after its spare was killed")
    XCTAssertFalse(next === killed)
  }

  // Value: protects=the first preview opened right after launch, while the spare is still booting,
  // renders once its template arrives; fails_when=makeNSView treats a page taken mid-load as loaded
  // (renders before the template) or loads the template a second time over the booting one;
  // why_new=pooled pages in makeNSView are new; seam=none; no_claim=timing.
  func testAPreviewOnAPageStillBootingRendersWhenItsTemplateArrives() async throws {
    let pool = MarkdownWebViewPool.shared
    _ = pool.take()  // starts a fresh spare, which cannot have loaded within this turn
    pool.prewarm()
    XCTAssertFalse(pool.spareIsLoaded)
    let spare = try XCTUnwrap(pool.spare)
    try await assertPreviewRenders(
      on: spare, markdown: "# Mid load\n\nARRIVED\n", needle: "ARRIVED")
  }

  // Value: protects=a preview on an already-booted page renders what it was given, in its theme;
  // fails_when=makeNSView never runs the page-loaded step for a page the pool hands over loaded, so
  // nothing renders and the loader never lifts; why_new=pooled pages in makeNSView are new;
  // seam=none; no_claim=timing.
  func testAPreviewOnABootedPageRendersAtOnce() async throws {
    let pool = MarkdownWebViewPool.shared
    pool.prewarm()
    try await waitUntilLoaded(pool)
    let spare = try XCTUnwrap(pool.spare)
    try await assertPreviewRenders(on: spare, markdown: "# Booted\n\nQUEUED\n", needle: "QUEUED")
  }

  /// Shows `markdown` in a real `MarkdownWebView` (in a window that is never ordered front) and
  /// asserts that it took `spare` as its page, painted, and carries the markdown and the theme.
  private func assertPreviewRenders(
    on spare: WKWebView, markdown: String, needle: String, line: UInt = #line
  ) async throws {
    let tokens = try XCTUnwrap(
      bundledThemes().map { ThemeTokens(preview: $0) }.first, "no bundled theme")
    let painted = expectation(description: "first render painted")
    let host = NSHostingView(
      rootView: MarkdownWebView(
        markdown: markdown, tokens: tokens, generation: 0, onFirstRender: { painted.fulfill() }))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    await fulfillment(of: [painted], timeout: 30)

    XCTAssertTrue(
      Self.contains(spare, in: host), "the preview did not take the pooled page", line: line)
    let text = try await spare.evaluateJavaScript("document.getElementById('content').textContent")
    XCTAssertTrue((text as? String)?.contains(needle) == true, "not rendered", line: line)
    let bg = try await spare.evaluateJavaScript(
      "document.documentElement.style.getPropertyValue('--bg')")
    XCTAssertFalse((bg as? String ?? "").isEmpty, "the theme was not applied", line: line)
  }

  private static func contains(_ webView: WKWebView, in view: NSView) -> Bool {
    view === webView || view.subviews.contains { contains(webView, in: $0) }
  }

  private func waitUntilLoaded(_ pool: MarkdownWebViewPool) async throws {
    for _ in 0..<200 where !pool.spareIsLoaded {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(pool.spareIsLoaded, "the spare never finished loading")
  }
}
