import XCTest

/// New Workroom asks where (#309): This Mac, then Docker and Apple Container under "Local
/// containers" and boxd under "Remote" (#356), each disabled with its reason when it can't be used
/// here.
// Value: protects=boxd is offered in New Workroom, disabled exactly when its title gives a reason;
// fails_when=WorkroomPlace.all or the sidebar's Remote section drops boxd; why_new=the places
// loops listed only Docker and Apple Container; seam=none
final class NewWorkroomPlacesUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    let project = app.otherElements["sidebar.project.UITestProject"]
    XCTAssertTrue(project.waitForExistence(timeout: 10), "fixture project row should exist")
    project.rightClick()
    return app
  }

  /// One launch, three surfaces in order, each asking where with the same places:
  /// the project's context menu, the row's "+" and File ▸ New Workroom… (⌘N, and the tab bar's +),
  /// where picking a project offers the same places rather than creating on this Mac. Nothing is
  /// picked, so nothing is created. The picker goes last: it leaves a sheet open.
  func testNewWorkroomAsksWhereFromTheMenuThePlusAndThePicker() {
    let app = launch()
    let newWorkroom = app.menuItems["New Workroom"]
    XCTAssertTrue(newWorkroom.waitForExistence(timeout: 5))
    newWorkroom.hover()

    let thisMac = app.menuItems["This Mac"]
    XCTAssertTrue(thisMac.waitForExistence(timeout: 5), "the submenu has no This Mac")
    thisMac.hover()
    XCTAssertTrue(thisMac.isEnabled)
    // Each runtime is listed, usable or saying why not; which depends on this Mac.
    for runtime in ["Docker", "Apple Container", "boxd"] {
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
    // The context menu `launch` opened, and its submenu: a "This Mac" left over from here would
    // satisfy the "+" menu's wait below.
    dismissMenus(app)

    // The row's "+" asks where too, with the same places as the context menu.
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
    for runtime in ["Docker", "Apple Container", "boxd"] {
      XCTAssertTrue(
        app.menuItems.matching(
          NSPredicate(format: "title == %@ OR title BEGINSWITH %@", runtime, "\(runtime) — ")
        ).firstMatch.waitForExistence(timeout: 5), "\(runtime) isn't listed")
    }
    let plusShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    plusShot.name = "plus-places"
    plusShot.lifetime = .keepAlways
    add(plusShot)
    // Closed before File is used, or a stale menu can cover its items.
    dismissMenus(app)

    pickProject(app)
    let pickerThisMac = app.buttons["newWorkroom.place.thisMac"]
    XCTAssertTrue(pickerThisMac.waitForExistence(timeout: 5), "the picker didn't ask where")
    XCTAssertFalse(app.textFields["newWorkroom.filter"].exists, "still listing projects")
    XCTAssertTrue(pickerThisMac.isEnabled)
    for runtime in ["container", "apple-container", "boxd"] {
      XCTAssertTrue(app.buttons["newWorkroom.place.\(runtime)"].exists, "\(runtime) isn't offered")
    }
    XCTAssertFalse(app.staticTexts["newWorkroom.placesBlocked"].exists)
    attach(app, "picker-places")

    // Back lists the projects again, and so does ←.
    app.buttons["newWorkroom.back"].click()
    XCTAssertTrue(app.textFields["newWorkroom.filter"].waitForExistence(timeout: 5))
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(pickerThisMac.waitForExistence(timeout: 5), "⏎ didn't pick the project")
    app.typeKey(.leftArrow, modifierFlags: [])
    XCTAssertTrue(
      app.textFields["newWorkroom.filter"].waitForExistence(timeout: 5), "← didn't go back")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// A create downloading its host image (#309) no longer shows on its project's row and no longer
  /// turns the places off (#483): it lists its own provisional row, which shows its pane with the
  /// image step running, while the project's New Workroom menu and the File ▸ New Workroom… picker
  /// still offer every place, since creates in one project may overlap. The picker goes last: it
  /// leaves a sheet open.
  func testADownloadingImageShowsInItsOwnRowAndPaneAndLeavesThePlacesOn() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-WorkroomUITestImagePull", "0.42",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    let row = app.descendants(matching: .any)
      .matching(identifier: "sidebar.creation.New workroom · Docker").firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the unnamed create lists no row of its own")
    XCTAssertFalse(
      app.progressIndicators.matching(identifier: "sidebar.project.UITestProject").firstMatch
        .exists,
      "the project row still shows the create")
    attach(app, "image-pull-row")

    row.click()
    let image = app.descendants(matching: .any)
      .matching(identifier: "CreationPane.step.image").firstMatch
    XCTAssertTrue(image.waitForExistence(timeout: 5), "the row doesn't show the create's pane")
    XCTAssertEqual(image.label, "Pull image, running")
    attach(app, "image-pull-pane")

    // Meanwhile the project's New Workroom offers every place it would anyway.
    app.otherElements["sidebar.project.UITestProject"].rightClick()
    app.menuItems["New Workroom"].hover()
    let thisMac = app.menuItems["This Mac"]
    XCTAssertTrue(thisMac.waitForExistence(timeout: 5))
    XCTAssertTrue(thisMac.isEnabled, "a running create turns This Mac off")
    XCTAssertFalse(app.menuItems["A workroom is already being created"].exists)
    for runtime in ["Docker", "Apple Container", "boxd"] {
      let entry = app.menuItems.matching(
        NSPredicate(format: "title == %@ OR title BEGINSWITH %@", runtime, "\(runtime) — ")
      ).firstMatch
      XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(runtime) isn't listed")
      XCTAssertEqual(
        entry.isEnabled, entry.title == runtime,
        "\(entry.title): disabled exactly when its title gives a reason, never for a create")
    }
    // Closed before File is used, or a stale menu can cover its items.
    dismissMenus(app)

    // The picker offers the places too.
    pickProject(app)
    let pickerThisMac = app.buttons["newWorkroom.place.thisMac"]
    XCTAssertTrue(pickerThisMac.waitForExistence(timeout: 5), "the picker didn't ask where")
    XCTAssertTrue(pickerThisMac.isEnabled, "a running create turns This Mac off in the picker")
    XCTAssertFalse(app.staticTexts["newWorkroom.placesBlocked"].exists)
    attach(app, "picker-places-while-creating")
    app.typeKey(.escape, modifierFlags: [])
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Closes the context menu, its submenu and the "+" menu, however many Escapes that takes, and
  /// proves they are gone: the next step's waits must not be satisfied by a leftover menu.
  private func dismissMenus(_ app: XCUIApplication) {
    let places = [app.menuItems["This Mac"], app.menuItems["New Workroom"]]
    for _ in 0..<3 where places.contains(where: \.exists) {
      app.typeKey(.escape, modifierFlags: [])
      _ = places[0].waitForNonExistence(timeout: 1)
    }
    for place in places {
      XCTAssertTrue(place.waitForNonExistence(timeout: 5), "a menu is still open")
    }
  }

  /// Opens File ▸ New Workroom… and picks the fixture project.
  private func pickProject(_ app: XCUIApplication) {
    let file = app.menuBars.menuBarItems["File"]
    file.click()
    file.menuItems["New Workroom…"].click()
    let project = app.descendants(matching: .any)
      .matching(identifier: "newWorkroom.project.UITestProject").firstMatch
    XCTAssertTrue(project.waitForExistence(timeout: 5), "the picker didn't list the project")
    project.click()
  }
}
