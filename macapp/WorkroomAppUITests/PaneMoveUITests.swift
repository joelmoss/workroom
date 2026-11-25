import XCTest

/// Moving a terminal anywhere in the real window (#660): a workroom terminal's tab dragged onto the
/// Open heading becomes a standalone terminal with a row of its own, whose menu has Rename…,
/// Move to…, Pop Out and Close. Driven through the fixture (`-WorkroomUITestFixture 1`), never a
/// real project. Run in the VM: `make app-uitest-vm`.
final class PaneMoveUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  func testATabDraggedOntoTheOpenHeadingBecomesAStandaloneTerminal() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()

    let chip = element(app, "terminal.tab.Terminal 1")
    XCTAssertTrue(chip.waitForExistence(timeout: 15), "the fixture workroom's terminal tab")
    let heading = element(app, "sidebar.open")
    XCTAssertTrue(heading.waitForExistence(timeout: 5), "the Open heading")
    let standalone = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.open.workroom.standalone:")
    ).firstMatch
    XCTAssertFalse(standalone.exists, "no standalone terminal yet")

    // `click(forDuration:thenDragTo:)`, the mouse drag: on macOS 27 `press` posts no mouse
    // events from an element, so nothing drags (#269).
    chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: heading.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))

    XCTAssertTrue(standalone.waitForExistence(timeout: 8), "it becomes a standalone terminal's row")

    standalone.rightClick()
    for title in ["Rename…", "Move to…", "Pop Out", "Close"] {
      XCTAssertNotNil(
        app.waitForHittableMenuItem(titled: title), "its row's menu offers \(title)")
    }
    app.typeKey(.escape, modifierFlags: [])
  }
}
