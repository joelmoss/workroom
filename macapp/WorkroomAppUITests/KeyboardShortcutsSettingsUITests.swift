import XCTest

/// Settings ▸ Keyboard Shortcuts (#148): reaching it from the menu, recording, Reset, Remove, the
/// conflict alert, search, and a shortcut without ⌘ working with a terminal focused.
///
/// Every test restores the defaults first: the XCUITest preferences suite keeps its values between
/// launches (`UserDefaults.app`).
final class KeyboardShortcutsSettingsUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func recorder(_ app: XCUIApplication, _ action: String) -> XCUIElement {
    element(app, "settings.shortcuts.record.\(action)")
  }

  private func row(_ app: XCUIApplication, _ action: String) -> XCUIElement {
    element(app, "settings.shortcuts.row.\(action)")
  }

  @discardableResult
  private func wait(_ el: XCUIElement, exists: Bool = true, _ timeout: TimeInterval = 6) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: exists))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// A recorder's visible text: the shortcut, "None", or "Type Shortcut…".
  private func keys(_ el: XCUIElement) -> String {
    (el.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? el.title
  }

  private func waitForKeys(_ el: XCUIElement, _ want: String, _ timeout: TimeInterval = 6) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if keys(el) == want || el.label.hasSuffix(" \(want)") { return true }
      if want == "Type Shortcut…", el.label.hasPrefix("Recording shortcut") { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }

  /// Help ▸ Keyboard Shortcuts… opens the pane, with every shortcut back at its default.
  private func openPane(_ app: XCUIApplication) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let help = app.menuBars.menuBarItems["Help"]
    XCTAssertTrue(help.waitForExistence(timeout: 10))
    help.click()
    help.menuItems["Keyboard Shortcuts…"].click()
    XCTAssertTrue(wait(row(app, "showHideWorkroom"), 10), "the pane opens on its rows")
    let restore = element(app, "settings.shortcuts.restoreDefaults")
    if restore.waitForExistence(timeout: 2), restore.isEnabled {
      restore.click()
      let confirm = element(app, "settings.shortcuts.restoreDefaults.confirm")
      XCTAssertTrue(wait(confirm))
      confirm.click()
    }
    XCTAssertTrue(waitForKeys(recorder(app, "run"), "⌘R"), "Run is back at its default")
  }

  func testThePaneListsEveryGroupWithTheGlobalShortcutsFirst() {
    let app = launchedApp()
    openPane(app)
    XCTAssertTrue(waitForKeys(recorder(app, "showHideWorkroom"), "⌘§"))
    XCTAssertTrue(waitForKeys(recorder(app, "quickTerminal"), "⌥§"))
    XCTAssertTrue(waitForKeys(recorder(app, "focusTerminalTab1"), "⌘1"))
    XCTAssertTrue(waitForKeys(recorder(app, "focusPaneLeft"), "⌃⌘←"))
    XCTAssertTrue(waitForKeys(recorder(app, "newProject"), "None"), "no default reads None")
    XCTAssertEqual(
      recorder(app, "newProject").frame.size, recorder(app, "newWorkroom").frame.size,
      "an unset shortcut's field is the same size as one showing keys")
    // The global rows come before the first in-app group.
    XCTAssertLessThan(row(app, "quickTerminal").frame.minY, row(app, "newProject").frame.minY)
  }

  func testRecordResetAndRemove() {
    let app = launchedApp()
    openPane(app)
    let run = recorder(app, "run")
    run.click()
    XCTAssertTrue(waitForKeys(run, "Type Shortcut…"))
    app.typeKey("j", modifierFlags: [.option, .command])
    XCTAssertTrue(waitForKeys(run, "⌥⌘J"), "the new keys are Run's")

    let reset = element(app, "settings.shortcuts.reset.run")
    XCTAssertTrue(wait(reset), "a changed shortcut offers Reset")
    reset.click()
    XCTAssertTrue(waitForKeys(run, "⌘R"), "Reset goes back to the default")
    XCTAssertTrue(wait(reset, exists: false), "and Reset goes away")

    element(app, "settings.shortcuts.remove.run").click()
    XCTAssertTrue(waitForKeys(run, "None"), "Remove leaves no shortcut")
    XCTAssertTrue(wait(reset), "an unset default can be reset")
  }

  func testARefusedPressSaysWhyAndEscapeCancels() {
    let app = launchedApp()
    openPane(app)
    let run = recorder(app, "run")
    run.click()
    app.typeKey("c", modifierFlags: .command)
    let problem = element(app, "settings.shortcuts.problem.run")
    XCTAssertTrue(wait(problem), "⌘C is refused with a reason")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitForKeys(run, "⌘R"), "Escape keeps the shortcut")
  }

  func testTakenKeysAskFirst() {
    let app = launchedApp()
    openPane(app)
    let fetch = recorder(app, "fetch")

    fetch.click()
    app.typeKey("t", modifierFlags: .command)
    let cancel = element(app, "settings.shortcuts.conflict.cancel")
    XCTAssertTrue(wait(cancel), "⌘T is New Terminal's, so it asks")
    cancel.click()
    XCTAssertTrue(waitForKeys(fetch, "⌥⇧⌘F"), "Cancel changes nothing")
    XCTAssertTrue(waitForKeys(recorder(app, "newTerminal"), "⌘T"))

    fetch.click()
    app.typeKey("t", modifierFlags: .command)
    let use = element(app, "settings.shortcuts.conflict.use")
    XCTAssertTrue(wait(use))
    use.click()
    XCTAssertTrue(waitForKeys(fetch, "⌘T"), "Use for Fetch takes the keys")
    XCTAssertTrue(waitForKeys(recorder(app, "newTerminal"), "None"), "and New Terminal has none")
  }

  func testSearchByTextAndByKeys() {
    let app = launchedApp()
    openPane(app)
    let search = element(app, "settings.shortcuts.search")
    search.click()
    search.typeText("cmd t")
    XCTAssertTrue(wait(row(app, "newTerminal")))
    XCTAssertTrue(wait(row(app, "run"), exists: false), "Run doesn't match “cmd t”")
    search.typeKey("a", modifierFlags: .command)
    search.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(wait(row(app, "run")), "an empty search shows every row")

    element(app, "settings.shortcuts.searchRecord").click()
    app.typeKey("p", modifierFlags: [.shift, .command])
    XCTAssertTrue(wait(element(app, "settings.shortcuts.searchKeys")))
    XCTAssertTrue(wait(row(app, "push")), "⇧⌘P finds Push")
    XCTAssertTrue(wait(row(app, "run"), exists: false))
    element(app, "settings.shortcuts.searchKeys.clear").click()
    XCTAssertTrue(wait(row(app, "run")))
  }

  /// A shortcut without ⌘ reaches its menu item past a focused terminal (ADR 0076): New Terminal on
  /// ⌃⌥Y opens a tab.
  func testAShortcutWithoutCommandWorksInATerminal() {
    let app = launchedApp()
    openPane(app)
    let newTerminal = recorder(app, "newTerminal")
    newTerminal.click()
    app.typeKey("y", modifierFlags: [.control, .option])
    XCTAssertTrue(waitForKeys(newTerminal, "⌃⌥Y"))
    XCTAssertTrue(
      wait(element(app, "settings.shortcuts.terminalNote.newTerminal")),
      "the row warns that terminal programs lose ⌃⌥Y")
    app.typeKey("w", modifierFlags: .command)  // Close Tab's keys close Settings

    let surface = element(app, "terminal.surface")
    XCTAssertTrue(wait(surface, 15), "the fixture's workroom has a terminal")
    surface.click()
    let tabs = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
    let before = tabs.count
    app.typeKey("y", modifierFlags: [.control, .option])
    let deadline = Date().addingTimeInterval(8)
    while tabs.count <= before, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    XCTAssertGreaterThan(tabs.count, before, "⌃⌥Y opened a terminal tab")
  }

  /// A ⌘ shortcut is its menu item's key equivalent: the key monitor leaves it to the menu, so a
  /// tab opening proves the item's equivalent moved with the rebind.
  func testARebindMovesTheMenuItemsKeyEquivalent() {
    let app = launchedApp()
    openPane(app)
    let newTerminal = recorder(app, "newTerminal")
    newTerminal.click()
    app.typeKey("j", modifierFlags: [.shift, .command])
    XCTAssertTrue(waitForKeys(newTerminal, "⇧⌘J"))
    app.typeKey("w", modifierFlags: .command)

    let surface = element(app, "terminal.surface")
    XCTAssertTrue(wait(surface, 15))
    surface.click()
    let tabs = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
    let before = tabs.count
    app.typeKey("t", modifierFlags: .command)
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    XCTAssertEqual(tabs.count, before, "⌘T is no longer New Terminal's")
    app.typeKey("j", modifierFlags: [.shift, .command])
    let deadline = Date().addingTimeInterval(8)
    while tabs.count <= before, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    XCTAssertGreaterThan(tabs.count, before, "⇧⌘J opened a terminal tab")
  }

  /// Go ▸ Terminal Tab names each tab as its chip does, live title included, and the items #148
  /// added for keys that had none are in their menus.
  func testTheMenusListTabsByNameAndHaveTheNewItems() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let surface = element(app, "terminal.surface")
    XCTAssertTrue(wait(surface, 15), "the fixture's workroom has a terminal")
    surface.click()
    // A running command holds the title it sets; at the prompt the shell would set its own.
    app.typeText("printf '\\033]2;WRTABNAME\\007'; sleep 60")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))

    let go = app.menuBars.menuBarItems["Go"]
    go.click()
    let tabs = go.menuItems["Terminal Tab"]
    XCTAssertTrue(tabs.waitForExistence(timeout: 5))
    tabs.hover()
    XCTAssertTrue(
      app.menuItems["WRTABNAME"].waitForExistence(timeout: 5),
      "the tab is listed by the title its program set")
    XCTAssertTrue(go.menuItems["Workroom Tab"].exists)
    for direction in ["Left", "Right", "Up", "Down"] {
      XCTAssertTrue(go.menuItems["Focus Pane \(direction)"].exists, "Focus Pane \(direction)")
    }
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey(.escape, modifierFlags: [])

    let window = app.menuBars.menuBarItems["Window"]
    window.click()
    XCTAssertTrue(window.menuItems["Next Window"].waitForExistence(timeout: 5))
    XCTAssertTrue(window.menuItems["Previous Window"].exists)
    app.typeKey(.escape, modifierFlags: [])

    let appMenu = app.menuBarItems.element(boundBy: 1)
    appMenu.click()
    XCTAssertTrue(
      appMenu.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Show/Hide"))
        .firstMatch.waitForExistence(timeout: 5),
      "Show/Hide Workroom sits in the app menu")
    app.typeKey(.escape, modifierFlags: [])
  }
}
