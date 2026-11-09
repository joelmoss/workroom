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

  // MARK: Configure (#575)

  /// Launches the fixture with its host option reads held `delay` seconds and, with `fail`,
  /// failing; then, with `openPicker`, opens File ▸ New Workroom… on the fixture project's places.
  private func launchForConfigure(fail: Bool, delay: Double, openPicker: Bool = true)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES",
      "-WorkroomUITestHostOptions", fail ? "fail" : "ok",
      "-WorkroomUITestHostOptionsDelay", String(delay),
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    XCTAssertTrue(
      app.otherElements["sidebar.project.UITestProject"].waitForExistence(timeout: 10),
      "fixture project row should exist")
    guard openPicker else { return app }
    pickProject(app)
    XCTAssertTrue(app.buttons["newWorkroom.place.thisMac"].waitForExistence(timeout: 5))
    return app
  }

  /// Value: protects=⏎ on the Configure step's settings presses Create Workroom: the dialog closes
  /// and the boxd create starts, listing its own row; fails_when=⏎ does nothing there (the
  /// dialog's own ⏎ handler steps aside on this step, so only the default-action shortcut can
  /// answer it), or reaches a field instead; why_new=review finding (⏎ untested);
  /// seam=-WorkroomUITestHostOptions ok; no_claim=the create's later steps, which go on with the
  /// live remote create path and fail on the fixture project
  func testReturnOnTheConfigureSettingsCreatesTheWorkroom() {
    let app = launchForConfigure(fail: false, delay: 0.5)
    let configure = app.buttons["newWorkroom.options.boxd"]
    XCTAssertTrue(configure.waitForExistence(timeout: 5), "boxd has no Configure button")
    configure.click()
    let create = app.buttons["hostOptions.create"]
    XCTAssertTrue(
      app.switches["hostOptions.remember"].waitForExistence(timeout: 10), "no settings showed")
    XCTAssertTrue(create.isEnabled)
    attach(app, "configure-before-return")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(create.waitForNonExistence(timeout: 5), "⏎ didn't press Create Workroom")
    XCTAssertFalse(app.buttons["newWorkroom.back"].exists, "the dialog stayed open")
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.creation.")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "⏎ closed the dialog but started no create")
    attach(app, "configure-after-return")
  }

  /// Value: protects=the sidebar's boxd ▸ Configure… opens the New Workroom dialog straight on
  /// boxd's Configure step for that project, with no project list on the way, and Back from it
  /// lists the project's places; fails_when=the menu item opens a sheet or nothing, the dialog
  /// opens on the projects, or Back leaves the dialog; why_new=review finding (sidebar route
  /// untested); seam=-WorkroomUITestHostOptions ok, -WorkroomUITestHostOptionsDelay;
  /// no_claim=the exe.dev item, which shares the code path
  func testTheSidebarsConfigureOpensTheDialogOnTheConfigureStep() {
    let app = launchForConfigure(fail: false, delay: 1.5, openPicker: false)
    app.otherElements["sidebar.project.UITestProject"].rightClick()
    let newWorkroom = app.menuItems["New Workroom"]
    XCTAssertTrue(newWorkroom.waitForExistence(timeout: 5))
    newWorkroom.hover()
    let boxd = app.menuItems["boxd"]
    XCTAssertTrue(boxd.waitForExistence(timeout: 5), "the menu has no boxd submenu")
    boxd.hover()
    // boxd's own: exe.dev's submenu has a Configure… too.
    let configure = boxd.menuItems["Configure…"]
    XCTAssertTrue(configure.waitForExistence(timeout: 5), "boxd's submenu has no Configure…")
    configure.click()

    let loading = app.descendants(matching: .any)
      .matching(identifier: "hostOptions.loading").firstMatch
    XCTAssertTrue(loading.waitForExistence(timeout: 2), "Configure… opened no loading step")
    XCTAssertTrue(
      app.staticTexts["New boxd Workroom in UITestProject"].exists, "wrong step title")
    XCTAssertFalse(app.textFields["newWorkroom.filter"].exists, "the dialog opened on projects")
    XCTAssertFalse(app.sheets.firstMatch.exists, "Configure… opened a sheet")
    attach(app, "sidebar-configure-loading")
    XCTAssertTrue(
      app.switches["hostOptions.remember"].waitForExistence(timeout: 10), "no settings showed")

    app.buttons["newWorkroom.back"].click()
    XCTAssertTrue(
      app.buttons["newWorkroom.place.thisMac"].waitForExistence(timeout: 5),
      "Back didn't list the project's places")
    XCTAssertTrue(app.staticTexts["New Workroom in UITestProject"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Value: protects=Configure opens a step in the dialog that shows loading while the provider is
  /// read, then the provider's error in place, and Back from it returns to the places with that
  /// place highlighted, then to the projects; fails_when=the step opens a sheet, skips loading,
  /// shows settings after a failed read, or Back leaves the dialog; why_new=owner request;
  /// seam=-WorkroomUITestHostOptions fail, -WorkroomUITestHostOptionsDelay; no_claim=the
  /// crossfade's look, the providers' own reads
  func testConfigureShowsLoadingThenTheErrorAndBackReturnsToThePlaces() {
    let app = launchForConfigure(fail: true, delay: 2)
    let configure = app.buttons["newWorkroom.options.exedev"]
    XCTAssertTrue(configure.waitForExistence(timeout: 5), "exe.dev has no Configure button")
    configure.click()

    let loading = app.descendants(matching: .any)
      .matching(identifier: "hostOptions.loading").firstMatch
    XCTAssertTrue(loading.waitForExistence(timeout: 2), "Configure showed no loading state")
    XCTAssertTrue(
      app.staticTexts["New exe.dev Workroom in UITestProject"].exists, "wrong step title")
    XCTAssertFalse(app.buttons["newWorkroom.place.thisMac"].exists, "the places still show")
    XCTAssertFalse(app.sheets.firstMatch.exists, "Configure opened a sheet")
    attach(app, "configure-loading")

    let message = app.staticTexts["error.message"]
    XCTAssertTrue(message.waitForExistence(timeout: 10), "the failed read showed no error")
    XCTAssertEqual(message.value as? String, "The fixture's provider couldn't be reached.")
    XCTAssertEqual(
      app.staticTexts["error.title"].value as? String, "Couldn't load exe.dev host options")
    XCTAssertFalse(loading.exists, "loading stayed up with the error")
    XCTAssertFalse(app.buttons["hostOptions.create"].exists, "Create shows with the error")
    XCTAssertFalse(app.sheets.firstMatch.exists, "the error opened a sheet")
    attach(app, "configure-error")

    // Back: the places, exe.dev highlighted, then the projects.
    app.buttons["newWorkroom.back"].click()
    XCTAssertTrue(
      app.buttons["newWorkroom.place.thisMac"].waitForExistence(timeout: 5),
      "Back didn't return to the places")
    XCTAssertFalse(message.exists, "the error outlived Back")
    attach(app, "configure-back-to-places")
    app.buttons["newWorkroom.back"].click()
    XCTAssertTrue(
      app.textFields["newWorkroom.filter"].waitForExistence(timeout: 5),
      "Back didn't return to the projects")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Value: protects=a good read moves from loading to the settings with Create Workroom, and Back
  /// from them returns to the places, where ⌘⏎ opens the step again, straight on the settings
  /// since the read is fresh; fails_when=the settings never show, Back leaves the dialog, or a
  /// fresh read shows loading again; why_new=owner request; seam=-WorkroomUITestHostOptions ok,
  /// -WorkroomUITestHostOptionsDelay; no_claim=what the fields offer (HostOptionChoicesTests)
  func testConfigureShowsTheSettingsAfterLoadingAndBackReturnsToThePlaces() {
    let app = launchForConfigure(fail: false, delay: 1.5)
    let configure = app.buttons["newWorkroom.options.boxd"]
    XCTAssertTrue(configure.waitForExistence(timeout: 5), "boxd has no Configure button")
    configure.click()

    let loading = app.descendants(matching: .any)
      .matching(identifier: "hostOptions.loading").firstMatch
    XCTAssertTrue(loading.waitForExistence(timeout: 2), "Configure showed no loading state")
    let create = app.buttons["hostOptions.create"]
    // A grouped Form draws its Toggle as a switch.
    let remember = app.switches["hostOptions.remember"]
    XCTAssertTrue(remember.waitForExistence(timeout: 10), "the good read showed no settings")
    XCTAssertTrue(
      create.exists && create.isEnabled, "Create Workroom isn't offered with the settings")
    XCTAssertFalse(loading.exists, "loading stayed up with the settings")
    XCTAssertFalse(app.staticTexts["error.message"].exists, "a good read showed an error")
    attach(app, "configure-settings")

    app.buttons["newWorkroom.back"].click()
    XCTAssertTrue(
      app.buttons["newWorkroom.place.thisMac"].waitForExistence(timeout: 5),
      "Back didn't return to the places")
    // Back highlights boxd, so ⌘⏎ opens its step again: the read is fresh, so no loading.
    app.typeKey(.return, modifierFlags: .command)
    XCTAssertTrue(
      remember.waitForExistence(timeout: 5), "⌘⏎ on the highlighted boxd didn't open its settings")
    XCTAssertFalse(loading.exists, "a fresh read showed loading again")
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
