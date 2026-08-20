import XCTest

/// The first-run onboarding wizard (issue #151).
///
/// Two groups: the override-driven walkthrough (deterministic, fast) and the persistence contract
/// itself — the acceptance criterion this feature exists for ("still shows next launch if closed
/// early; never shows again once finished"). Both run in fixture mode
/// (`-WorkroomUITestNoProjects 1` for a reliable zero-project state).
///
/// The persistence group seeds its starting `hasCompletedOnboarding` value via
/// `-WorkroomUITestOnboardingSeed true|false`, written FROM INSIDE the app itself by
/// `applyFixtureDefaults` — the same pattern every other fixture pin already uses. An external
/// `defaults write` from the TEST process (confirmed via its own readback) was tried first and
/// empirically does NOT reliably reach a freshly xcodebuild-test-launched app's own `UserDefaults`
/// read moments later — some cross-process cfprefsd domain quirk specific to that launch path, not
/// a production bug; the in-app seed sidesteps it entirely. `-WorkroomUITestOnboardingRealGate 1`
/// (no seed) is what the SECOND launch of each relaunch pair uses, so it reads whatever the first
/// launch's real, running app process persisted — ordinary same-app cross-launch persistence.
///
/// A genuinely isolated `HOME` (non-fixture mode) was tried first too, for a reliable zero-project
/// state without the fixture, and also empirically doesn't work: `XCUIApplication.launchEnvironment`'s
/// `HOME` override isn't reliably seen by the bundled CLI subprocess a GUI-launched app spawns, so it
/// kept reading the real `~/.config/workroom/config.json` instead of an isolated one.
///
/// All wizard element queries are scoped through the onboarding window element, not `app` directly —
/// the main window's sidebar has its own "Add Project" empty-state button (`ProjectSidebar.swift`)
/// with the same accessible label, so an unscoped `app.buttons["Add Project"]` is ambiguous while
/// both windows are open.
///
/// None of these tests touch the developer's real `~/.config/workroom/config.json` or CLI: fixture
/// mode's `AppStore.addProject` simulates success locally instead of shelling out (see its doc
/// comment) — an earlier draft of `testAddingAProjectAdvancesToDone` didn't have that guard and
/// genuinely registered temp-directory projects in the real config on every run.
final class OnboardingUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// `addTeardownBlock` guarantees `terminate()` even when the test fails partway — without it, a
  /// failed assertion mid-test leaves the app running, and the NEXT test's `XCUIApplication().launch()`
  /// just re-activates that leftover instance (with its OLD launch arguments/state) instead of
  /// starting fresh, cascading one failure into every test that runs after it in the same suite.
  private func launchedApp(extraArgs: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-WorkroomUITestNoProjects", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extraArgs
    app.launch()
    addTeardownBlock { app.terminate() }
    return app
  }

  // MARK: Override-driven walkthrough

  /// Walks Welcome → Tour → skip Add Project → Done → Get Started, forced via the override so it's
  /// independent of the real gate/Defaults state.
  func testWalkthroughSkippingAddProjectClosesTheWindow() {
    let app = launchedApp(extraArgs: ["-WorkroomUITestOnboarding", "show"])
    let window = app.windows["onboarding.window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10), "onboarding window should open")

    window.buttons["Next"].click()  // welcome -> tour
    window.buttons["Next"].click()  // tour -> addProject
    window.buttons["Skip"].click()  // addProject -> done
    XCTAssertTrue(window.buttons["Get Started"].waitForExistence(timeout: 4))
    window.buttons["Get Started"].click()

    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: window)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: 4), .completed, "window should close on Get Started")
  }

  /// Walks to the Add Project step and adds a project, asserting auto-advance to Done — the success
  /// path of `OnboardingWindow.handleAdd`. In fixture mode, `AppStore.addProject` simulates success
  /// locally (see its doc comment) rather than calling the real CLI, so this never touches the
  /// developer's actual `~/.config/workroom/config.json` — no real directory is created either, so
  /// there's nothing on disk to clean up.
  func testAddingAProjectAdvancesToDone() throws {
    let app = launchedApp(extraArgs: ["-WorkroomUITestOnboarding", "show"])
    let window = app.windows["onboarding.window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))

    window.buttons["Next"].click()  // welcome -> tour
    window.buttons["Next"].click()  // tour -> addProject

    let projectDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-onboarding-uitest-\(UUID().uuidString)", isDirectory: true)

    let pathField = window.textFields["addProject.pathField"]
    XCTAssertTrue(pathField.waitForExistence(timeout: 4))
    window.radioButtons["Create new directory…"].click()
    pathField.click()
    pathField.typeText(projectDir.path)

    let addButton = window.buttons["Add Project"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 4))
    XCTAssertTrue(addButton.isEnabled, "a valid create-mode path should enable Add Project")
    addButton.click()

    XCTAssertTrue(
      window.buttons["Get Started"].waitForExistence(timeout: 10), "should auto-advance to Done")
  }

  // MARK: Persistence (the acceptance criterion)

  /// First launch of a relaunch pair: seed `hasCompletedOnboarding` to a known `false` from inside
  /// the app itself.
  private func launchedFreshRealGateApp() -> XCUIApplication {
    launchedApp(extraArgs: ["-WorkroomUITestOnboardingSeed", "false"])
  }

  /// Second launch of a relaunch pair: no seed, so it reads whatever the first launch left behind —
  /// `-WorkroomUITestOnboardingRealGate 1` only stops the generic fixture pin from overwriting it.
  private func relaunchedRealGateApp() -> XCUIApplication {
    launchedApp(extraArgs: ["-WorkroomUITestOnboardingRealGate", "1"])
  }

  /// Closing the wizard before it reaches Done leaves the completion flag unset, so it reopens on
  /// the next launch — the "still show again if not finished" half of the contract.
  func testClosingEarlyReopensOnNextLaunch() throws {
    let app = launchedFreshRealGateApp()
    let window = app.windows["onboarding.window"]
    XCTAssertTrue(
      window.waitForExistence(timeout: 10),
      "zero projects + seeded-false flag should show onboarding")
    app.terminate()

    let relaunched = relaunchedRealGateApp()
    XCTAssertTrue(
      relaunched.windows["onboarding.window"].waitForExistence(timeout: 10),
      "closing before Done should leave the wizard showing again next launch")
  }

  /// Reaching Done (by any path) sets the flag on entry, so it does NOT reopen on the next launch —
  /// the "never shows again once finished" half of the contract.
  func testReachingDoneNeverReopens() throws {
    let app = launchedFreshRealGateApp()
    let window = app.windows["onboarding.window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    window.buttons["Next"].click()  // welcome -> tour
    window.buttons["Next"].click()  // tour -> addProject
    window.buttons["Skip"].click()  // addProject -> done (sets the flag on entry)
    XCTAssertTrue(window.buttons["Get Started"].waitForExistence(timeout: 4))
    app.terminate()  // closed via terminate, NOT the Get Started button — flag must already be set

    let relaunched = relaunchedRealGateApp()
    XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
    XCTAssertFalse(
      relaunched.windows["onboarding.window"].waitForExistence(timeout: 4),
      "reaching Done should mark onboarding complete regardless of how the window was later closed")
  }
}
