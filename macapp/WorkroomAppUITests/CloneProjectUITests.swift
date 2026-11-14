import XCTest

/// New Project ▸ "Clone a repository…" (issue #620), in fixture mode: `AppStore.cloneProject`
/// simulates the clone (progress lines, then success; a failure for a URL naming
/// "fixture-clone-fails"; no end until cancelled for one naming "fixture-clone-hangs") and never
/// runs the real CLI or touches the disk.
final class CloneProjectUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(extraArgs: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extraArgs
    app.launch()
    addTeardownBlock { app.terminate() }
    return app
  }

  /// Opens File ▸ New Project… and switches it to clone mode, typing `url`.
  private func openCloneSheet(_ app: XCUIApplication, url: String) -> XCUIElement {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["New Project…"].click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the New Project sheet should open")
    sheet.radioButtons["Clone a repository…"].click()
    let urlField = sheet.textFields["addProject.urlField"]
    XCTAssertTrue(urlField.waitForExistence(timeout: 4))
    // Typed with no click first: choosing clone mode puts the cursor in the URL field.
    let focused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: urlField)
    XCTAssertEqual(
      XCTWaiter().wait(for: [focused], timeout: 4), .completed,
      "choosing clone mode should focus Repository URL")
    urlField.typeText(url)
    XCTAssertEqual(urlField.value as? String, url)
    return sheet
  }

  /// The URL fills "Clone into" with its repo name; Clone Project shows git's progress in the sheet,
  /// then closes it on success.
  func testCloneShowsProgressThenClosesTheSheet() {
    let app = launchedApp()
    let sheet = openCloneSheet(app, url: "git@github.com:acme/fixture-api.git")

    let pathField = sheet.textFields["addProject.pathField"]
    XCTAssertTrue(
      (pathField.value as? String)?.hasSuffix("/fixture-api") ?? false,
      "Clone into should follow the URL, got \(String(describing: pathField.value))")

    let clone = sheet.buttons["Clone Project"]
    XCTAssertTrue(clone.isEnabled, "a URL and a new folder should enable Clone Project")
    clone.click()

    XCTAssertTrue(
      sheet.staticTexts["addProject.cloneProgress"].waitForExistence(timeout: 4),
      "the sheet should show the clone's progress")
    XCTAssertFalse(pathField.isEnabled, "the fields lock while cloning")

    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: sheet)
    XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "sheet should close")
    XCTAssertTrue(
      app.staticTexts["fixture-api"].waitForExistence(timeout: 5),
      "the clone should be added and shown as a project")
  }

  /// A failed clone keeps the sheet open with git's error inline, and unlocks the fields to retry.
  func testCloneFailureShowsTheErrorInlineAndUnlocks() {
    let app = launchedApp()
    let sheet = openCloneSheet(app, url: "git@github.com:acme/fixture-clone-fails.git")
    sheet.buttons["Clone Project"].click()

    let error = sheet.staticTexts["addProject.cloneError"]
    XCTAssertTrue(error.waitForExistence(timeout: 10), "the error should show in the sheet")
    XCTAssertTrue(
      (error.value as? String ?? error.label).contains("Permission denied"),
      "the error should be git's own")
    XCTAssertTrue(
      sheet.textFields["addProject.urlField"].isEnabled, "fields unlock after a failure")
    XCTAssertTrue(sheet.buttons["Clone Project"].isEnabled, "Clone Project can be retried")
  }

  /// Cancel during a clone cancels the clone, not the sheet.
  func testCancelDuringACloneKeepsTheSheet() {
    let app = launchedApp()
    // A clone that runs until it is cancelled, so the click can't race its finishing.
    let sheet = openCloneSheet(app, url: "git@github.com:acme/fixture-clone-hangs.git")
    sheet.buttons["Clone Project"].click()
    XCTAssertTrue(sheet.staticTexts["addProject.cloneProgress"].waitForExistence(timeout: 4))

    sheet.buttons["addProject.cancelButton"].click()

    let error = sheet.staticTexts["addProject.cloneError"]
    XCTAssertTrue(error.waitForExistence(timeout: 10), "the sheet should say it was cancelled")
    XCTAssertEqual(error.value as? String ?? error.label, "Clone cancelled.")
    XCTAssertTrue(sheet.exists, "Cancel during a clone keeps the sheet open")
  }

  /// The onboarding wizard's Add Project step offers the same clone mode.
  func testOnboardingClonesAndAdvancesToDone() {
    let app = launchedApp(extraArgs: [
      "-WorkroomUITestNoProjects", "1", "-WorkroomUITestOnboarding", "show",
    ])
    let window = app.windows["onboarding.window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    window.buttons["Next"].click()  // welcome -> tour
    window.buttons["Next"].click()  // tour -> addProject

    window.radioButtons["Clone a repository…"].click()
    let urlField = window.textFields["addProject.urlField"]
    XCTAssertTrue(urlField.waitForExistence(timeout: 4))
    urlField.click()
    urlField.typeText("https://github.com/acme/fixture-web")
    window.buttons["Clone Project"].click()

    XCTAssertTrue(
      window.buttons["Get Started"].waitForExistence(timeout: 10), "should advance to Done")
  }
}
