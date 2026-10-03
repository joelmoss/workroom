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
    attach(app, "image-pull-progress")

    // Meanwhile the project's New Workroom says once why its entries are off, and each is off.
    app.otherElements["sidebar.project.UITestProject"].rightClick()
    app.menuItems["New Workroom"].hover()
    XCTAssertTrue(
      app.menuItems["A workroom is already being created"].waitForExistence(timeout: 5),
      "the submenu doesn't say why its entries are off")
    let thisMac = app.menuItems["This Mac"]
    XCTAssertTrue(thisMac.waitForExistence(timeout: 5))
    XCTAssertFalse(thisMac.isEnabled)
    for runtime in ["Docker", "Apple Container"] {
      let entry = app.menuItems.matching(
        NSPredicate(format: "title == %@ OR title BEGINSWITH %@", runtime, "\(runtime) — ")
      ).firstMatch
      XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(runtime) isn't listed")
      XCTAssertFalse(entry.isEnabled, entry.title)
      XCTAssertFalse(
        entry.title.contains("already being created"), "the reason is repeated: \(entry.title)")
    }
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "new-workroom-busy"
    shot.lifetime = .keepAlways
    add(shot)
    app.typeKey(.escape, modifierFlags: [])
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// The row's "+" asks where too, with the same places as the context menu.
  func testTheRowsPlusAsksWhereWithThePreviewOn() {
    let app = launch(preview: true)
    app.typeKey(.escape, modifierFlags: [])  // the context menu `launch` opened
    let plus = app.menuButtons.matching(
      NSPredicate(format: "title BEGINSWITH %@", "New workroom in UITestProject, on this Mac")
    ).firstMatch
    XCTAssertTrue(plus.waitForExistence(timeout: 5), "the row has no places +")
    plus.hover()
    let idle = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    idle.name = "plus-places-idle"
    idle.lifetime = .keepAlways
    add(idle)
    plus.click()
    XCTAssertTrue(app.menuItems["This Mac"].waitForExistence(timeout: 5), "+ didn't ask where")
    for runtime in ["Docker", "Apple Container"] {
      XCTAssertTrue(
        app.menuItems.matching(
          NSPredicate(format: "title == %@ OR title BEGINSWITH %@", runtime, "\(runtime) — ")
        ).firstMatch.exists, "\(runtime) isn't listed")
    }
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "plus-places"
    shot.lifetime = .keepAlways
    add(shot)
    app.typeKey(.escape, modifierFlags: [])
  }

  func testNewWorkroomIsOneItemWithThePreviewOff() {
    let app = launch(preview: false)
    defer {
      // The row's "+" as it looks without the preview, to compare with the places one.
      app.typeKey(.escape, modifierFlags: [])
      app.otherElements["sidebar.project.UITestProject"].hover()
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      shot.name = "plus-plain"
      shot.lifetime = .keepAlways
      add(shot)
    }
    XCTAssertTrue(app.menuItems["New Workroom"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.menuItems["This Mac"].exists, "a submenu appeared without the preview")
    XCTAssertFalse(app.menuItems["New Remote Workroom"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }
}
