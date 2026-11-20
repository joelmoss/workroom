import XCTest

/// Settings ▸ Appearance's Glass slider (#725): one slider, 70–100%, where 100% reads "Off" and is
/// Glass off. Its value persists across a relaunch, and Glass at 85% is captured in each appearance
/// for a reviewer. Run in the VM, this class only (`make app-uitest-vm`).
final class GlassSettingsUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// - Parameter appearance: a forced `AppearanceMode` raw value ("light", "dark"), or nil for
  ///   whatever the preference holds. A launch argument only shadows the preference, so it never
  ///   changes what a later launch sees.
  private func launchedApp(appearance: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if let appearance { app.launchArguments += ["-appearance", appearance] }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// Settings via the app menu, then its Appearance pane; returns the Glass slider.
  private func glassSlider(_ app: XCUIApplication) -> XCUIElement {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "app menu should exist")
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings… menu item should exist")
    settings.click()
    let appearance = app.descendants(matching: .any)
      .matching(identifier: "settingsPane.appearance").firstMatch
    XCTAssertTrue(appearance.waitForExistence(timeout: 10), "the Appearance row should exist")
    appearance.click()
    let slider = app.sliders["settings.control.glass"]
    XCTAssertTrue(slider.waitForExistence(timeout: 5), "Appearance shows the Glass slider")
    XCTAssertFalse(
      app.switches["settings.control.glass"].exists, "the slider replaces the Glass toggle")
    return slider
  }

  /// The slider's value as a whole percentage. XCUITest reports a slider's raw value ("0.85"),
  /// not the accessibility value VoiceOver reads.
  private func percent(_ slider: XCUIElement) -> Int? {
    Double("\(slider.value ?? "")").map { Int(($0 * 100).rounded()) }
  }

  /// The readout beside the slider, as shown: "85%", or "Off" at 100%.
  private func readout(_ app: XCUIApplication) -> String {
    let text = app.staticTexts["settings.control.glassReadout"]
    XCTAssertTrue(text.waitForExistence(timeout: 5), "the slider shows its readout")
    let value = "\(text.value ?? "")"
    return value.isEmpty ? text.label : value
  }

  /// Drag the slider to `target` percent, nudging a 5% stop at a time with the arrow keys for any
  /// last step a normalized position misses.
  private func setGlass(_ slider: XCUIElement, to target: Int) {
    slider.adjust(toNormalizedSliderPosition: (Double(target) - 70) / 30)
    for _ in 0..<10 {
      guard let now = percent(slider), now != target else { break }
      slider.typeKey(now < target ? .rightArrow : .leftArrow, modifierFlags: [])
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertEqual(percent(slider), target, "the slider reaches \(target)%")
  }

  /// The window in front (Settings, while it is open) as a reviewer sees it.
  private func attachWindow(_ app: XCUIApplication, named name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// The frosted main window over the guest's desktop, Settings closed, for a reviewer.
  private func recordScreenshot(_ app: XCUIApplication, named name: String) {
    app.typeKey("w", modifierFlags: .command)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testTheGlassSliderPersistsAcrossARelaunch() throws {
    var app = launchedApp()
    var slider = glassSlider(app)
    // 100% is off, and says so.
    setGlass(slider, to: 100)
    XCTAssertEqual(readout(app), "Off", "100% reads Off")
    attachWindow(app, named: "Settings, Appearance, Glass off")
    // Not the default, so the relaunch proves the value was stored.
    setGlass(slider, to: 85)
    XCTAssertEqual(readout(app), "85%")
    attachWindow(app, named: "Settings, Appearance, Glass at 85%")
    recordScreenshot(app, named: "Glass at 85%")
    app.terminate()

    app = launchedApp()
    slider = glassSlider(app)
    XCTAssertEqual(percent(slider), 85, "Glass is still 85% after a relaunch")
    // Leave it off for whatever runs next.
    setGlass(slider, to: 100)
    XCTAssertEqual(readout(app), "Off")
    app.terminate()
  }

  /// What Glass at 85% looks like in each appearance, for a reviewer.
  func testGlassInEachAppearance() throws {
    var app = launchedApp()
    setGlass(glassSlider(app), to: 85)
    app.terminate()
    for appearance in ["light", "dark"] {
      app = launchedApp(appearance: appearance)
      XCTAssertEqual(percent(glassSlider(app)), 85)
      recordScreenshot(app, named: "Glass at 85%, \(appearance)")
      app.terminate()
    }

    // Leave Glass off for whatever runs next.
    app = launchedApp()
    setGlass(glassSlider(app), to: 100)
    app.terminate()
  }
}
