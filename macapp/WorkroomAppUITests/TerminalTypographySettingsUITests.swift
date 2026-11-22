import XCTest

/// Settings ▸ Terminal's Font and Cursor sections: choosing a weight, size, cursor shape and blinking
/// reaches the generated `ghostty.conf` the terminals load, and Restore Defaults takes every line
/// back out. Run in the VM, this class only (`make app-uitest-vm`).
///
/// Asserts on the conf, not on the controls: a control showing the new value proves only a
/// `Defaults` write, while the conf is what libghostty reads.
final class TerminalTypographySettingsUITests: XCTestCase {
  /// The app's generated conf, at a path this runner hands over: see
  /// `ThemePickerUITests.generatedConfURL` for why `/tmp`, and why not a path worked out here.
  private var generatedConfURL: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    let conf = URL(fileURLWithPath: "/tmp/workroom-uitest-typography-\(UUID().uuidString).conf")
    generatedConfURL = conf
    addTeardownBlock { try? FileManager.default.removeItem(at: conf) }
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestGhosttyConfigFile", generatedConfURL.path]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func openTerminalSettings(_ app: XCUIApplication) {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "no app menu")
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings… menu item")
    settings.click()
    let pane = element(app, "settingsPane.terminal")
    XCTAssertTrue(pane.waitForExistence(timeout: 10), "the Settings sidebar has no Terminal row")
    pane.click()
    XCTAssertTrue(
      element(app, "settings.terminal.preview").waitForExistence(timeout: 5),
      "Settings ▸ Terminal shows no preview")
  }

  /// Choose `item` from the pop-up menu `identifier`.
  private func choose(_ app: XCUIApplication, _ identifier: String, _ item: String) {
    let popup = app.popUpButtons[identifier]
    XCTAssertTrue(popup.waitForExistence(timeout: 5), "no \(identifier) menu")
    popup.click()
    let menuItem = app.menuItems[item]
    XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "\(identifier) has no \(item)")
    menuItem.click()
  }

  private func confLines() -> [String] {
    guard let text = try? String(contentsOf: generatedConfURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  /// Poll the conf until `predicate` holds: the write follows the click after a short settle.
  private func waitForConf(
    timeout: TimeInterval = 5, _ predicate: ([String]) -> Bool
  ) -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let lines = confLines()
      if predicate(lines) { return lines }
      usleep(150_000)
    }
    return confLines()
  }

  private func attachWindow(_ app: XCUIApplication, named name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testFontAndCursorReachTheTerminalConfig() throws {
    let app = launchedApp()
    openTerminalSettings(app)
    // Start from the defaults, whatever an earlier run left behind.
    let restore = app.buttons["settings.control.terminalTypographyRestoreDefaults"]
    XCTAssertTrue(restore.waitForExistence(timeout: 5), "no Restore Defaults button")
    if restore.isEnabled { restore.click() }
    var lines = waitForConf { !$0.isEmpty && !$0.contains { $0.hasPrefix("font-") } }
    XCTAssertFalse(lines.contains { $0.hasPrefix("font-") || $0.hasPrefix("cursor-") })
    attachWindow(app, named: "Settings, Terminal, defaults")

    choose(app, "settings.control.terminalFontWeight", "Light")
    choose(app, "settings.control.terminalCursorShape", "Hollow Block")
    let blink = element(app, "settings.control.terminalCursorBlinks")
    XCTAssertTrue(blink.waitForExistence(timeout: 5), "no Blink toggle")
    blink.click()
    let size = app.textFields["settings.control.terminalFontSize"]
    XCTAssertTrue(size.waitForExistence(timeout: 5), "no Size field")
    // Select the whole value: a double-click selects one word, which may not be all of it.
    size.click()
    size.typeKey("a", modifierFlags: .command)
    size.typeText("15\r")

    let expected = [
      "font-family = \"JetBrains Mono\"", "font-variation = wght=300",
      "font-variation-bold = wght=400",
      "font-size = 15",
      "cursor-style = block_hollow", "shell-integration-features = no-cursor",
      "cursor-style-blink = false",
    ]
    lines = waitForConf { lines in expected.allSatisfy(lines.contains) }
    for line in expected {
      XCTAssertTrue(lines.contains(line), "the conf has no '\(line)': \(lines)")
    }
    attachWindow(app, named: "Settings, Terminal, Light 15pt, hollow block, no blink")

    // Leave the defaults for whatever runs next, and prove they write nothing.
    XCTAssertTrue(restore.isEnabled, "Restore Defaults is off with settings changed")
    restore.click()
    lines = waitForConf { !$0.isEmpty && !$0.contains { $0.hasPrefix("font-") } }
    XCTAssertFalse(
      lines.contains { $0.hasPrefix("font-") || $0.hasPrefix("cursor-") },
      "Restore Defaults left lines behind: \(lines)")
    XCTAssertFalse(restore.isEnabled, "Restore Defaults is still on at the defaults")
    app.terminate()
  }
}
