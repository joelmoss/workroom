import XCTest

/// New Workroom asks where once the remote preview is on (#309): This Mac, then Docker and Apple
/// Container under "Local containers", each disabled with its reason when it can't be used here.
/// Without the preview it stays one plain item.
final class NewWorkroomPlacesUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launch(preview: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestRemotePreview", preview ? "1" : "0",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    let project = app.otherElements["sidebar.project.UITestProject"]
    XCTAssertTrue(project.waitForExistence(timeout: 10), "fixture project row should exist")
    project.rightClick()
    return app
  }

  func testNewWorkroomAsksWhereWithThePreviewOn() {
    let app = launch(preview: true)
    let newWorkroom = app.menuItems["New Workroom"]
    XCTAssertTrue(newWorkroom.waitForExistence(timeout: 5))
    newWorkroom.hover()

    let thisMac = app.menuItems["This Mac"]
    XCTAssertTrue(thisMac.waitForExistence(timeout: 5), "the submenu has no This Mac")
    thisMac.hover()
    XCTAssertTrue(thisMac.isEnabled)
    // Each runtime is listed, usable or saying why not; which depends on this Mac.
    for runtime in ["Docker", "Apple Container"] {
      let entry = app.menuItems.matching(
        NSPredicate(format: "title == %@ OR title BEGINSWITH %@", runtime, "\(runtime) — ")
      ).firstMatch
      XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(runtime) isn't listed")
      let title = entry.title
      XCTAssertEqual(
        entry.isEnabled, title == runtime,
        "\(title): an entry is disabled exactly when its title gives a reason")
    }
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "new-workroom-places"
    shot.lifetime = .keepAlways
    add(shot)
    app.typeKey(.escape, modifierFlags: [])
  }

  /// A create downloading its host image shows how far it has got in place of the row's spinner.
  func testADownloadingImageShowsItsProgressOnTheRow() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestRemotePreview", "1",
      "-WorkroomUITestImagePull", "0.42", "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    // The row's own identifier is the indicator's too.
    let progress = app.progressIndicators.matching(identifier: "sidebar.project.UITestProject")
      .firstMatch
    XCTAssertTrue(progress.waitForExistence(timeout: 10), "the row shows no download progress")
    XCTAssertEqual(progress.value as? Double, 0.42)
    progress.hover()
    sleep(2)  // for the tooltip
    attach(app, "image-pull-progress")
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testNewWorkroomIsOneItemWithThePreviewOff() {
    let app = launch(preview: false)
    XCTAssertTrue(app.menuItems["New Workroom"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.menuItems["This Mac"].exists, "a submenu appeared without the preview")
    XCTAssertFalse(app.menuItems["New Remote Workroom"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }
}
