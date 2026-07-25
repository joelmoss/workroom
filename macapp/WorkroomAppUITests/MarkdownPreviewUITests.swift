import XCTest

/// UI tests for the rendered-Markdown preview (`MarkdownWebView` inside `PlainFileViewer`).
///
/// Two behaviours that only exist on screen, so neither is reachable from the unit gate:
///
/// 1. **The panel is never blank while the preview boots.** The web view has to spawn a WebContent
///    process and parse ~3.5 MB of bundled script (mermaid alone is 3.4 MB, ~104 ms of the ~117 ms
///    parse) before `__render` can run. That window used to show an empty rectangle; it now shows a
///    loader. `MarkdownFirstRenderTests` covers the *signal*, but only a UI test can prove the loader
///    is actually in the view hierarchy.
/// 2. **The preview renders the WHOLE file.** The seeded fixture mentions a raw `<title>` in prose
///    before its tail marker — the exact shape that made the preview silently render only the head of
///    the document. Asserting the tail in the live web view is the end-to-end version of that fix.
///
/// Run with `make app-uitest` on a real GUI login session (excluded from `make app-test`).
final class MarkdownPreviewUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// Markers seeded by `UITestFixture` into the real `NOTES.md` on disk.
  private let headMarker = "UITEST_MARKDOWN_HEAD"
  private let tailMarker = "UITEST_MARKDOWN_TAIL"
  private let markdownFile = "NOTES.md"

  /// `holdLoader` sets `-WorkroomUITestHoldPreviewLoader`, which makes `PlainFileViewer` ignore the
  /// first-render signal so the loading state stays put long enough to assert.
  private func launchedApp(holdLoader: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    // Force the inspector visible and parked on Changes. Both live in the Dev app's real UserDefaults
    // domain, so without this the test inherits whatever pane the developer (or a previous test) last
    // left behind — which silently removes the Changes rows this test opens the file from. The fixture
    // applies it (`UITestFixture.applyInspectorDefaults`) rather than the test setting the `Defaults`
    // keys directly: an argument-domain value is a *string*, which `Defaults` can't read as a `Bool`,
    // and it shadows both the persisted value and every later write — pinning the pane shut.
    app.launchArguments += ["-WorkroomUITestInspectorSection", "changes"]
    if holdLoader {
      app.launchArguments += ["-WorkroomUITestHoldPreviewLoader", "1"]
    }
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Open the seeded Markdown file in the in-app viewer, via the Changes row's "Open File" context
  /// menu item — the same keyboard-reachable route `ChangesPanelUITests` uses for the `Gemfile`.
  private func openSeededMarkdown(_ app: XCUIApplication) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // Select the Changes pane explicitly rather than trusting whatever pane the inspector happens to
    // be on. `inspector.activeSection` is persisted in the Dev app's real UserDefaults domain and
    // survives launches (`-ApplePersistenceIgnoreState` only covers window state), so any earlier
    // manual session can leave it on History or Files — which silently breaks every assertion below.
    let changesTab = element(app, id: "activitySection.changes")
    if changesTab.waitForExistence(timeout: 10), !changesTab.isSelected {
      changesTab.click()
    }

    XCTAssertTrue(
      element(app, id: "changes.workingCopy").waitForExistence(timeout: 10),
      "the Changes panel should render. App tree:\n\(app.debugDescription)")

    let row = element(app, id: "changes.file.\(markdownFile)")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the \(markdownFile) row should render")
    row.rightClick()

    let openFile = app.menuItems["Open File"]  // exact title — not "Open File in <editor>"
    XCTAssertTrue(openFile.waitForExistence(timeout: 6), "the context menu offers Open File")
    openFile.click()
  }

  /// Whether `marker` appears in the rendered preview. The preview is a `WKWebView`, so its content
  /// surfaces as web static text rather than the `textViews` value the source path uses.
  private func previewText(_ app: XCUIApplication, contains marker: String, timeout: Double = 15)
    -> Bool
  {
    // Read the elements and compare in Swift rather than with an NSPredicate. WKWebView is
    // inconsistent about where it puts rendered text — a heading surfaces as the element's `label`,
    // a paragraph as its `value` — and a predicate covering both throws
    // "Can't use in/contains operator with collection (not a collection)" the moment the scan reaches
    // an element whose value is a number instead of a string.
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for text in app.webViews.staticTexts.allElementsBoundByIndex {
        if text.label.contains(marker) { return true }
        if let value = text.value as? String, value.contains(marker) { return true }
      }
      usleep(200_000)
    } while Date() < deadline
    return false
  }

  /// Dump the preview's accessibility tree — called only when an assertion is about to fail, so a
  /// failure report says what the web view actually exposed instead of just "not found".
  private func previewTreeDump(_ app: XCUIApplication) -> String {
    let webView = app.webViews.firstMatch
    guard webView.exists else { return "no webView element in the query tree" }
    return webView.debugDescription
  }

  /// Opening a Markdown file shows the loader instead of an empty panel while the web view boots.
  func testPreviewShowsLoaderWhileWebViewBoots() throws {
    let app = launchedApp(holdLoader: true)
    openSeededMarkdown(app)

    XCTAssertTrue(
      element(app, id: "file.preview.loading").waitForExistence(timeout: 10),
      "the Markdown preview should show a loader while it boots, not a blank panel")
  }

  /// The loader is transient: without the hold flag it goes away on its own once the render paints,
  /// and it must not be left spinning over content.
  func testLoaderDisappearsOnceRendered() throws {
    let app = launchedApp()
    openSeededMarkdown(app)

    XCTAssertTrue(
      previewText(app, contains: headMarker), "the preview should render the file's content")

    let loader = element(app, id: "file.preview.loading")
    let gone = NSPredicate(format: "exists == false")
    let result = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: gone, object: loader)], timeout: 10)
    XCTAssertEqual(result, .completed, "the loader should be gone once the preview has rendered")
  }

  /// End-to-end cover for the truncation fix: the seeded file mentions a raw `<title>` in prose, and
  /// everything after it used to vanish from the preview. Both markers must render.
  func testPreviewRendersWholeFilePastRawHTMLMention() throws {
    let app = launchedApp()
    openSeededMarkdown(app)

    XCTAssertTrue(
      previewText(app, contains: headMarker), "the preview should render the head of the file")
    XCTAssertTrue(
      previewText(app, contains: tailMarker),
      """
      content after the raw <title> mention must render — this is the truncation regression.
      Preview accessibility tree:
      \(previewTreeDump(app))
      """)
  }

  /// The seeded file's raw `<title>` must reach the preview as visible text, not as markup. This is
  /// the positive half of the escaping fix — the tail surviving proves nothing was eaten, this proves
  /// the mention itself is shown rather than silently swallowed.
  func testRawTitleMentionRendersAsVisibleText() throws {
    let app = launchedApp()
    openSeededMarkdown(app)

    XCTAssertTrue(
      previewText(app, contains: "<title>"),
      "the raw <title> mention should render as literal text in the preview")
  }
}
