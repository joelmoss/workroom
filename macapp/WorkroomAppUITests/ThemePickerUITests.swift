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

  private func launchedApp(
    withUserThemes: Bool = false, lightTheme: String = "Workroom Light",
    favouriteThemes: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Favourites are seeded by the app itself, and reset to none when unset, like the themes below.
    if !favouriteThemes.isEmpty {
      app.launchArguments += [
        "-WorkroomUITestFavouriteThemes", favouriteThemes.joined(separator: ","),
      ]
    }
    if withUserThemes { app.launchArguments += ["-WorkroomUITestUserThemes", "1"] }
    // Start somewhere that is NOT the family under test, so a passing assertion can't be the
    // fixture's starting state.
    app.launchArguments += ["-WorkroomUITestLightTheme", lightTheme]
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

  /// Open Settings ▸ Themes the way the Appearance pane offers it: through the app menu as
  /// `SettingsSidebarUITests` does, then Appearance's Themes row, which names the family.
  private func openThemesSettings(_ app: XCUIApplication, family expected: String = "Workroom") {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "no app menu")
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings… menu item")
    settings.click()
    let pane = element(app, "settingsPane.appearance")
    XCTAssertTrue(pane.waitForExistence(timeout: 10), "the Settings sidebar did not render")
    pane.click()
    let themesRow = element(app, "settings.control.themes")
    XCTAssertTrue(themesRow.waitForExistence(timeout: 5), "Settings ▸ Appearance has no Themes row")
    XCTAssertTrue(
      text(of: themesRow).contains(expected),
      "the Themes row shows '\(text(of: themesRow))', not the family '\(expected)'")
    themesRow.click()
    XCTAssertTrue(
      element(app, "settings.themes.stage.light").waitForExistence(timeout: 5),
      "Settings ▸ Themes has no stage")
  }

  /// Wait for a Themes pane label — `themes.family`, `themes.stage.light.name` or
  /// `themes.stage.dark.name` — to show `expected`. Polled: the Settings scene's `@Default`
  /// invalidates asynchronously, so an immediate read can still show the previous value.
  private func waitForLabel(
    _ app: XCUIApplication, _ id: String, toShow expected: String, timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let label = element(app, id)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if label.exists, text(of: label) == expected { return }
      usleep(150_000)
    }
    XCTFail(
      "\(id) shows '\(label.exists ? text(of: label) : "nothing")', expected '\(expected)'",
      file: file, line: line)
  }

  /// A tile in the Themes pane's grid: `family-<name>`, `light-<name>` or `dark-<name>`.
  private func tile(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    element(app, "settings.themes.\(id)")
  }

  /// Wait for the loading state of a theme list to clear, so the list has settled.
  private func waitForListToSettle(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let loading = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Loading themes")).firstMatch
    XCTAssertTrue(
      loading.waitForNonExistence(timeout: 5), "the theme list never settled", file: file,
      line: line)
  }

  /// Wait for the generated conf's theme to stop changing, and return it.
  private func waitForConfToSettle(timeout: TimeInterval = 5) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    var name = confTheme()
    var stableSince = Date()
    while Date() < deadline {
      usleep(100_000)
      let now = confTheme()
      if now != name {
        name = now
        stableSince = Date()
      } else if Date().timeIntervalSince(stableSince) >= 0.6 {
        return name
      }
    }
    return name
  }

  /// Choose Family, Light or Dark in the Themes pane's browser.
  private func browse(_ app: XCUIApplication, _ label: String) {
    let segment = element(app, "settings.themes.browse")
      .descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(segment.waitForExistence(timeout: 3), "the browser has no '\(label)' segment")
    segment.click()
  }

  /// Replace the Themes pane's search with `query`.
  private func search(_ app: XCUIApplication, _ query: String) {
    let field = element(app, "settings.themes.search")
    XCTAssertTrue(field.waitForExistence(timeout: 3), "the Themes pane has no search field")
    field.click()
    app.typeKey("a", modifierFlags: [.command])
    app.typeText(query)
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

  /// Settings ▸ Themes (#733) chooses a family, then one side alone. A family sets both themes and
  /// the stage and family label follow; a dark theme alone leaves the light one and makes the pair
  /// Custom. The appearance is Dark, so the generated config names the dark theme each time.
  func testAFamilySetsBothThemesAndChangingOneSideAloneShowsCustom() throws {
    let app = launchedApp()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")

    openThemesSettings(app)
    waitForLabel(app, "settings.themes.family", toShow: "Workroom")
    waitForLabel(app, "settings.themes.stage.light.name", toShow: "Workroom Light")
    waitForLabel(app, "settings.themes.stage.dark.name", toShow: "Workroom")

    browse(app, "Family")
    XCTAssertTrue(
      tile(app, "family-Workroom").waitForExistence(timeout: 3),
      "Families did not list the families")
    search(app, family)
    let target = tile(app, "family-\(family)")
    XCTAssertTrue(target.waitForExistence(timeout: 5), "'\(family)' is not among the families")
    target.click()
    XCTAssertEqual(
      waitForConfTheme(oneOf: [darkVariantFile]), darkVariantFile,
      "choosing '\(family)' did not reach the engine")
    waitForLabel(app, "settings.themes.family", toShow: family)
    waitForLabel(app, "settings.themes.stage.light.name", toShow: lightVariantFile)
    waitForLabel(app, "settings.themes.stage.dark.name", toShow: darkVariantFile)

    // The Dark stage window browses dark themes, and lists no family and no light theme.
    element(app, "settings.themes.stage.dark").click()
    search(app, "Nord")
    let nord = tile(app, "dark-Nord")
    XCTAssertTrue(nord.waitForExistence(timeout: 5), "'Nord' is not among the dark themes")
    XCTAssertFalse(tile(app, "family-\(family)").exists, "the dark themes listed a family")
    XCTAssertFalse(
      element(app, "settings.themes.note").exists,
      "the dark themes noted the other appearance while Dark is showing")
    nord.click()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Nord"]), "Nord", "choosing the dark theme 'Nord' didn't show")
    waitForLabel(app, "settings.themes.family", toShow: "Custom")
    waitForLabel(app, "settings.themes.stage.light.name", toShow: lightVariantFile)
    waitForLabel(app, "settings.themes.stage.dark.name", toShow: "Nord")
  }

  /// Browsing the side that isn't showing saves the choice without changing the generated config
  /// (#735). The appearance is Dark, so the light themes are the hidden side: they say so, a click
  /// there saves the light theme, and the engine keeps the dark theme it had.
  func testBrowsingTheHiddenSideSavesWithoutChangingTheGeneratedConfig() throws {
    let app = launchedApp()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")

    openThemesSettings(app)
    element(app, "settings.themes.stage.light").click()
    XCTAssertTrue(
      tile(app, "light-Workroom Light").waitForExistence(timeout: 3),
      "the Light stage window did not browse light themes")
    XCTAssertFalse(tile(app, "dark-Workroom").exists, "the light themes listed a dark one")

    let note = element(app, "settings.themes.note")
    XCTAssertTrue(note.waitForExistence(timeout: 3), "the light themes don't say they apply later")
    XCTAssertEqual(text(of: note), "Applies when the appearance is Light")

    search(app, lightVariantFile)
    let target = tile(app, "light-\(lightVariantFile)")
    XCTAssertTrue(target.waitForExistence(timeout: 5), "'\(lightVariantFile)' is not listed")
    target.click()

    // The positive signal first, so the unchanged config below can't be read before anything
    // happened.
    waitForLabel(app, "settings.themes.stage.light.name", toShow: lightVariantFile)
    waitForLabel(app, "settings.themes.family", toShow: "Custom")
    waitForLabel(app, "settings.themes.stage.dark.name", toShow: "Workroom")
    usleep(1_000_000)
    XCTAssertEqual(
      confTheme(), "Workroom",
      "choosing a hidden light theme changed the generated config, so the screen repainted")
  }

  /// The stage says when a side fell back. Your own dark file called `Ayu Light` puts the stored
  /// light theme on the wrong side, so Workroom Light shows in its place: the Light window keeps the
  /// stored name and notes the fallback, the Dark window notes nothing, and choosing a real light
  /// theme clears the note.
  func testTheStageSaysWhenAThemeFellBack() throws {
    let app = launchedApp(withUserThemes: true, lightTheme: "Ayu Light")
    openThemesSettings(app, family: "Custom")
    waitForLabel(app, "settings.themes.stage.light.name", toShow: "Ayu Light")

    let note = element(app, "settings.themes.fallback.light")
    XCTAssertTrue(note.waitForExistence(timeout: 5), "the Light window doesn't say it fell back")
    XCTAssertEqual(text(of: note), "Not a light theme: showing Workroom Light")
    XCTAssertFalse(
      element(app, "settings.themes.fallback.dark").exists,
      "the Dark window says it fell back, although Workroom is a dark theme")

    element(app, "settings.themes.stage.light").click()
    search(app, lightVariantFile)
    let target = tile(app, "light-\(lightVariantFile)")
    XCTAssertTrue(target.waitForExistence(timeout: 5), "'\(lightVariantFile)' is not listed")
    target.click()
    waitForLabel(app, "settings.themes.stage.light.name", toShow: lightVariantFile)
    XCTAssertTrue(
      note.waitForNonExistence(timeout: 5), "the fallback note stayed after choosing a light theme")
  }

  /// The Settings ▸ Themes grid moves by keyboard and applies each theme live, as the ⌘⇧K picker does:
  /// → and ← step one tile, ↓ and ↑ one row (two or more tiles at this width), and a burst of ↓ keeps
  /// the chosen tile on screen under the pinned browser. The appearance is Dark and the Dark grid
  /// opens on Workroom, its first tile, so every move shows in the generated config.
  func testTheThemesGridMovesByKeyboardAndAppliesEachTheme() throws {
    let app = launchedApp()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")
    openThemesSettings(app)
    waitForListToSettle(app)
    let start = tile(app, "dark-Workroom")
    XCTAssertTrue(start.waitForExistence(timeout: 5), "the Dark grid has no Workroom tile")
    start.click()  // gives the grid focus; Workroom is already chosen

    app.typeKey(.rightArrow, modifierFlags: [])
    let next = waitForConfToSettle()
    XCTAssertNotNil(next)
    XCTAssertNotEqual(next, "Workroom", "→ didn't choose the next theme")
    app.typeKey(.leftArrow, modifierFlags: [])
    XCTAssertEqual(waitForConfToSettle(), "Workroom", "← didn't go back to Workroom")

    app.typeKey(.downArrow, modifierFlags: [])
    let below = waitForConfToSettle()
    XCTAssertNotNil(below)
    XCTAssertNotEqual(below, "Workroom", "↓ didn't move")
    XCTAssertNotEqual(below, next, "↓ moved one tile, not a row")
    app.typeKey(.upArrow, modifierFlags: [])
    XCTAssertEqual(waitForConfToSettle(), "Workroom", "↑ didn't go back up a row")

    // A burst, as a held key sends: the chosen tile stays wholly in the grid, under the browser.
    app.typeText(String(repeating: "\u{F701}", count: 8))
    guard let name = waitForConfToSettle(), name != "Workroom" else {
      return XCTFail("the burst of ↓ didn't move")
    }
    let chosen = tile(app, "dark-\(name)")
    XCTAssertTrue(chosen.waitForExistence(timeout: 3), "no tile for '\(name)'")
    let top = element(app, "settings.themes.search").frame.maxY
    let bottom = app.windows["Settings"].frame.maxY
    XCTAssertGreaterThanOrEqual(chosen.frame.minY, top, "'\(name)' is under the browser")
    XCTAssertLessThanOrEqual(chosen.frame.maxY, bottom + 1, "'\(name)' is below the window")
  }

  /// Quick arrow presses keep the highlighted theme on screen. Each press applies a theme and
  /// repaints the picker, and an animated scroll that the next press interrupted used to stop short,
  /// leaving the highlight below the bottom edge. The highlight is the theme the generated config
  /// names, so this finds that row and checks it lies wholly inside the list, under the tabs.
  ///
  /// A guard, not a reproduction: in the VM the old animated scroll kept up too, so this passed
  /// against it. The failure needed a real machine's timing.
  func testQuickArrowPressesKeepTheHighlightedThemeOnScreen() throws {
    let app = launchedApp()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")
    openPicker(app)
    XCTAssertTrue(
      element(app, "theme-dark-Workroom").waitForExistence(timeout: 5),
      "⌘⇧K did not open the picker on the Dark tab")
    waitForListToSettle(app)

    @discardableResult
    func assertHighlightOnScreen(
      after presses: String, movedFrom previous: String?, file: StaticString = #filePath,
      line: UInt = #line
    ) -> String? {
      // Let the last press's theme reach the conf.
      guard let name = waitForConfToSettle() else {
        XCTFail("no theme in the conf", file: file, line: line)
        return nil
      }
      XCTAssertNotEqual(name, previous, "\(presses) moved nothing", file: file, line: line)
      let row = element(app, "theme-dark-\(name)")
      XCTAssertTrue(
        row.waitForExistence(timeout: 3), "no row for '\(name)'", file: file, line: line)
      let list = app.popovers.firstMatch.frame
      let top = element(app, "theme-picker.tab.dark").frame.maxY
      XCTAssertGreaterThanOrEqual(
        row.frame.minY, top - 1, "after \(presses), '\(name)' is above the list", file: file,
        line: line)
      XCTAssertLessThanOrEqual(
        row.frame.maxY, list.maxY + 1, "after \(presses), '\(name)' is below the list",
        file: file, line: line)
      return name
    }

    // One `typeText` burst, not a `typeKey` loop: `typeKey` waits for the app to go idle between
    // presses, which lets each scroll finish and hides the bug. The arrow keys' function-key
    // characters arrive back to back, as a held or quickly repeated key does.
    app.typeText(String(repeating: "\u{F701}", count: 14))
    let down = assertHighlightOnScreen(after: "14 quick ↓", movedFrom: "Workroom")
    app.typeText(String(repeating: "\u{F700}", count: 9))
    assertHighlightOnScreen(after: "9 quick ↑", movedFrom: down)
  }

  /// Your own theme files in the Light and Dark lists (#737). `-WorkroomUITestUserThemes 1` has the
  /// app write `UITestFixture.sampleUserThemes` into a scratch folder of its own (this sandboxed runner
  /// can't create files under `/tmp`), never the real `~/.config`: a dark `My Night`, a dark
  /// `Ayu Light` and an unparseable `Broken Mine`. The appearance is Dark, so ⌘⇧K opens the Dark tab:
  ///
  /// - a dark file of yours is on the Dark tab, labelled as yours, and choosing it reaches the
  ///   generated config;
  /// - a dark file called `Ayu Light` replaces that light theme, so it's on the Dark tab, labelled,
  ///   and the Ayu family is hidden from the Family tab while its neighbours stay;
  /// - a file that doesn't parse is listed nowhere.
  func testYourOwnThemeFilesAreListedOnTheirSideAndLabelled() throws {
    let app = launchedApp(withUserThemes: true)
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")

    openPicker(app)
    XCTAssertTrue(
      element(app, "theme-dark-Workroom").waitForExistence(timeout: 5),
      "⌘⇧K did not open the picker on the Dark tab")

    // The Family tab: Ayu is hidden while its light theme is a dark file; its neighbours stay.
    // Searched, so the rows asserted on are materialised however long the list is.
    element(app, "theme-picker.tab.family").click()
    app.typeText("Atom One")
    XCTAssertTrue(
      row(app, "Atom One").waitForExistence(timeout: 3), "the Family tab did not list Atom One")
    app.typeKey("a", modifierFlags: [.command])
    app.typeText("Ayu")
    XCTAssertTrue(
      row(app, "Atom One").waitForNonExistence(timeout: 3), "the search didn't apply")
    XCTAssertFalse(
      row(app, "Ayu").exists, "Ayu is offered although its light theme is a dark file of yours")

    // The Dark tab, on the same search: the replacement moved here, labelled; the bundled Ayu
    // Mirage isn't labelled.
    element(app, "theme-picker.tab.dark").click()
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

  // MARK: Favourites

  /// The terminal panes of the fixture workroom, to tell whether ⌘D split one.
  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func assertPaneCount(
    _ app: XCUIApplication, is expected: Int, _ message: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let reached = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", expected), object: panes(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [reached], timeout: 6), .completed, message, file: file, line: line)
  }

  /// Favourites in the ⌘⇧K picker: ⌘D stars the highlighted theme and ⌘F lists only favourites,
  /// neither reaching the workroom behind (⌘D is Split Right there, and still is once the picker
  /// closes). A row unstarred with the filter on stays until the list is rebuilt; a tab with no
  /// favourites says so and offers every theme back.
  func testThePickerStarsTheHighlightedThemeAndFiltersToFavourites() throws {
    let app = launchedApp()
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")
    XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 10), "no terminal pane")
    openPicker(app)
    let workroom = element(app, "theme-dark-Workroom")
    XCTAssertTrue(workroom.waitForExistence(timeout: 5), "⌘⇧K did not open on the Dark tab")
    waitForListToSettle(app)

    // ⌘D stars the highlighted row, Workroom, the current choice.
    app.typeKey("d", modifierFlags: .command)
    let star = element(app, "theme-dark-Workroom-star")
    XCTAssertTrue(star.waitForExistence(timeout: 3), "the Workroom row has no star")
    XCTAssertTrue(waitFor(star, selected: true), "⌘D didn't star the highlighted theme")
    XCTAssertTrue(app.popovers.firstMatch.exists, "⌘D closed the picker")
    assertPaneCount(app, is: 1, "⌘D in the picker split the workroom behind it")

    // ⌘F: only favourites.
    let neighbour = element(app, "theme-dark-Night Owl")
    app.typeText("Owl")
    XCTAssertTrue(neighbour.waitForExistence(timeout: 3), "the search didn't list Night Owl")
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(.delete, modifierFlags: [])
    app.typeKey("f", modifierFlags: .command)
    let filter = element(app, "theme-picker.favourites")
    XCTAssertTrue(waitFor(filter, selected: true), "⌘F didn't turn the favourites filter on")
    XCTAssertFalse(
      findBar(app).exists, "⌘F in the picker opened Find in the workroom behind it")
    XCTAssertTrue(workroom.waitForExistence(timeout: 3), "the favourite isn't listed")
    app.typeText("Owl")
    let noMatch = element(app, "theme-picker.empty.title")
    XCTAssertTrue(noMatch.waitForExistence(timeout: 3), "a search no favourite matches is blank")
    XCTAssertEqual(text(of: noMatch), "No favourites match “Owl”")
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(.delete, modifierFlags: [])

    // Unstarred with the filter on: still listed, until the tab changes.
    XCTAssertTrue(workroom.waitForExistence(timeout: 3))
    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(waitFor(star, selected: false), "⌘D didn't unstar the highlighted theme")
    XCTAssertTrue(workroom.exists, "the unstarred row vanished at once")
    element(app, "theme-picker.tab.light").click()
    element(app, "theme-picker.tab.dark").click()
    let empty = element(app, "theme-picker.empty.title")
    XCTAssertTrue(empty.waitForExistence(timeout: 3), "a tab with no favourites is blank")
    XCTAssertEqual(text(of: empty), "No favourite dark themes yet")
    XCTAssertFalse(workroom.exists, "the unstarred row outlived the rebuild")

    element(app, "theme-picker.empty.showAll").click()
    XCTAssertTrue(waitFor(filter, selected: false), "Show All Themes left the filter on")
    XCTAssertTrue(workroom.waitForExistence(timeout: 3), "every theme isn't listed again")

    // Closed, ⌘D is Split Right again.
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 3), "Esc didn't close it")
    app.typeKey("d", modifierFlags: .command)
    assertPaneCount(app, is: 2, "⌘D no longer splits once the picker is closed")
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(
      findBar(app).waitForExistence(timeout: 3), "⌘F no longer opens Find once the picker is closed"
    )
  }

  /// The terminal's Find bar's field, which ⌘F opens outside a theme list. Its match count, the
  /// bar's one identifier, is empty text until there's a search, so it isn't in the tree to find.
  private func findBar(_ app: XCUIApplication) -> XCUIElement {
    app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Find")).firstMatch
  }

  /// Favourites in Settings ▸ Themes, with one starred at launch: the filter is the picker's own
  /// setting, the grid starts on a favourite without applying it, a tile's star unstars it without
  /// choosing it, a tab with no favourites says so, the context menu and ⌘D star one, and ⌘D and ⌘F
  /// stay in Settings.
  func testSettingsSharesTheFilterAndStarsFromTheTile() throws {
    let app = launchedApp(favouriteThemes: ["Night Owl"])
    XCTAssertEqual(
      waitForConfTheme(oneOf: ["Workroom"]), "Workroom", "the fixture's dark theme isn't showing")
    XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 10), "no terminal pane")

    // Turned on in the picker…
    openPicker(app)
    XCTAssertTrue(element(app, "theme-dark-Workroom").waitForExistence(timeout: 5))
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(waitFor(element(app, "theme-picker.favourites"), selected: true))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 3))

    // …it's on in Settings.
    openThemesSettings(app)
    waitForListToSettle(app)
    let filter = element(app, "settings.themes.favourites")
    XCTAssertTrue(waitFor(filter, selected: true), "Settings doesn't share the picker's filter")
    let nightOwl = tile(app, "dark-Night Owl")
    let workroom = tile(app, "dark-Workroom")
    XCTAssertTrue(nightOwl.waitForExistence(timeout: 3), "the favourite has no tile")
    XCTAssertFalse(workroom.exists, "a theme that isn't a favourite is listed")

    // Workroom, the current choice, isn't a favourite: the grid starts on Night Owl without
    // applying it.
    XCTAssertEqual(waitForConfToSettle(), "Workroom", "opening the filtered grid applied a theme")

    // The tile's star unstars it without choosing it; the tile stays until the grid is rebuilt.
    let star = element(app, "settings.themes.dark-Night Owl-star")
    XCTAssertTrue(waitFor(star, selected: true), "the favourite's star isn't filled")
    star.click()
    XCTAssertTrue(waitFor(star, selected: false), "clicking the star didn't unstar it")
    XCTAssertTrue(nightOwl.exists, "the unstarred tile vanished at once")
    XCTAssertEqual(waitForConfToSettle(), "Workroom", "clicking the star chose the theme")

    // Rebuilt, with no favourites left on Dark.
    browse(app, "Light")
    browse(app, "Dark")
    let empty = element(app, "settings.themes.empty.title")
    XCTAssertTrue(empty.waitForExistence(timeout: 3), "a tab with no favourites is blank")
    XCTAssertEqual(text(of: empty), "No favourite dark themes yet")
    XCTAssertFalse(nightOwl.exists, "the unstarred tile outlived the rebuild")
    element(app, "settings.themes.empty.showAll").click()
    XCTAssertTrue(waitFor(filter, selected: false), "Show All Themes left the filter on")
    XCTAssertTrue(workroom.waitForExistence(timeout: 3), "every theme isn't listed again")

    // ⌘D stars the current choice, and splits nothing in the main window…
    workroom.click()
    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(
      waitFor(element(app, "settings.themes.dark-Workroom-star"), selected: true),
      "⌘D didn't star the current theme")
    assertPaneCount(app, is: 1, "⌘D in Settings split the workroom")

    // …and the filter button is ⌘F's too.
    filter.click()
    XCTAssertTrue(waitFor(filter, selected: true), "the filter button didn't turn the filter on")
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(waitFor(filter, selected: false), "⌘F didn't turn the filter off in Settings")

    // …and the context menu stars a tile. Searched, so the lazy grid has made its tile.
    search(app, "Night Owl")
    XCTAssertTrue(nightOwl.waitForExistence(timeout: 3), "the search didn't list Night Owl")
    nightOwl.rightClick()
    let add = app.menuItems["Add to Favourites"]
    XCTAssertTrue(add.waitForExistence(timeout: 3), "the tile's menu can't add it to favourites")
    add.click()
    XCTAssertTrue(waitFor(star, selected: true), "Add to Favourites didn't star it")
  }

  /// Polls `element` until its selected state is `selected`: the Settings scene's `@Default`
  /// invalidates asynchronously. An unstarred star that isn't hovered is hidden, and may leave the
  /// accessibility tree, so gone counts as not selected.
  private func waitFor(_ element: XCUIElement, selected: Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.exists ? element.isSelected == selected : !selected { return true }
      usleep(100_000)
    }
    return false
  }
}
