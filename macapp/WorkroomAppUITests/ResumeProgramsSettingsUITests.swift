import XCTest

/// Settings ▸ Terminal ▸ "Resume programs after a restart" (ADR 0082, #827): on by default, with
/// its label and help text, and what it is set to is what the next launch reads. The fixture pins
/// it on at each launch but the one that reads it back (`-WorkroomUITestKeepResumePrograms 1`), so
/// a run that fails part way leaves the next on. Run in the VM, this class only
/// (`make app-uitest-vm`).
final class ResumeProgramsSettingsUITests: XCTestCase {
  private static let label = "Resume programs after a restart"
  private static let help =
    "When your Mac restarts or a terminal's session ends, programs that support it, such as "
    + "Claude Code and Codex, come back where they were. Claude Code does so through a hook "
    + "Workroom adds to its settings."

  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(keep: Bool = false, appearance: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if keep { app.launchArguments += ["-WorkroomUITestKeepResumePrograms", "1"] }
    if let appearance { app.launchArguments += ["-appearance", appearance] }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// Settings via the app menu, then its Terminal pane; returns the setting's toggle.
  private func resumeToggle(_ app: XCUIApplication) -> XCUIElement {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "app menu should exist")
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings… menu item should exist")
    settings.click()
    let pane = app.descendants(matching: .any).matching(identifier: "settingsPane.terminal")
      .firstMatch
    XCTAssertTrue(pane.waitForExistence(timeout: 10), "the Terminal row should exist")
    pane.click()
    // A grouped Form draws its Toggle as a switch.
    let toggle = app.switches["settings.control.resumePrograms"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Terminal shows the resume toggle")
    toggle.scrollIntoView(in: app)
    return toggle
  }

  private func isOn(_ toggle: XCUIElement) -> Bool {
    ["1", "true"].contains("\(toggle.value ?? "")")
  }

  /// Polls until `condition` holds, for up to `timeout` seconds.
  private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
  }

  /// The Settings window as a reviewer sees it.
  private func attachWindow(_ app: XCUIApplication, named name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testTheSettingIsOnByDefaultAndTheNextLaunchReadsWhatItWasSetTo() throws {
    var app = launchedApp()
    var toggle = resumeToggle(app)
    XCTAssertTrue(isOn(toggle), "on by default")
    XCTAssertTrue(
      app.staticTexts[Self.label].exists || "\(toggle.label)" == Self.label,
      "its label: \(toggle.label)")
    let caption = app.staticTexts["settings.control.resumeProgramsCaption"]
    XCTAssertTrue(caption.exists, "its help text is under it")
    XCTAssertEqual("\(caption.value ?? caption.label)", Self.help)

    toggle.click()
    XCTAssertTrue(poll(timeout: 5) { !self.isOn(toggle) }, "the toggle turns off")
    app.terminate()

    // What it was set to is the key the app reads, not the view's own state.
    app = launchedApp(keep: true)
    toggle = resumeToggle(app)
    XCTAssertFalse(isOn(toggle), "the next launch reads it off")
    toggle.click()
    XCTAssertTrue(poll(timeout: 5) { self.isOn(toggle) }, "the toggle turns on again")
    app.terminate()

    app = launchedApp(keep: true)
    XCTAssertTrue(isOn(resumeToggle(app)), "and the next reads it on")
    app.terminate()
  }

  /// The section in each appearance, on and off, for a reviewer.
  func testTheSettingInEachAppearance() throws {
    for appearance in ["light", "dark"] {
      let app = launchedApp(appearance: appearance)
      let toggle = resumeToggle(app)
      attachWindow(app, named: "Terminal, resume on, \(appearance)")
      toggle.click()
      XCTAssertTrue(poll(timeout: 5) { !self.isOn(toggle) })
      attachWindow(app, named: "Terminal, resume off, \(appearance)")
      app.terminate()
    }
  }
}
