import XCTest

/// Program status indicators (#358), on the panes `-WorkroomUITestProgramStatus 1` seeds into the
/// fixture workroom with no daemon involved: Terminal 1 working (focused at launch), Terminal 2
/// waiting for permission ("Apply?"), Terminal 3 waiting for an answer on a host whose link is down,
/// Terminal 4 stopped on an error.
///
/// Colour and the glyphs themselves aren't assertable here; the workroom row's glyph button and the
/// chips' accessibility label/value are what VoiceOver gets, so they are what is asserted.
final class ProgramStatusUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp(terminalTabs: Int? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestProgramStatus", "1"]
    if let terminalTabs {
      app.launchArguments += ["-WorkroomUITestTerminalTabs", "\(terminalTabs)"]
    }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func chip(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "terminal.tab.\(title)").firstMatch
  }

  /// The workroom row's glyph button, by its spoken label: the row's own identifier reaches its
  /// children, so the label is the reliable handle.
  private func workroomGlyph(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "label == %@", "2 terminals need you, may be out of date")
    ).firstMatch
  }

  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// Two terminals wait in the workroom, one of them on a stale host: one glyph, counted, and the
  /// row says the count may be out of date.
  func testTheWorkroomRowCountsItsWaitingTerminals() {
    let app = launchedApp()
    XCTAssertTrue(
      workroomGlyph(app).waitForExistence(timeout: 15),
      "the workroom row shows the waiting glyph with its count and stale state")
  }

  /// The glyph button focuses the terminal that has waited longest, Terminal 2, from Terminal 1.
  func testTheGlyphButtonFocusesTheTerminalWaitingLongest() {
    let app = launchedApp()
    let waiting = chip(app, "Terminal 2")
    XCTAssertTrue(waiting.waitForExistence(timeout: 15))
    XCTAssertTrue(
      poll(timeout: 5) { chip(app, "Terminal 1").isSelected }, "the working terminal starts focused"
    )
    XCTAssertFalse(waiting.isSelected)

    XCTAssertTrue(workroomGlyph(app).waitForExistence(timeout: 10))
    workroomGlyph(app).click()

    XCTAssertTrue(
      poll(timeout: 5) { waiting.isSelected }, "the glyph focused the terminal waiting longest")
  }

  /// Each chip says what its program reports: the waiting kind, a stale link, an error, busy.
  func testChipsSayWhatTheirProgramReports() {
    let app = launchedApp()
    let permission = chip(app, "Terminal 2")
    XCTAssertTrue(permission.waitForExistence(timeout: 15))
    XCTAssertTrue(
      poll(timeout: 5) { (permission.value as? String) == "Waiting for your permission" },
      "got \(permission.value ?? "<nil>")")
    XCTAssertTrue(permission.label.hasPrefix("Terminal 2"))
    XCTAssertFalse(permission.label.contains("may be out of date"), "its host is live")

    let stale = chip(app, "Terminal 3")
    XCTAssertEqual(stale.value as? String, "Waiting for your answer")
    XCTAssertTrue(stale.label.contains("may be out of date"), "got \(stale.label)")

    XCTAssertEqual(chip(app, "Terminal 4").value as? String, "Error")
    XCTAssertEqual(chip(app, "Terminal 1").value as? String, "Busy")
  }

  /// With the strip overflowing and the waiting terminals scrolled out past its leading edge, the
  /// edge shows a button that brings the one waiting into view and focuses it.
  func testAWaitingTabScrolledOutOfTheStripIsOneClickAway() {
    let app = launchedApp(terminalTabs: 16)
    XCTAssertTrue(chip(app, "Terminal 2").waitForExistence(timeout: 15))
    // A new tab at the end scrolls the strip there, past the waiting ones at the start.
    let add = app.descendants(matching: .any).matching(identifier: "NewTerminal").firstMatch
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    add.click()

    let edge = app.descendants(matching: .any)
      .matching(identifier: "terminal.tab.waitingEdge.leading").firstMatch
    XCTAssertTrue(
      edge.waitForExistence(timeout: 10), "no edge button for the waiting tabs scrolled out")
    edge.click()
    let waiting = [chip(app, "Terminal 2"), chip(app, "Terminal 3")]
    XCTAssertTrue(
      poll(timeout: 5) { waiting.contains { $0.isSelected } },
      "the edge button did not focus a waiting terminal")
  }
}
