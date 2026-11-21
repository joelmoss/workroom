import XCTest

/// Rename… in a terminal tab's menu (#654). Driven through the fixture (`-WorkroomUITestFixture 1`),
/// never a real project. Run in the VM: `make app-uitest-vm`.
final class TerminalRenameUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  func testRenameATerminalTabShowsTheNewNameAndClearingRestoresTheDefault() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()

    let chip = element(app, id: "terminal.tab.Terminal 1")
    XCTAssertTrue(chip.waitForExistence(timeout: 10), "the fixture terminal's tab")

    chip.rightClick()
    let rename = app.waitForHittableMenuItem(titled: "Rename…")
    XCTAssertNotNil(rename, "a terminal tab's menu offers Rename…")
    rename?.click()

    let field = app.sheets.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 6), "the rename sheet has a name field")
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Build box")
    app.sheets.buttons["Rename"].click()
    // The chip keeps its identifier ("Terminal 1", never shown); its label is the title it shows.
    XCTAssertTrue(
      waitForLabel(chip, containing: "Build box"), "the tab shows the name the user gave it")

    // Clearing the name (an empty one) brings the default title back: the shell and its folder.
    chip.rightClick()
    app.waitForHittableMenuItem(titled: "Rename…")?.click()
    XCTAssertTrue(field.waitForExistence(timeout: 6))
    field.typeKey("a", modifierFlags: .command)
    field.typeKey(.delete, modifierFlags: [])
    app.sheets.buttons["Rename"].click()
    XCTAssertTrue(
      waitForLabel(chip, containing: "zsh "), "an empty name clears it: \(chip.label)")
    XCTAssertFalse(chip.label.contains("Build box"))
    XCTAssertFalse(chip.label.contains("Terminal 1"), "no number is shown: \(chip.label)")
  }

  private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 8)
      == .completed
  }
}
