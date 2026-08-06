import AppKit
import XCTest

/// XCUITest for the status bar's cwd actions (issue #143): clicking the cwd segment drops a menu with
/// Copy to Clipboard + Reveal in Finder.
///
/// The cwd is only there once the live surface has reported one (OSC 7 via the bundled
/// shell-integration), so every lookup here waits rather than asserting on the first frame.
///
/// Two things this can't cover, both known XCUITest limits: `.onHover` isn't drivable, so the hover
/// well is verified by eye; and "Reveal in Finder" is asserted as an offered item, never clicked — the
/// click would activate Finder over the test run.
final class StatusBarCwdUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// Type-agnostic on purpose: the segment is a `Button` today and resolves under `.buttons`, but it
  /// has already been a SwiftUI `Menu` (which doesn't — see `openIn.menu` in
  /// `WorkroomPaneHeaderUITests`), and this test cares about the identifier, not the element type.
  private func cwdSegment(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "terminal.statusBar.cwd").firstMatch
  }

  /// The accessibility label is `Working directory <absolute path>` — the path the menu acts on.
  private func cwdPath(from element: XCUIElement) -> String {
    let prefix = "Working directory "
    XCTAssertTrue(element.label.hasPrefix(prefix), "unexpected cwd label: \(element.label)")
    return String(element.label.dropFirst(prefix.count))
  }

  /// Clicking the cwd opens the menu with both actions.
  func testClickingCwdOpensActionsMenu() {
    let app = launchedApp()
    let cwd = cwdSegment(app)
    XCTAssertTrue(
      cwd.waitForExistence(timeout: 20), "a terminal pane's status bar shows its working directory")

    cwd.click()
    XCTAssertTrue(
      app.menuItems["Copy to Clipboard"].waitForExistence(timeout: 5),
      "the cwd menu offers Copy to Clipboard")
    XCTAssertTrue(app.menuItems["Reveal in Finder"].exists, "the cwd menu offers Reveal in Finder")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Copy puts the FULL absolute path on the pasteboard — not the `~`-abbreviated, middle-truncated
  /// string the label draws.
  func testCopyToClipboardCopiesTheAbsolutePath() {
    let app = launchedApp()
    let cwd = cwdSegment(app)
    XCTAssertTrue(cwd.waitForExistence(timeout: 20))
    let path = cwdPath(from: cwd)
    XCTAssertTrue(path.hasPrefix("/"), "the label carries the absolute path, got \(path)")

    // Sentinel, so a stale pasteboard can't pass this by accident.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("UITEST-sentinel", forType: .string)

    cwd.click()
    let copy = app.menuItems["Copy to Clipboard"]
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    copy.click()

    var copied = NSPasteboard.general.string(forType: .string)
    // The click returns before the menu action has run through the app's main loop.
    let deadline = Date().addingTimeInterval(5)
    while copied != path, Date() < deadline {
      usleep(100_000)
      copied = NSPasteboard.general.string(forType: .string)
    }
    XCTAssertEqual(copied, path, "Copy to Clipboard writes the pane's cwd")
  }
}
