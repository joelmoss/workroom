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

  /// Fixture project row: it exists exactly while the real Projects sidebar is shown.
  private func projectRow(_ app: XCUIApplication) -> XCUIElement {
    element(app, id: "sidebar.project.\(uiTestFixtureProjectName)")
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

  /// Asserts a keyboard shortcut flips a section's "shown" state. `Files` is a solo pane whose "off"
  /// path closes the WHOLE inspector (`SectionHeader`'s header has no chevron/collapse binding), so
  /// its header's existence toggles cleanly. `Changes`/`History`/`Pull Request` collapse IN PLACE
  /// (their header stays in the tree either way) — `SectionHeader` gives their header an
  /// accessibility label of `"<title> section, collapsed"` / `"...expanded"`
  /// (`InspectorSplitView.swift`), so those three are asserted by label instead of existence.
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

  /// Without a focused terminal: asserts the project row is on screen first (so the absence check
  /// can't pass vacuously), then that the shortcut hides the sidebar and shows it again. Toggling
  /// twice returns to the starting state.
  private func assertSidebarShortcutHidesThenShows(
    _ app: XCUIApplication, label: String, key: String, modifiers: XCUIElement.KeyModifierFlags
  ) {
    let row = projectRow(app)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the fixture project row should render")
    app.typeKey(key, modifierFlags: modifiers)
    XCTAssertTrue(waitExists(row, false), "\(label) should hide the real Projects sidebar")
    app.typeKey(key, modifierFlags: modifiers)
    XCTAssertTrue(waitExists(row, true), "\(label) should show the real Projects sidebar again")
  }

  /// With a focused terminal: the starting state is read right before the keystroke and the
  /// shortcut must flip it, whichever direction that is, so a no-op keystroke can't pass. It then
  /// flips it back, so the sidebar ends where it started: the toggle persists across runs, and the
  /// next run's no-focus steps need the sidebar showing.
  private func assertSidebarShortcutFlipsWithTerminalFocused(
    _ app: XCUIApplication, key: String, modifiers: XCUIElement.KeyModifierFlags, message: String
  ) {
    focusATerminal(app)
    let row = projectRow(app)
    let before = row.exists
    app.typeKey(key, modifierFlags: modifiers)
    XCTAssertTrue(waitExists(row, !before), message)
    focusATerminal(app)
    app.typeKey(key, modifierFlags: modifiers)
    XCTAssertTrue(waitExists(row, before), "\(message) (and back again)")
  }

  /// One launch, ordered. Every step reads its own starting state (the toggles' `Defaults` persist
  /// across runs), so a flip left by an earlier step can't satisfy a later assertion.
  ///
  /// 1. Bugs 2a/2b/3 WITHOUT a focused terminal. These run first, before anything has clicked into
  ///    a terminal, and each toggles twice so the sidebar ends where it started. ⌃⌘S is our own
  ///    Projects shortcut; ⌥⌘S is the OS-standard Toggle Sidebar shortcut, which must not open the
  ///    empty native column (it's aliased onto the same real sidebar toggle); ⌥⌘B is the secondary
  ///    Projects toggle.
  /// 2. Bug 1: Changes/Files/History/Pull Request shortcuts reach the menu with a TUI focused.
  /// 3. Bugs 2a/2b/3 again, WITH a focused terminal (the keystroke must beat the Ghostty surface).
  /// 4. Bug 4: ⌘B toggles the Inspector as a whole, independent of which section is active. It
  ///    sets its own known state with ⌥⌘C, so it goes last and needs nothing from earlier steps.
  func testViewMenuShortcutsReachTheAppWithAndWithoutTerminalFocused() {
    let app = launchedApp()

    // Bugs 2a/2b/3, no terminal focus.
    assertSidebarShortcutHidesThenShows(
      app, label: "⌃⌘S", key: "s", modifiers: [.command, .control])
    assertSidebarShortcutHidesThenShows(
      app, label: "⌥⌘S", key: "s", modifiers: [.command, .option])
    assertSidebarShortcutHidesThenShows(
      app, label: "⌥⌘B", key: "b", modifiers: [.command, .option])

    // Bug 1: shortcuts reach the menu even with a TUI focused.
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
      collapsible: true)
    focusATerminal(app)
    assertShortcutTogglesSection(
      app, headerID: "inspector.header.Pull Request", key: "p", modifiers: [.command, .option],
      collapsible: true)

    // Bugs 2a/2b/3, terminal focused.
    assertSidebarShortcutFlipsWithTerminalFocused(
      app, key: "s", modifiers: [.command, .control],
      message: "⌃⌘S should toggle the real Projects sidebar even with a terminal focused")
    assertSidebarShortcutFlipsWithTerminalFocused(
      app, key: "s", modifiers: [.command, .option],
      message:
        "⌥⌘S should toggle the real Projects sidebar (not an empty native column), terminal focused"
    )
    assertSidebarShortcutFlipsWithTerminalFocused(
      app, key: "b", modifiers: [.command, .option],
      message: "⌥⌘B should toggle the real Projects sidebar even with a terminal focused")

    // Bug 4: ⌘B toggles the whole Inspector.
    focusATerminal(app)
    // Establish a known section (Changes) and ensure the inspector is open, so ⌘B's effect on the
    // header is unambiguous regardless of the state the earlier steps left behind.
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
