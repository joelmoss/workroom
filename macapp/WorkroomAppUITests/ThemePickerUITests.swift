import XCTest

/// UI test for the **theme picker** (⌘⇧K) after the 27→58 family expansion.
///
/// This covers the one link in the chain that no unit test can reach. `ThemeServiceTests` proves the
/// registry and the bundled files agree, reading the bundle from the test host — but it never renders
/// a row, and it never proves a theme the user picks actually reaches the terminal engine. That path
/// runs through SwiftUI and then through a generated ghostty config, so only a UI test sees it.
///
/// **What "applied" means here.** Asserting a checkmark would only prove a `Defaults` write. Applying
/// a theme also rewrites `~/Library/Application Support/Workroom/ghostty.conf` with
/// `theme = "<variant file name>"` (`GhosttyApp.writeThemeConfig`), and the test process can read that
/// file — so the assertion is that the conf names the expected *file*, which proves registry lookup →
/// appearance-appropriate variant → the name handed to libghostty.
///
/// **Residual gap, deliberately not claimed:** nothing here proves ghostty *accepted* the file. The
/// engine exposes no error surface for an unresolvable `theme =`, so a bad file is indistinguishable
/// from a good one at this level. `themes/CHECKSUMS` is what pins the bytes instead.
///
/// The picker is a transient popover anchored to a toolbar button (`TrailingTitlebarBar`), not a sheet
/// and not a window — so it is queried through the app's descendants, and `app.sheets` staying empty is
/// part of what the dropdown test asserts.
///
/// The starting family comes from `-WorkroomUITestThemeFamily`, mirrored into `Defaults` by
/// `UITestFixture.applyFixtureDefaults`. That is app-side on purpose: `Defaults` is not isolated by a
/// throwaway `$HOME`, so a runner-side save/restore would be writing the developer's real preference.
///
/// Run with a real GUI login session — XCUITest can't drive a headless run, so this lives in the UI
/// scheme, excluded from `make app-test`. Scope it when iterating; the full UI suite is slow:
/// `xcodebuild … -only-testing:WorkroomAppUITests/ThemePickerUITests`
final class ThemePickerUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// A newly-bundled family — deliberately one of the 31 added, so this fails if the new files didn't
  /// make it into the built bundle. `Night Owl` also exercises the awkward shape: its variants are
  /// `Night Owl` / `Light Owl`, which share no common prefix, so a name-suffix assumption anywhere in
  /// the chain would break on it.
  private let family = "Night Owl"
  private let darkVariantFile = "Night Owl"
  private let lightVariantFile = "Light Owl"

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Start somewhere that is NOT the family under test, so a passing assertion can't be the
    // fixture's starting state.
    app.launchArguments += ["-WorkroomUITestThemeFamily", "Workroom"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// The app's generated conf, resolved against the **real** home.
  ///
  /// `FileManager.urls(for: .applicationSupportDirectory, …)` is wrong here and silently so: the
  /// XCUITest runner has its own container, so it answers
  /// `~/Library/Containers/com.developwithstyle.workroom.uitests.xctrunner/Data/Library/…` — a path
  /// the app never writes to. Every read returned nil and the assertion failed while the feature
  /// worked. `getpwuid` reports the real home because the sandbox doesn't rewrite passwd.
  private var generatedConfURL: URL {
    let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir)
    return URL(fileURLWithPath: realHome)
      .appendingPathComponent("Library/Application Support/Workroom/ghostty.conf")
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
    app.descendants(matching: .any)
      .matching(identifier: "theme-family-\(name)").firstMatch
  }

  /// The whole chain: a newly-bundled family is findable by search, its row renders, clicking it
  /// applies, and the generated conf names the variant file for the current appearance.
  func testANewlyBundledFamilyIsFindableAndReachesTheEngine() throws {
    let app = launchedApp()
    openPicker(app)

    // Search rather than scroll: with 58 rows the target may be far down the list, and searching is
    // also what a user does. The search field takes focus on open.
    app.typeText(family)

    let target = row(app, family)
    XCTAssertTrue(
      target.waitForExistence(timeout: 5),
      "'\(family)' did not appear in the picker — either its files are missing from the built bundle "
        + "or it is not registered in ThemeService.families")

    target.click()

    let applied = waitForConfTheme(oneOf: [darkVariantFile, lightVariantFile])
    XCTAssertNotNil(
      applied, "no theme line in the generated ghostty.conf after picking '\(family)'")
    XCTAssertTrue(
      [darkVariantFile, lightVariantFile].contains(applied),
      "the engine was handed '\(applied ?? "nil")' — expected '\(darkVariantFile)' (dark appearance) "
        + "or '\(lightVariantFile)' (light appearance) for the '\(family)' family")
  }

  /// The dropdown hangs off its own toolbar button, and clicking away closes it — the shape that makes
  /// a live preview possible at all. It used to be a `.sheet`, which was document-modal: AppKit rendered
  /// the whole window inactive behind it (traffic lights greyed, the sidebar's VCS dot badges orange →
  /// dull brown), and being anchored under the title bar it covered the content whose colours you were
  /// choosing.
  ///
  /// What this can and cannot see: XCUITest exposes no window key/main state and no pixels, so the
  /// *inactive rendering* itself isn't assertable here. What is assertable — and is what rules it out —
  /// is that the picker is a transient popover rather than a sheet: `app.sheets` stays empty, and a
  /// click elsewhere dismisses it, which no modal presentation does.
  func testTheDropdownHangsOffTheToolbarAndClosesOnAClickAway() throws {
    let app = launchedApp()

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
    let popover = app.popovers.firstMatch
    XCTAssertTrue(
      popover.waitForExistence(timeout: 5),
      "the button did not open the theme dropdown — button frame \(button.frame), hittable "
        + "\(button.isHittable), sheets \(app.sheets.count)")
    XCTAssertEqual(app.sheets.count, 0, "the picker came up as a sheet, not a dropdown")

    // Content really rendered, not just an empty popover. `Workroom` is the family the fixture starts on
    // and the list scrolls the selected family into view, so that row is materialised. The family used by
    // the other cases is row 33 of 58, and a `LazyVStack` never builds it until the search filters it in
    // — which is exactly what failed an earlier version of this test against working code.
    XCTAssertTrue(
      row(app, "Workroom").waitForExistence(timeout: 3), "the dropdown rendered no rows")

    // Click in the DETAIL area (0.6 across), not the leading 0.25 a previous version used: the sidebar
    // occupies up to 360pt at the leading edge, so a click there can land on a workroom row, change the
    // selection, and close the dropdown through the explicit selection handler — passing this test via a
    // different mechanism than the native outside-click dismissal it claims to prove.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8)).click()
    XCTAssertTrue(
      popover.waitForNonExistence(timeout: 5),
      "the dropdown survived a click elsewhere — it is not transient, so any other action leaves it "
        + "hanging over the app")
  }

  /// ⌘⇧K opens the dropdown AND closes it again.
  ///
  /// The second press is the load-bearing half. The command is a broadcast notification, and the handler
  /// toggles only if `store.hostWindow?.isKeyWindow` — so the shortcut can close an OPEN dropdown only
  /// because a popover doesn't take key from the window it hangs off. That is measured behaviour, not a
  /// documented guarantee, and an independent reviewer flagged the opposite as a P1 wedge (open it, then
  /// never able to close it by keyboard). This is the assertion that would catch it if AppKit ever
  /// changed its mind.
  func testTheShortcutOpensAndClosesTheDropdown() throws {
    let app = launchedApp()
    let popover = app.popovers.firstMatch

    openPicker(app)
    XCTAssertTrue(popover.waitForExistence(timeout: 5), "⌘⇧K did not open the dropdown")

    openPicker(app)
    XCTAssertTrue(
      popover.waitForNonExistence(timeout: 5),
      "⌘⇧K did not close the dropdown it had just opened — if the popover now takes key focus from its "
        + "window, the isKeyWindow guard in TrailingTitlebarBar rejects the toggle and the shortcut can "
        + "only ever open it")
  }

  /// Esc closes it. `ThemePicker` handles this itself (`.onExitCommand`) rather than trusting the host,
  /// because a popover's own cancel handling depends on a behaviour mode SwiftUI doesn't expose.
  func testEscapeClosesTheDropdown() throws {
    let app = launchedApp()
    let popover = app.popovers.firstMatch

    openPicker(app)
    XCTAssertTrue(popover.waitForExistence(timeout: 5))

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Esc must dismiss the dropdown")
  }

  /// A dialog raised by KEYBOARD closes the dropdown — the `hasModalPresentation` path in
  /// `TrailingTitlebarBar`.
  ///
  /// Driven with ⌘N rather than a menu click on purpose: a click anywhere outside would dismiss the
  /// popover natively, so a mouse-driven version of this test would pass without the handler existing.
  /// A keystroke sends no outside click, which is exactly why the handler has to exist — a dropdown left
  /// hanging over a modal is both confusing and unreachable past.
  func testAKeyboardRaisedDialogClosesTheDropdown() throws {
    let app = launchedApp()
    let popover = app.popovers.firstMatch

    openPicker(app)
    XCTAssertTrue(popover.waitForExistence(timeout: 5))

    app.typeKey("n", modifierFlags: [.command])  // New Workroom — sets store.activePicker
    XCTAssertTrue(
      popover.waitForNonExistence(timeout: 5),
      "a modal presentation must close the dropdown; without the hasModalPresentation handler a "
        + "keyboard-raised dialog leaves it hanging over the modal")

    app.typeKey(.escape, modifierFlags: [])  // leave no dialog up for the next case
  }

  /// Both of a new family's swatches render a **resolved** theme. A variant whose file doesn't resolve
  /// renders the grey fallback swatch, which is the visible symptom of a registry typo — and the one
  /// failure a bundle-reading unit test cannot see, because it happens in the view.
  ///
  /// Each swatch reports its own variant file name and resolution state through accessibility, so this
  /// names the two files rather than counting anonymous elements.
  ///
  /// Scoped to the family under test rather than all 58 rows: applying a theme rewrites the conf and
  /// force-reloads the engine, so walking the whole list would mean 58 of those round-trips in one
  /// test. Per-theme colour correctness is already asserted 116 times over by `SwitcherThemeSweepTests`.
  func testBothSwatchesOfANewFamilyResolve() throws {
    let app = launchedApp()
    openPicker(app)
    app.typeText(family)

    XCTAssertTrue(row(app, family).waitForExistence(timeout: 5))

    for variant in [darkVariantFile, lightVariantFile] {
      let resolved = app.descendants(matching: .any)
        .matching(identifier: "theme-swatch-\(variant)-resolved").firstMatch
      XCTAssertTrue(
        resolved.waitForExistence(timeout: 3),
        "the '\(variant)' swatch did not render as resolved — that file is missing from the bundle or "
          + "misnamed in ThemeService.families, so the row is drawing the grey fallback")

      let unresolved = app.descendants(matching: .any)
        .matching(identifier: "theme-swatch-\(variant)-unresolved").firstMatch
      XCTAssertFalse(unresolved.exists, "the '\(variant)' swatch rendered the fallback")
    }
  }
}
