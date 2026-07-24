import XCTest

/// Issue #128: the View ▸ Projects/Changes/Files/History/Pull Request keyboard shortcuts didn't
/// reach the app when a TUI (a focused `GhosttySurfaceView`, e.g. running Claude Code) held first
/// responder — `GhosttySurfaceView.isAppShortcut` didn't reserve them, so the terminal swallowed
/// the keystroke before the menu's key-equivalent ever saw it. Separately, ⌥⌘S — the OS-standard
/// "Toggle Sidebar" shortcut (AppKit's `toggleSidebar:`, not bound to our own "Projects" menu item,
/// which uses ⌃⌘S) — popped the hidden native `NavigationSplitView` sidebar column open (truly
/// empty, `Color.clear.frame(width: 0)`, unlike the real `SidebarColumn`'s 240pt floor): RootView
/// keeps that column purely for toolbar/title-bar layering, but AppKit auto-wires its default
/// toggle to it regardless. Fixed by catching ⌥⌘S in the `AppDelegate` `NSEvent` monitor and
/// aliasing it onto our real `sidebarVisible` toggle before it can reach AppKit's responder chain.
///
/// These tests don't assume a specific starting toggle state (the underlying `Defaults` persist
/// across runs against the same Debug app) — each asserts the shortcut flips the state, whichever
/// direction that is, both with and without a focused terminal.
final class ViewMenuShortcutsUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Waits until `el`'s existence matches `want`, so a test can assert a toggle flipped without
  /// knowing which direction it started in (persisted `Defaults` carry over across runs).
  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 6) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// Clicks the first available terminal tab chip to move first responder into its
  /// `GhosttySurfaceView` — the "a TUI is focused" precondition issue #128 is about. Any fixture
  /// terminal works; the assertion only cares that a real Ghostty surface holds focus.
  private func focusATerminal(_ app: XCUIApplication) {
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab.")).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 10), "a terminal tab chip should exist")
    chip.click()
  }

  /// Asserts a keyboard shortcut flips a section's "shown" state. `Files`/`History` are solo panes
  /// whose "off" path closes the WHOLE inspector (`SectionHeader`'s header has no chevron/collapse
  /// binding), so their header's existence toggles cleanly. `Changes`/`Pull Request` collapse IN
  /// PLACE (their header stays in the tree either way) — `SectionHeader` gives their header an
  /// accessibility label of `"<title> section, collapsed"` / `"...expanded"`
  /// (`InspectorSplitView.swift`), so those two are asserted by label instead of existence.
  private func assertShortcutTogglesSection(
    _ app: XCUIApplication, headerID: String, key: String, modifiers: XCUIElement.KeyModifierFlags,
    collapsible: Bool
  ) {
    let header = element(app, id: headerID)
    if collapsible {
      // Don't require existence upfront: if a DIFFERENT section group is currently active (e.g.
      // Files), this header won't exist yet at all — the shortcut both switches the active group
      // AND expands it, so its label goes from "" (absent) straight to "...expanded".
      let before = header.exists ? header.label : ""
      let beforeDescription = before.isEmpty ? "absent" : before
      app.typeKey(key, modifierFlags: modifiers)
      let p = NSPredicate(format: "label != %@", before)
      let waited = XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: p, object: header)], timeout: 6)
      XCTAssertEqual(
        waited, .completed,
        "\(headerID)'s expanded/collapsed label should change after the shortcut (was \(beforeDescription))"
      )
    } else {
      let before = header.exists
      app.typeKey(key, modifierFlags: modifiers)
      XCTAssertTrue(
        waitExists(header, !before),
        "\(headerID) should flip from \(before) after the shortcut")
    }
  }

  // MARK: - Bug 1: shortcuts reach the menu even with a TUI focused

  func testChangesFilesHistoryPullRequestShortcutsWorkWithTerminalFocused() {
    let app = launchedApp()
    focusATerminal(app)

    assertShortcutTogglesSection(
      app, headerID: "inspector.header.Changes", key: "c", modifiers: [.command, .option],
      collapsible: true)
    focusATerminal(app)
    assertShortcutTogglesSection(
      app, headerID: "inspector.header.Files", key: "f", modifiers: [.command, .option],
      collapsible: false)
    focusATerminal(app)
    assertShortcutTogglesSection(
      app, headerID: "inspector.header.History", key: "y", modifiers: [.command, .option],
      collapsible: false)
    focusATerminal(app)
    assertShortcutTogglesSection(
      app, headerID: "inspector.header.Pull Request", key: "p", modifiers: [.command, .option],
      collapsible: true)
  }

  // MARK: - Bug 2a: ⌃⌘S (our own Projects shortcut) toggles the real sidebar, terminal-focused or not

  func testProjectsShortcutTogglesSidebarWithTerminalFocused() {
    let app = launchedApp()
    focusATerminal(app)

    let row = element(app, id: "sidebar.project.\(uiTestFixtureProjectName)")
    let before = row.exists
    app.typeKey("s", modifierFlags: [.command, .control])
    XCTAssertTrue(
      waitExists(row, !before),
      "⌃⌘S should toggle the real Projects sidebar even with a terminal focused")
  }

  func testProjectsShortcutTogglesSidebarWithoutTerminalFocused() {
    let app = launchedApp()

    let row = element(app, id: "sidebar.project.\(uiTestFixtureProjectName)")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the fixture project row should render")
    app.typeKey("s", modifierFlags: [.command, .control])
    XCTAssertTrue(waitExists(row, false), "⌃⌘S should hide the real Projects sidebar")
    app.typeKey("s", modifierFlags: [.command, .control])
    XCTAssertTrue(waitExists(row, true), "⌃⌘S should show the real Projects sidebar again")
  }

  // MARK: - Bug 2b: ⌥⌘S (the OS-standard Toggle Sidebar shortcut) must not open the empty native
  // column — it's aliased onto the same real sidebar toggle instead, terminal-focused or not.

  func testOSStandardToggleSidebarShortcutTogglesRealSidebarWithTerminalFocused() {
    let app = launchedApp()
    focusATerminal(app)

    let row = element(app, id: "sidebar.project.\(uiTestFixtureProjectName)")
    let before = row.exists
    app.typeKey("s", modifierFlags: [.command, .option])
    XCTAssertTrue(
      waitExists(row, !before),
      "⌥⌘S should toggle the real Projects sidebar (not an empty native column), terminal focused")
  }

  func testOSStandardToggleSidebarShortcutTogglesRealSidebarWithoutTerminalFocused() {
    let app = launchedApp()

    let row = element(app, id: "sidebar.project.\(uiTestFixtureProjectName)")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the fixture project row should render")
    app.typeKey("s", modifierFlags: [.command, .option])
    XCTAssertTrue(waitExists(row, false), "⌥⌘S should hide the real Projects sidebar")
    app.typeKey("s", modifierFlags: [.command, .option])
    XCTAssertTrue(waitExists(row, true), "⌥⌘S should show the real Projects sidebar again")
  }

  // MARK: - Bug 3: ⌥⌘B (secondary Projects sidebar toggle) reaches the app with a TUI focused too

  func testSecondaryProjectsShortcutTogglesSidebarWithTerminalFocused() {
    let app = launchedApp()
    focusATerminal(app)

    let row = element(app, id: "sidebar.project.\(uiTestFixtureProjectName)")
    let before = row.exists
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(
      waitExists(row, !before),
      "⌥⌘B should toggle the real Projects sidebar even with a terminal focused")
  }

  func testSecondaryProjectsShortcutTogglesSidebarWithoutTerminalFocused() {
    let app = launchedApp()

    let row = element(app, id: "sidebar.project.\(uiTestFixtureProjectName)")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the fixture project row should render")
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(waitExists(row, false), "⌥⌘B should hide the real Projects sidebar")
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(waitExists(row, true), "⌥⌘B should show the real Projects sidebar again")
  }

  // MARK: - Bug 4: ⌘B toggles the Inspector as a whole, independent of which section is active

  func testInspectorShortcutTogglesWholeInspectorWithTerminalFocused() {
    let app = launchedApp()
    focusATerminal(app)

    // Establish a known section (Changes) and ensure the inspector is open, so ⌘B's effect on the
    // header is unambiguous regardless of persisted `Defaults` state from a prior run.
    let header = element(app, id: "inspector.header.Changes")
    app.typeKey("c", modifierFlags: [.command, .option])
    XCTAssertTrue(header.waitForExistence(timeout: 6), "Changes section should be open")

    focusATerminal(app)
    app.typeKey("b", modifierFlags: [.command])
    XCTAssertTrue(
      waitExists(header, false), "⌘B should hide the whole inspector, terminal focused")

    focusATerminal(app)
    app.typeKey("b", modifierFlags: [.command])
    XCTAssertTrue(
      waitExists(header, true),
      "⌘B should restore the inspector back on the Changes section, terminal focused")
  }
}

/// Mirrors `UITestFixture.projectName` — kept as a plain literal here so this file doesn't need
/// `@testable import Workroom` just to read one constant.
private let uiTestFixtureProjectName = "UITestProject"
