import XCTest

/// UI test for the **theme picker** (⌘⇧K) after the 27→58 family expansion.
///
/// This covers the one link in the chain that no unit test can reach. `ThemeServiceTests` proves the
/// registry and the bundled files agree, reading the bundle from the test host — but it never renders
/// a row, and it never proves a theme the user picks actually reaches the terminal engine. That path
/// runs through SwiftUI and then through a generated ghostty config, so only a UI test sees it.
///
/// **What "applied" means here.** Asserting a checkmark would only prove a `Defaults` write. Applying
/// a theme also rewrites the generated libghostty config with `theme = "<variant file name>"`
/// (`GhosttyApp.writeThemeConfig`), and this runner names that file for the launch so it can read
/// it back — the assertion is that the conf names the expected *file*, which proves registry lookup
/// → appearance-appropriate variant → the name handed to libghostty.
///
/// **Residual gap, deliberately not claimed:** nothing here proves ghostty *accepted* the file. The
/// engine exposes no error surface for an unresolvable `theme =`, so a bad file is indistinguishable
/// from a good one at this level. `themes/CHECKSUMS` is what pins the bytes instead.
///
/// The picker is a transient popover anchored to a toolbar button (`TrailingTitlebarBar`), not a sheet
/// and not a window — so it is queried through the app's descendants, and `app.sheets` staying empty is
/// part of what the dropdown test asserts.
///
/// The starting light and dark themes come from `-WorkroomUITestLightTheme` and
/// `-WorkroomUITestDarkTheme`, mirrored into `Defaults` by
/// `UITestFixture.applyFixtureDefaults`. That is app-side on purpose: `Defaults` is not isolated by a
/// throwaway `$HOME`, so a runner-side save/restore would be writing the developer's real preference.
///
/// Run with a real GUI login session — XCUITest can't drive a headless run, so this lives in the UI
/// scheme, excluded from `make app-test`. Scope it when iterating; the full UI suite is slow:
/// `xcodebuild … -only-testing:WorkroomAppUITests/ThemePickerUITests`
final class ThemePickerUITests: XCTestCase {
  /// The app's generated conf, at a path this runner picks and hands over with
  /// `-WorkroomUITestGhosttyConfigFile` rather than one it works out.
  ///
  /// Working it out is wrong here, and silently so. Asked for `.applicationSupportDirectory`,
  /// `FileManager` answers the runner's own container
  /// (`~/Library/Containers/com.developwithstyle.workroom.uitests.xctrunner/Data/Library/…`), a
  /// path the app never writes to: every read returned nil and the assertion failed while the
  /// feature worked. And the app's real file is scoped by bundle id — by process, in a fixture
  /// launch that names no file — so there is no fixed location left to compute.
  ///
  /// `/tmp` rather than this runner's `NSTemporaryDirectory()`, which is inside that same
  /// container; `GhosttyOrphanShellUITests.stampPath` measured `/tmp` as the scratch directory both
  /// sides reach.
  private var generatedConfURL: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    let conf = URL(fileURLWithPath: "/tmp/workroom-uitest-ghostty-\(UUID().uuidString).conf")
    generatedConfURL = conf
    addTeardownBlock { try? FileManager.default.removeItem(at: conf) }
  }

  /// A newly-bundled family — deliberately one of the 31 added, so this fails if the new files didn't
  /// make it into the built bundle. `Night Owl` also exercises the awkward shape: its variants are
  /// `Night Owl` / `Light Owl`, which share no common prefix, so a name-suffix assumption anywhere in
  /// the chain would break on it.
  private let family = "Night Owl"
  private let darkVariantFile = "Night Owl"
  private let lightVariantFile = "Light Owl"

  private func launchedApp(userThemeDirectory: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if let userThemeDirectory {
      app.launchArguments += ["-WorkroomUITestUserThemeDirectory", userThemeDirectory]
    }
    // Start somewhere that is NOT the family under test, so a passing assertion can't be the
    // fixture's starting state.
    app.launchArguments += ["-WorkroomUITestLightTheme", "Workroom Light"]
    app.launchArguments += ["-WorkroomUITestDarkTheme", "Workroom"]
    // Pinned Dark, so which side is showing, and so which tab ⌘⇧K opens, doesn't hang on the
    // machine's appearance or on whatever the Dev app was last left on (#735).
    app.launchArguments += ["-WorkroomUITestAppearance", "dark"]
    app.launchArguments += ["-WorkroomUITestGhosttyConfigFile", generatedConfURL.path]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// The `theme = "…"` line of the generated conf, or nil while it hasn't been written yet.
  private func confTheme() -> String? {
    guard let text = try? String(contentsOf: generatedConfURL, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("theme = ") {
      return line.dropFirst("theme = ".count).trimmingCharacters(
        in: CharacterSet(charactersIn: "\""))
    }
    return nil
  }

  /// Poll the conf until it names one of `expected`. The apply path is synchronous from the click but
  /// the file write and the engine reload are not observable through the a11y tree, so this waits on
  /// the artefact rather than on a UI state that would only prove a `Defaults` write.
  private func waitForConfTheme(oneOf expected: [String], timeout: TimeInterval = 5) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let current = confTheme(), expected.contains(current) { return current }
      usleep(150_000)
    }
    return confTheme()
  }

  private func openPicker(_ app: XCUIApplication) {
    app.typeKey("k", modifierFlags: [.command, .shift])
  }

  private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
    element(app, "theme-family-\(name)")
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// What an element shows: its accessibility value, or its label when it has no value.
  private func text(of element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty { return value }
    return element.label
  }

  /// Open Settings → Appearance, through the app menu as `SettingsSidebarUITests` does.
  private func openAppearanceSettings(_ app: XCUIApplication) {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "no app menu")
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings… menu item")
    settings.click()
    let pane = element(app, "settingsPane.appearance")
    XCTAssertTrue(pane.waitForExistence(timeout: 10), "the Settings sidebar did not render")
    pane.click()
    XCTAssertTrue(
      settingsRow(app, "themeFamily").waitForExistence(timeout: 5),
      "Settings → Appearance has no Theme family row")
  }

  /// A Settings → Appearance theme row: `themeFamily`, `lightTheme` or `darkTheme`.
  private func settingsRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    element(app, "settings.control.\(id)")
  }

  /// Wait for a Settings theme row to show `expected`. Polled: the Settings scene's `@Default`
  /// invalidates asynchronously, so an immediate read can still show the previous value.
  private func waitForSettingsRow(
    _ app: XCUIApplication, _ id: String, toShow expected: String, timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let row = settingsRow(app, id)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if row.exists, row.label == expected || (row.value as? String) == expected { return }
      usleep(150_000)
    }
    XCTFail(
      "the \(id) row shows '\(row.exists ? text(of: row) : "nothing")', expected '\(expected)'",
      file: file, line: line)
  }

  /// Close the open picker with Esc, and prove it closed.
  private func closePicker(_ app: XCUIApplication) {
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5), "Esc left the picker up")
  }

  /// The whole picker lifecycle in ONE launch (each launch costs a full app start), as an ordered
  /// chain. Every step ends with the popover proven gone before the next one opens it, so no
  /// `waitForExistence` can be satisfied by the previous step's popover. The applying step is LAST:
  /// it changes the selected family, and the first step needs the fixture's `Workroom` row to be the
  /// one materialised.
  ///
  /// 1. **Hangs off the toolbar button; a click away closes it.** The shape that makes a live preview
  ///    possible at all. It used to be a `.sheet`, which was document-modal: AppKit rendered the whole
  ///    window inactive behind it (traffic lights greyed, the sidebar's VCS dot badges orange → dull
  ///    brown), and being anchored under the title bar it covered the content whose colours you were
  ///    choosing. XCUITest exposes no window key/main state and no pixels, so the *inactive rendering*
  ///    itself isn't assertable. What is — and rules it out — is that the picker is a transient popover
  ///    rather than a sheet: `app.sheets` stays empty, and a click elsewhere dismisses it, which no
  ///    modal presentation does.
  /// 2. **⌘⇧K opens it AND closes it again.** The second press is the load-bearing half. The command
  ///    is a broadcast notification, and the handler toggles only if `store.hostWindow?.isKeyWindow`
  ///    — so the shortcut can close an OPEN dropdown only because a popover doesn't take key from the
  ///    window it hangs off. That is measured behaviour, not a documented guarantee, and an
  ///    independent reviewer flagged the opposite as a P1 wedge (open it, then never able to close it
  ///    by keyboard). This is the assertion that would catch it if AppKit ever changed its mind.
  /// 3. **Esc closes it.** `ThemePicker` handles this itself (`.onExitCommand`) rather than trusting
  ///    the host, because a popover's own cancel handling depends on a behaviour mode SwiftUI doesn't
  ///    expose.
  /// 4. **A dialog raised by KEYBOARD closes it** — the `hasModalPresentation` path in
  ///    `TrailingTitlebarBar`. Driven with ⌘N rather than a menu click on purpose: a click anywhere
  ///    outside would dismiss the popover natively, so a mouse-driven version would pass without the
  ///    handler existing. A keystroke sends no outside click, which is exactly why the handler has to
  ///    exist — a dropdown left hanging over a modal is both confusing and unreachable past.
  /// 5. **Both of a new family's swatches render a resolved theme.** A variant whose file doesn't
  ///    resolve renders the grey fallback swatch, the visible symptom of a registry typo — and the one
  ///    failure a bundle-reading unit test cannot see, because it happens in the view. Each swatch
  ///    reports its own variant file name and resolution state through accessibility, so this names
  ///    the two files rather than counting anonymous elements. Scoped to the family under test rather
  ///    than all 58 rows: applying a theme rewrites the conf and force-reloads the engine, so walking
  ///    the whole list would mean 58 of those round-trips. Per-theme colour correctness is already
  ///    asserted 116 times over by `SwitcherThemeSweepTests`.
  /// 6. **A newly-bundled family is findable by search, reaches the engine, and the generated conf
  ///    names the variant file for the current appearance.** Deliberately one of the 31 added, so it
  ///    fails if the new files didn't make it into the built bundle. `Night Owl` also exercises the
  ///    awkward shape: its variants are `Night Owl` / `Light Owl`, which share no common prefix, so a
  ///    name-suffix assumption anywhere in the chain would break on it.
  func testThePickerDropdownLifecycleAndApplyingANewFamilyReachesTheEngine() throws {
    let app = launchedApp()
    let popover = app.popovers.firstMatch
    XCTAssertFalse(popover.exists, "a popover was already open at launch")

    // 1. Toolbar button → popover (not a sheet) → click away closes it.
    let button = app.descendants(matching: .any)
      .matching(identifier: "toolbar.theme").firstMatch
    XCTAssertTrue(
      button.waitForExistence(timeout: 5), "no theme button in the window's trailing toolbar")

    // Click the centre coordinate rather than the element: the button lives in a window-level titlebar
    // accessory hosting tree, and an identifier query there can resolve to a container whose centre is
    // not over the glyph.
    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

    // The presentation KIND is the assertion, not any particular row: a popover registers in
    // `app.popovers`, a sheet in `app.sheets`. That distinction IS the fix — a sheet is modal, which is
    // what had AppKit render the window inactive behind the picker.
    XCTAssertTrue(
      popover.waitForExistence(timeout: 5),
      "the button did not open the theme dropdown — button frame \(button.frame), hittable "
        + "\(button.isHittable), sheets \(app.sheets.count)")
    XCTAssertEqual(app.sheets.count, 0, "the picker came up as a sheet, not a dropdown")

    // Content really rendered, not just an empty popover. `Workroom` is the family the fixture starts on
    // and the list scrolls the selected family into view, so that row is materialised. The family used by
    // the later steps is row 33 of 58, and a `LazyVStack` never builds it until the search filters it in
    // — which is exactly what failed an earlier version of this test against working code.
    // Under the fixture's Dark appearance the button opens on the Dark tab (#735): its rows are dark
    // themes, scrolled to the current one, and no family row is built.
    XCTAssertTrue(
      element(app, "theme-dark-Workroom").waitForExistence(timeout: 3),
      "the toolbar button did not open the picker on the Dark tab")
    XCTAssertFalse(
      element(app, "theme-family-Workroom").exists, "the Dark tab listed theme families")

    // Click in the DETAIL area (0.6 across), not the leading 0.25 a previous version used: the sidebar
    // occupies up to 360pt at the leading edge, so a click there can land on a workroom row, change the
    // selection, and close the dropdown through the explicit selection handler — passing this test via a
    // different mechanism than the native outside-click dismissal it claims to prove.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8)).click()
    XCTAssertTrue(
      popover.waitForNonExistence(timeout: 5),
      "the dropdown survived a click elsewhere — it is not transient, so any other action leaves it "
        + "hanging over the app")

    // 2. ⌘⇧K opens, ⌘⇧K closes.
    openPicker(app)
    XCTAssertTrue(popover.waitForExistence(timeout: 5), "⌘⇧K did not open the dropdown")

    openPicker(app)
    XCTAssertTrue(
      popover.waitForNonExistence(timeout: 5),
      "⌘⇧K did not close the dropdown it had just opened — if the popover now takes key focus from its "
        + "window, the isKeyWindow guard in TrailingTitlebarBar rejects the toggle and the shortcut can "
        + "only ever open it")

    // 3. Esc closes it.
    openPicker(app)
    XCTAssertTrue(popover.waitForExistence(timeout: 5), "⌘⇧K did not reopen the dropdown")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Esc must dismiss the dropdown")

    // 4. A keyboard-raised dialog closes it.
    openPicker(app)
    XCTAssertTrue(popover.waitForExistence(timeout: 5), "⌘⇧K did not reopen the dropdown")

    app.typeKey("n", modifierFlags: [.command])  // New Workroom — sets store.activePicker
    XCTAssertTrue(
      popover.waitForNonExistence(timeout: 5),
      "a modal presentation must close the dropdown; without the hasModalPresentation handler a "
        + "keyboard-raised dialog leaves it hanging over the modal")

    // The dialog really is up (it is an overlay, not a sheet), then leave none up for the next step.
    let dialogFilter = app.textFields["newWorkroom.filter"]
    XCTAssertTrue(
      dialogFilter.waitForExistence(timeout: 5), "⌘N did not raise the New Workroom dialog")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      dialogFilter.waitForNonExistence(timeout: 5), "Esc did not dismiss the New Workroom dialog")

    // 5. Both swatches of the new family resolve.
    openPicker(app)
    XCTAssertTrue(
      popover.waitForExistence(timeout: 5), "⌘⇧K did not open the dropdown after the dialog closed")

    // ⌘⇧K opens on the current appearance's tab too, which is Dark here; families are a tab away.
    XCTAssertTrue(
      element(app, "theme-dark-Workroom").waitForExistence(timeout: 3),
      "⌘⇧K did not open the picker on the Dark tab")
    element(app, "theme-picker.tab.family").click()
    XCTAssertTrue(
      row(app, "Workroom").waitForExistence(timeout: 3), "the Family tab rendered no rows")

    // Search rather than scroll: with 58 rows the target may be far down the list, and searching is
    // also what a user does. The search field takes focus on open.
    app.typeText(family)

    let target = row(app, family)
    XCTAssertTrue(
      target.waitForExistence(timeout: 5),
      "'\(family)' did not appear in the picker — either its files are missing from the built bundle "
        + "or it is not registered in ThemeCatalog.families")

    for variant in [darkVariantFile, lightVariantFile] {
      let resolved = app.descendants(matching: .any)
        .matching(identifier: "theme-swatch-\(variant)-resolved").firstMatch
      XCTAssertTrue(
        resolved.waitForExistence(timeout: 3),
        "the '\(variant)' swatch did not render as resolved — that file is missing from the bundle or "
          + "misnamed in ThemeCatalog.families, so the row is drawing the grey fallback")

      let unresolved = app.descendants(matching: .any)
        .matching(identifier: "theme-swatch-\(variant)-unresolved").firstMatch
      XCTAssertFalse(unresolved.exists, "the '\(variant)' swatch rendered the fallback")
    }

    // 6. LAST: apply it. Clicking changes the persisted family, so nothing may follow that reads the
    // picker's starting state; the next launch re-seeds `Workroom` through the fixture.
    target.click()

    // The appearance is pinned Dark, so the family's dark theme is the one the engine is handed.
    let applied = waitForConfTheme(oneOf: [darkVariantFile])
    XCTAssertEqual(
      applied, darkVariantFile,
      "the engine was handed '\(applied ?? "nil")' — expected the '\(family)' family's dark theme")
  }

  /// Choosing a family sets both themes and the Settings rows name it; then choosing one side alone
  /// changes only that side, and the family row says "Custom" (#735). One launch for both, since the
  /// second needs the first's family as its starting point. The appearance is Dark, so the generated
  /// config names the dark theme each time.
  func testAFamilySetsBothThemesAndChangingOneSideAloneShowsCustom() throws {
    let app = launchedApp()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")

    openAppearanceSettings(app)
    waitForSettingsRow(app, "themeFamily", toShow: "Workroom")
    waitForSettingsRow(app, "lightTheme", toShow: "Workroom Light")
    waitForSettingsRow(app, "darkTheme", toShow: "Workroom")

    // The Theme family row opens the picker on the Family tab.
    settingsRow(app, "themeFamily").click()
    XCTAssertTrue(
      app.popovers.firstMatch.waitForExistence(timeout: 5), "the Theme family row opened no picker")
    XCTAssertTrue(
      row(app, "Workroom").waitForExistence(timeout: 3),
      "the Theme family row did not open the picker on the Family tab")

    app.typeText(family)
    let target = row(app, family)
    XCTAssertTrue(target.waitForExistence(timeout: 5), "'\(family)' is not on the Family tab")
    target.click()
    XCTAssertEqual(
      waitForConfTheme(oneOf: [darkVariantFile]), darkVariantFile,
      "choosing '\(family)' did not reach the engine")
    closePicker(app)

    waitForSettingsRow(app, "themeFamily", toShow: family)
    waitForSettingsRow(app, "lightTheme", toShow: lightVariantFile)
    waitForSettingsRow(app, "darkTheme", toShow: darkVariantFile)

    // The Dark theme row opens the picker on the Dark tab, on the current dark theme.
    settingsRow(app, "darkTheme").click()
    XCTAssertTrue(
      app.popovers.firstMatch.waitForExistence(timeout: 5), "the Dark theme row opened no picker")
    XCTAssertTrue(
      element(app, "theme-dark-\(darkVariantFile)").waitForExistence(timeout: 3),
      "the Dark theme row did not open the picker on the Dark tab")
    XCTAssertFalse(row(app, family).exists, "the Dark tab listed theme families")
    XCTAssertFalse(
      element(app, "theme-light-\(lightVariantFile)").exists, "the Dark tab listed a light theme")
    XCTAssertFalse(
      element(app, "theme-picker.note").exists,
      "the Dark tab noted another mode while Dark is showing")

    app.typeText("Nord")
    let nord = element(app, "theme-dark-Nord")
    XCTAssertTrue(nord.waitForExistence(timeout: 5), "'Nord' is not on the Dark tab")
    nord.click()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Nord"]), "Nord", "choosing the dark theme 'Nord' didn't show")
    closePicker(app)

    waitForSettingsRow(app, "themeFamily", toShow: "Custom")
    waitForSettingsRow(app, "lightTheme", toShow: lightVariantFile)
    waitForSettingsRow(app, "darkTheme", toShow: "Nord")
  }

  /// Browsing the side that isn't showing saves the choice without changing the generated config
  /// (#735). The appearance is Dark, so the Light tab is the hidden side: it says so, an arrow key
  /// there saves the light theme, and the engine keeps the dark theme it had.
  func testBrowsingTheHiddenSideSavesWithoutChangingTheGeneratedConfig() throws {
    let app = launchedApp()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")

    openAppearanceSettings(app)
    settingsRow(app, "lightTheme").click()
    XCTAssertTrue(
      app.popovers.firstMatch.waitForExistence(timeout: 5), "the Light theme row opened no picker")
    XCTAssertTrue(
      element(app, "theme-light-Workroom Light").waitForExistence(timeout: 3),
      "the Light theme row did not open the picker on the Light tab")
    XCTAssertFalse(element(app, "theme-dark-Workroom").exists, "the Light tab listed a dark theme")

    let note = element(app, "theme-picker.note")
    XCTAssertTrue(note.waitForExistence(timeout: 3), "the Light tab doesn't say it applies later")
    XCTAssertEqual(text(of: note), "Applies in Light mode")

    app.typeText(lightVariantFile)
    XCTAssertTrue(
      element(app, "theme-light-\(lightVariantFile)").waitForExistence(timeout: 5),
      "'\(lightVariantFile)' is not on the Light tab")
    app.typeKey(.downArrow, modifierFlags: [])

    // The positive signal first, so the unchanged config below can't be read before anything
    // happened.
    waitForSettingsRow(app, "lightTheme", toShow: lightVariantFile)
    waitForSettingsRow(app, "themeFamily", toShow: "Custom")
    waitForSettingsRow(app, "darkTheme", toShow: "Workroom")
    usleep(1_000_000)
    XCTAssertEqual(
      confTheme(), "Workroom",
      "browsing the hidden Light side changed the generated config, so the screen repainted")
  }

  /// Your own theme files in the Light and Dark lists (#737), from a scratch folder under `/tmp`
  /// handed over with `-WorkroomUITestUserThemeDirectory`, never the real `~/.config`. The appearance
  /// is Dark, so ⌘⇧K opens the Dark tab:
  ///
  /// - a dark file of yours is on the Dark tab, labelled as yours, and choosing it reaches the
  ///   generated config;
  /// - a dark file called `Ayu Light` replaces that light theme, so it's on the Dark tab, labelled,
  ///   and the Ayu family is hidden from the Family tab while its neighbours stay;
  /// - a file that doesn't parse is listed nowhere.
  func testYourOwnThemeFilesAreListedOnTheirSideAndLabelled() throws {
    let dir = URL(fileURLWithPath: "/tmp/workroom-uitest-user-themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let darkFile = "background = #101418\nforeground = #e0e0e0\n"
    try darkFile.write(
      to: dir.appendingPathComponent("My Night"), atomically: true, encoding: .utf8)
    try darkFile.write(
      to: dir.appendingPathComponent("Ayu Light"), atomically: true, encoding: .utf8)
    try "not a theme\n".write(
      to: dir.appendingPathComponent("Broken Mine"), atomically: true, encoding: .utf8)

    let app = launchedApp(userThemeDirectory: dir.path)
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")

    openPicker(app)
    XCTAssertTrue(
      element(app, "theme-dark-Workroom").waitForExistence(timeout: 5),
      "⌘⇧K did not open the picker on the Dark tab")

    // The Family tab: Ayu is hidden while its light theme is a dark file; its neighbours stay.
    element(app, "theme-picker.tab.family").click()
    XCTAssertTrue(
      row(app, "Atom One").waitForExistence(timeout: 3), "the Family tab did not list Atom One")
    XCTAssertTrue(row(app, "Belafonte").exists, "the Family tab did not list Belafonte")
    XCTAssertFalse(
      row(app, "Ayu").exists, "Ayu is offered although its light theme is a dark file of yours")

    // The Dark tab: the replacement moved here, labelled; the bundled Ayu Mirage isn't labelled.
    element(app, "theme-picker.tab.dark").click()
    app.typeText("Ayu")
    XCTAssertTrue(
      element(app, "theme-dark-Ayu Light").waitForExistence(timeout: 3),
      "a dark file called 'Ayu Light' is not on the Dark tab")
    XCTAssertTrue(
      element(app, "theme-dark-Ayu Light-yours").exists, "the replacement isn't labelled as yours")
    XCTAssertTrue(element(app, "theme-dark-Ayu Mirage").exists, "Ayu Mirage is missing")
    XCTAssertFalse(
      element(app, "theme-dark-Ayu Mirage-yours").exists, "a bundled theme is labelled as yours")

    // Your own dark theme, labelled, and choosing it reaches the engine.
    app.typeKey("a", modifierFlags: [.command])
    app.typeText("My Night")
    XCTAssertTrue(
      element(app, "theme-dark-My Night").waitForExistence(timeout: 3),
      "your 'My Night' is not on the Dark tab")
    XCTAssertTrue(
      element(app, "theme-dark-My Night-yours").exists, "'My Night' isn't labelled as yours")
    XCTAssertFalse(element(app, "theme-dark-Ayu Light").exists, "the search didn't apply")
    app.typeKey(.downArrow, modifierFlags: [])
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["My Night"]), "My Night",
      "choosing your own dark theme didn't reach the generated config")

    // The unparseable file is listed on neither side.
    app.typeKey("a", modifierFlags: [.command])
    app.typeText("Mine")
    XCTAssertTrue(
      element(app, "theme-dark-My Night").waitForNonExistence(timeout: 3),
      "the search didn't apply")
    XCTAssertFalse(element(app, "theme-dark-Broken Mine").exists, "an unparseable file is listed")
    element(app, "theme-picker.tab.light").click()
    XCTAssertTrue(
      element(app, "theme-picker.note").waitForExistence(timeout: 3), "the Light tab did not open")
    XCTAssertFalse(element(app, "theme-light-Broken Mine").exists, "an unparseable file is listed")
  }
}
