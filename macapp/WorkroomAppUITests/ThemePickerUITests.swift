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
