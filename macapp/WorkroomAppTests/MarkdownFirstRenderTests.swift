import AppKit
import Foundation
import WebKit
import XCTest

@testable import Workroom

/// Tests for `MarkdownWebView.Coordinator`'s first-render signal — the thing `PlainFileViewer` waits
/// on before it drops the preview loader.
///
/// It has to be exact in both directions. Fire too early (or never) and the user sees the blank panel
/// this was built to hide; fire again on later renders and a loader flashes over content that is
/// already on screen every time the file changes or the theme re-renders. Both are invisible to a
/// pure-logic test, so these drive a real `WKWebView` against the real bundled template.
@MainActor
final class MarkdownFirstRenderTests: XCTestCase {

  private var webView: WKWebView!
  private var coordinator: MarkdownWebView.Coordinator!

  override func setUp() async throws {
    try await super.setUp()
    let assetDirectory = try XCTUnwrap(
      Bundle.main.url(forResource: "markdown", withExtension: nil),
      "bundled markdown assets missing from the app bundle")

    // Wire the coordinator the way `makeNSView` does, so the test exercises the production path
    // (pending markdown queued pre-load, flushed on `didFinish`) rather than a rehearsal of it.
    coordinator = MarkdownWebView.Coordinator()
    webView = WKWebView(frame: .zero)
    webView.navigationDelegate = coordinator
    coordinator.webView = webView
    coordinator.templateURL = assetDirectory.appendingPathComponent("template.html")
    coordinator.assetDirectory = assetDirectory
  }

  override func tearDown() async throws {
    webView?.navigationDelegate = nil
    webView = nil
    coordinator = nil
    try await super.tearDown()
  }

  /// Start the page load and return an expectation that is fulfilled by `onFirstRender`.
  private func loadAndCountRenders() -> XCTestExpectation {
    let fired = expectation(description: "onFirstRender called")
    fired.assertForOverFulfill = false  // over-fulfilment is asserted explicitly where it matters
    coordinator.onFirstRender = { fired.fulfill() }
    let template = coordinator.templateURL!
    webView.loadFileURL(template, allowingReadAccessTo: coordinator.assetDirectory!)
    return fired
  }

  /// Poll the rendered text until it contains `needle`, so a render assertion doesn't depend on a
  /// guessed sleep. Reads with `evaluateJavaScript` on a plain expression — `callAsyncJavaScript`'s
  /// return value does not bridge back as a `String` here.
  private func waitForRenderedText(
    containing needle: String, attempts: Int = 60
  ) async throws -> Bool {
    for _ in 0..<attempts {
      let text = try await webView.evaluateJavaScript(
        "document.getElementById('content').textContent")
      if let text = text as? String, text.contains(needle) { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  func testFirstRenderFiresOncePagePaints() async throws {
    let fired = loadAndCountRenders()
    coordinator.pendingMarkdown = "# Hello\n\nBody text.\n"
    await fulfillment(of: [fired], timeout: 30)

    // Fired *after* the content is really in the page, not merely after the load finished.
    let text = try await webView.evaluateJavaScript(
      "document.getElementById('content').textContent")
    let rendered = try XCTUnwrap(text as? String)
    XCTAssertTrue(
      rendered.contains("Body text."), "signalled before the render landed: \(rendered)")
  }

  func testFirstRenderDoesNotFireAgainOnSubsequentRenders() async throws {
    let fired = loadAndCountRenders()
    coordinator.pendingMarkdown = "# One\n"
    await fulfillment(of: [fired], timeout: 30)

    // Any further call would be a loader flashing over already-visible content.
    var extraCalls = 0
    coordinator.onFirstRender = { extraCalls += 1 }
    coordinator.render("# Two\n\nEdited.\n")
    coordinator.render("# Three\n\nEdited again.\n")

    // Poll for the last render to land rather than sleeping a guessed interval.
    let landed = try await waitForRenderedText(containing: "Edited again.")
    XCTAssertTrue(landed, "the follow-up renders never reached the page")
    XCTAssertEqual(extraCalls, 0, "onFirstRender must fire only for the initial boot render")
  }

  /// A file whose Markdown is empty still has to release the loader — otherwise an empty `.md` spins
  /// forever.
  func testFirstRenderFiresForEmptyMarkdown() async throws {
    let fired = loadAndCountRenders()
    coordinator.pendingMarkdown = ""
    await fulfillment(of: [fired], timeout: 30)
  }
}
