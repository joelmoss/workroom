import XCTest

/// A remote host's awake-ceiling prompt (#257). The app hands a remote agent whose box sleeps this
/// Mac's ask-at-ceiling setting, so it asks too, and its card has to show or the box sleeps under a
/// running job. The fixture's stand-in host (`-WorkroomUITestCeilingPrompt`) has a prompt
/// pending until it is sent `keep`; no host or agent is involved.
final class WakefulnessPromptUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// The card names the machine (a host with no workroom gets a generic name), carries the host's
  /// own "Keep awake" button, and a click answers the prompt: the card goes and does not come back
  /// on the next status reply.
  func testARemoteHostsCeilingPromptShowsAndKeepAwakeAnswersIt() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestCeilingPrompt", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

    let keep = app.buttons["wakefulness.keepAwake.25700000-0000-4000-8000-000000000257"]
    XCTAssertTrue(keep.waitForExistence(timeout: 15), "the remote host's card never showed")
    XCTAssertTrue(app.staticTexts["Keep a remote machine awake?"].exists)
    XCTAssertFalse(app.buttons["wakefulness.keepAwake"].exists, "not this Mac's card")

    keep.click()
    XCTAssertTrue(keep.waitForNonExistence(timeout: 5), "Keep awake did not answer the prompt")
    // The status poll runs every 10 s; a reply still saying "pending" would raise it again.
    XCTAssertFalse(keep.waitForExistence(timeout: 12), "the answered prompt came back")
  }
}
