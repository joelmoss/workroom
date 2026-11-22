import XCTest

/// Settings ▸ AI Agents ▸ Workroom skill (#697): the toggle installs the Workroom skill for
/// Claude Code and Codex, and turning it off removes it again, in the fixture's throwaway home,
/// never the developer's. The setting is captured in each appearance for a reviewer. Run in the
/// VM, this class only (`make app-uitest-vm`).
final class AgentSkillSettingsUITests: XCTestCase {
  /// The home the app installs into: under `/tmp`, which the fixture takes, and this runner reads.
  /// `ThemePickerUITests.generatedConfURL` has why `/tmp`, and not a path worked out here.
  private var home: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    home = URL(fileURLWithPath: "/tmp/workroom-uitest-agent-skill-\(UUID().uuidString)")
    addTeardownBlock { [home] in try? FileManager.default.removeItem(at: home!) }
  }

  private func launchedApp(appearance: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestAgentSkillHome", home.path]
    if let appearance { app.launchArguments += ["-appearance", appearance] }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// Settings via the app menu, then its AI Agents pane; returns the skill's toggle.
  private func skillToggle(_ app: XCUIApplication) -> XCUIElement {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "app menu should exist")
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings… menu item should exist")
    settings.click()
    let pane = app.descendants(matching: .any).matching(identifier: "settingsPane.agent")
      .firstMatch
    XCTAssertTrue(pane.waitForExistence(timeout: 10), "the AI Agents row should exist")
    pane.click()
    // A grouped Form draws its Toggle as a switch.
    let toggle = app.switches["settings.control.agentSkill"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5), "AI Agents shows the skill's toggle")
    toggle.scrollIntoView(in: app)
    return toggle
  }

  private func isOn(_ toggle: XCUIElement) -> Bool {
    ["1", "true"].contains("\(toggle.value ?? "")")
  }

  private func skillFile(_ agent: String) -> URL {
    home.appendingPathComponent("\(agent)/skills/workroom/SKILL.md")
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

  func testTheSettingInstallsAndRemovesTheSkillInTheThrowawayHome() throws {
    let app = launchedApp()
    let toggle = skillToggle(app)
    XCTAssertFalse(isOn(toggle), "off by default")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: skillFile(".claude").path), "off writes nothing")

    toggle.click()
    XCTAssertTrue(poll(timeout: 5) { self.isOn(toggle) }, "the toggle turns on")
    for agent in [".claude", ".codex"] {
      XCTAssertTrue(
        poll(timeout: 15) { FileManager.default.fileExists(atPath: self.skillFile(agent).path) },
        "turning it on installs \(agent)'s skill in the fixture's home")
      let text = try String(contentsOf: skillFile(agent), encoding: .utf8)
      XCTAssertTrue(text.hasPrefix("---\nname: workroom\n"), text)
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: home.appendingPathComponent("\(agent)/skills/workroom/.workroom-skill").path),
        "Workroom's marker is beside it")
    }
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "settings.control.agentSkillNotice")
        .firstMatch.exists, "an install that went as asked says nothing more")

    toggle.click()
    XCTAssertTrue(poll(timeout: 5) { !self.isOn(toggle) }, "the toggle turns off")
    for agent in [".claude", ".codex"] {
      XCTAssertTrue(
        poll(timeout: 15) {
          !FileManager.default.fileExists(
            atPath: self.home.appendingPathComponent("\(agent)/skills/workroom").path)
        }, "turning it off removes \(agent)'s skill")
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: home.appendingPathComponent(agent).path),
        "the agent's own folder stays")
    }
    app.terminate()
  }

  /// The section in each appearance, on and off, for a reviewer.
  func testTheSettingInEachAppearance() throws {
    for appearance in ["light", "dark"] {
      let app = launchedApp(appearance: appearance)
      let toggle = skillToggle(app)
      attachWindow(app, named: "AI Agents, Workroom skill off, \(appearance)")
      toggle.click()
      XCTAssertTrue(
        poll(timeout: 15) { FileManager.default.fileExists(atPath: self.skillFile(".claude").path) }
      )
      attachWindow(app, named: "AI Agents, Workroom skill on, \(appearance)")
      // Leave it off for whatever runs next.
      toggle.click()
      XCTAssertTrue(
        poll(timeout: 15) {
          !FileManager.default.fileExists(atPath: self.skillFile(".claude").path)
        })
      app.terminate()
    }
  }
}
