import Defaults
import XCTest

@testable import Workroom

/// The shared UI-preference keys — inspector visibility, the inspector's active section, and the diff
/// viewer's layout — from both sides: the fixture seam that pins them for XCUITest
/// (`UITestFixture.applyFixtureDefaults`), and the store paths that read or persist them
/// (`AppStore.inspectorIsVisible`, the `activeInspectorSection` didSet).
///
/// **This class is the whole unit suite's single writer of these raw keys, and that is the point.**
/// `-parallel-testing` gives each worker its own host process but ONE UserDefaults domain, and XCTest
/// parallelises per *class* — so keeping every write in one class makes them sequential by
/// construction, where two classes writing them can interleave inside each other's bodies. That is not
/// hypothetical: with the assertions split across two classes, `inspector.activeSection` raced (a
/// `.files` write landing between this seam's write and its read failed
/// `testUnknownSectionArgumentFallsBackToChanges` about once in five 6-class parallel iterations).
/// Anything elsewhere that needs one of these prefs pinned uses a per-store override instead —
/// `AppStore.inspectorVisibleOverrideForTesting` / `.isolatesInspectorSectionForTesting`.
///
/// Why the fixture seam needs testing at all: the XCUITests can't set these keys themselves. A launch
/// argument lands in the argument domain as a **string**, `Defaults` reads a `Bool` key with `as? Bool`
/// (which fails on a string and returns the key default, `false`), and the argument domain then shadows
/// both the persisted value and every later write — so `-showNotificationsInspector 1` pins the pane
/// shut for the whole run instead of forcing it open.
///
/// Nothing in the app notices if that seam regresses — the failure surfaces only as XCUITests that
/// can't find the panel they were about to assert on, one build later. That is not theoretical either:
/// the diff-mode half was missing, and a Dev domain left on side-by-side quietly turned five diff UI
/// tests red (they assert on `diff.line`, which only the unified renderer emits).
final class SharedPrefDefaultsTests: XCTestCase {

  private let sectionArgKey = "WorkroomUITestInspectorSection"
  private let diffModeArgKey = "WorkroomUITestDiffViewMode"
  private let visibleKey = "showNotificationsInspector"
  private let activeSectionKey = "inspector.activeSection"
  private let diffModeKey = "diffViewMode"
  private let sidebarVisibleKey = "sidebar.visible"

  /// Every raw key this test writes, saved/restored so it never leaks into the real Dev defaults
  /// (the unit tests run in the app's own UserDefaults domain — cf. `ActivitySectionTests`).
  ///
  /// `WorkroomUITestFixture` is deliberately NOT among them: fixture-mode-ness is passed to
  /// `applyFixtureDefaults(active:)` instead of written, because ~47 production sites branch on that
  /// key and the parallel test workers share one on-disk defaults domain — holding it true for the
  /// length of a body here silently early-returns `AppStore.handleRootBranchChange` in whichever
  /// unrelated class happens to be running beside it. The keys that remain are written by this class
  /// alone (see above), so nothing else can see them mid-flight.
  private var keys: [String] {
    [sectionArgKey, diffModeArgKey, visibleKey, activeSectionKey, diffModeKey, sidebarVisibleKey]
  }
  private var saved: [String: Any?] = [:]

  override func setUp() {
    super.setUp()
    for key in keys {
      saved[key] = UserDefaults.standard.object(forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  override func tearDown() {
    for (key, value) in saved {
      if let value {
        UserDefaults.standard.set(value, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    saved = [:]
    super.tearDown()
  }

  // MARK: shipped defaults

  /// The shipped defaults, with the keys absent (as they are until the user first touches them): the
  /// pane starts closed, on Changes. `setUp` removed both, so this asserts the `Key`s' own defaults.
  func testTheShippedDefaultsAreAClosedPaneOnChanges() {
    XCTAssertFalse(Defaults[.showInspector], "the inspector starts closed until the user opens it")
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes)
  }

  /// The sidebar's own shipped default, kept separate from the inspector's above since it's the
  /// opposite polarity — the projects sidebar starts SHOWN, unlike the inspector.
  func testTheSidebarShippedDefaultIsShown() {
    XCTAssertTrue(Defaults[.sidebarVisible], "the projects sidebar starts open")
  }

  // MARK: sidebar visibility, as the store persists it

  /// A fresh store seeds from whatever was last persisted, not the shipped default — the same
  /// contract `showInspector`/`activeInspectorSection` already have.
  ///
  /// The write-back half (`didSet { if persistsSidebarPrefs { … } }`) has no test here, matching
  /// `collapsedProjects`/`workroomTabOrder`/`sidebarSelection` — the other properties gated the same
  /// way — because this suite runs hosted inside the real app (`TEST_HOST`): the app's own launch
  /// path opens a real window and registers its `AppStore` as `WindowRegistry.lastActiveStore` before
  /// any test body runs, so a freshly-constructed `AppStore()` here is never the last-active store and
  /// `persistsSidebarPrefs` is always false for it. Asserting the write would test a should-never-fire
  /// branch, not the real gate.
  @MainActor
  func testAStoreSeedsSidebarVisibilityFromThePersistedSetting() {
    Defaults[.sidebarVisible] = false
    XCTAssertFalse(
      AppStore().sidebarVisible, "a new store must not silently reopen a closed sidebar")

    Defaults[.sidebarVisible] = true
    XCTAssertTrue(AppStore().sidebarVisible, "and must reopen a persisted-visible sidebar")
  }

  // MARK: inspector visibility, as the store reads it

  /// `AppStore.inspectorIsVisible` gates the live-History triggers — `handleRootBranchChange` and the
  /// on-refocus `refreshHistoryIfActive` only repaint the log when the pane is actually open.
  ///
  /// It needs its own test for the same reason `resolveConfirmOnClose` does: the classes that drive
  /// those triggers pin visibility per store rather than writing this key, so nothing else reaches the
  /// `Defaults` side any more — hard-code the resolver `true` and the whole suite stays green while
  /// History quietly starts reading VCS behind a closed pane. Driven through the pure static so the
  /// write window stays a statement wide.
  func testVisibilityFallsBackToTheStoredSetting() {
    Defaults[.showInspector] = true
    XCTAssertTrue(AppStore.resolveInspectorVisible(override: nil), "open → History may refresh")

    Defaults[.showInspector] = false
    XCTAssertFalse(AppStore.resolveInspectorVisible(override: nil), "closed → it must not")
  }

  /// …and a pinned override wins over the setting in both directions, which is what the History
  /// live-refresh classes depend on.
  func testTheVisibilityOverrideWinsOverTheStoredSetting() {
    Defaults[.showInspector] = true
    XCTAssertFalse(AppStore.resolveInspectorVisible(override: false))

    Defaults[.showInspector] = false
    XCTAssertTrue(AppStore.resolveInspectorVisible(override: true))
  }

  /// The seam has to reach the store's own read, not just the static: an unpinned store answers from
  /// the setting, a pinned one ignores it.
  @MainActor
  func testAStoreReadsTheOverrideThenTheSetting() {
    Defaults[.showInspector] = true
    let store = AppStore()
    XCTAssertTrue(store.inspectorIsVisible)

    store.inspectorVisibleOverrideForTesting = false
    XCTAssertFalse(store.inspectorIsVisible, "a pinned store ignores the shared setting")
  }

  // MARK: the active section, as the store persists it

  /// Picking a section must still persist it — the pane reopens where you left it. Guarded because
  /// `isolatesInspectorSectionForTesting` suppresses that write (the History classes set it so their
  /// picked section doesn't leak into a store another worker is building): widen the suppression to
  /// always-on and the section silently stops persisting with the suite still green.
  @MainActor
  func testAStoresSectionChangePersistsUnlessTheStoreIsIsolatedForTesting() {
    Defaults[.activeInspectorSection] = .changes
    AppStore().activeInspectorSection = .files
    XCTAssertEqual(Defaults[.activeInspectorSection], .files, "a picked section must be remembered")

    Defaults[.activeInspectorSection] = .changes
    let isolated = AppStore()
    isolated.isolatesInspectorSectionForTesting = true
    isolated.activeInspectorSection = .files
    XCTAssertEqual(isolated.activeInspectorSection, .files, "the store still moves…")
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes, "…but writes nothing shared")
  }

  // MARK: fixture seam — inspector

  /// Fixture mode with no section argument: the pane opens on Changes — the state most XCUITests
  /// assume, whatever the developer's machine last persisted.
  func testFixtureModeOpensTheInspectorOnChanges() {
    Defaults[.showInspector] = false
    Defaults[.activeInspectorSection] = .files

    UITestFixture.applyFixtureDefaults(active: true)

    XCTAssertTrue(Defaults[.showInspector], "fixture mode should open the inspector pane")
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes, "default section is Changes")
  }

  /// `-WorkroomUITestInspectorSection <raw>` picks the pane. The flag is read with
  /// `UserDefaults.string(forKey:)`, which is exactly what makes a launch argument usable here.
  func testSectionArgumentSelectsThePane() {
    UserDefaults.standard.set("files", forKey: sectionArgKey)

    UITestFixture.applyFixtureDefaults(active: true)

    XCTAssertTrue(Defaults[.showInspector])
    XCTAssertEqual(Defaults[.activeInspectorSection], .files)
  }

  /// An unrecognised section falls back to Changes rather than leaving the pane on whatever was
  /// persisted — a typo'd flag must still produce a deterministic launch.
  func testUnknownSectionArgumentFallsBackToChanges() {
    UserDefaults.standard.set("bogus", forKey: sectionArgKey)
    Defaults[.activeInspectorSection] = .files

    UITestFixture.applyFixtureDefaults(active: true)

    XCTAssertEqual(UITestFixture.inspectorSection, .changes)
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes)
  }

  // MARK: fixture seam — diff view mode

  /// Fixture mode with no diff-mode argument pins **unified** — the shipped default — over a persisted
  /// side-by-side choice. This is the assertion that would have caught the red `diff.line` tests: they
  /// say nothing about the layout, so the fixture must not let the developer's Settings pick it.
  func testFixtureModeForcesUnifiedOverAPersistedSideBySide() {
    Defaults[.diffViewMode] = .sideBySide

    UITestFixture.applyFixtureDefaults(active: true)

    XCTAssertEqual(Defaults[.diffViewMode], .unified)
  }

  /// `-WorkroomUITestDiffViewMode sideBySide` opts a test into the two-column layout.
  func testDiffModeArgumentSelectsSideBySide() {
    UserDefaults.standard.set("sideBySide", forKey: diffModeArgKey)

    UITestFixture.applyFixtureDefaults(active: true)

    XCTAssertEqual(UITestFixture.diffViewMode, .sideBySide)
    XCTAssertEqual(Defaults[.diffViewMode], .sideBySide)
  }

  /// A typo'd layout falls back to unified rather than to whatever was persisted.
  func testUnknownDiffModeArgumentFallsBackToUnified() {
    UserDefaults.standard.set("bogus", forKey: diffModeArgKey)
    Defaults[.diffViewMode] = .sideBySide

    UITestFixture.applyFixtureDefaults(active: true)

    XCTAssertEqual(Defaults[.diffViewMode], .unified)
  }

  // MARK: fixture seam — production

  /// Inert outside fixture mode: a real user's persisted state must survive untouched — the inspector
  /// they closed, the section they left, and the diff layout they picked in Settings.
  func testDoesNothingWhenNotInFixtureMode() {
    Defaults[.showInspector] = false
    Defaults[.activeInspectorSection] = .files
    Defaults[.diffViewMode] = .sideBySide

    UITestFixture.applyFixtureDefaults(active: false)

    XCTAssertFalse(Defaults[.showInspector], "a normal launch keeps the user's closed pane")
    XCTAssertEqual(Defaults[.activeInspectorSection], .files, "and their active section")
    XCTAssertEqual(Defaults[.diffViewMode], .sideBySide, "and their diff layout")
  }
}
