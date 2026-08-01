import XCTest

/// UI tests for the VCS toolbar: its placement above the Changes header, the states its sync segment
/// renders, and the button→engine seam.
///
/// **Every test runs against BOTH backends.** This is an abstract base; `VCSToolbarGitUITests` and
/// `VCSToolbarJJUITests` are the two concrete suites, and the only difference between them is the fixture
/// project's declared VCS and therefore the vocabulary the branch segment uses. Parity is deliberate — the
/// toolbar is one code path with two wordings, and the one defect this structure exists to catch (a jj
/// project captioned "Current Branch") was invisible precisely because the suite only ever ran the git
/// shape. Where a backend genuinely differs, the expectation comes from `expectedRefNoun` rather than a
/// separate test, so neither backend can quietly lose coverage the other has.
///
/// Remote state is SEEDED via `-WorkroomUITestSyncState` (see `UITestFixture.remoteState`) because the
/// fixture's paths aren't real repos — a live read resolves to "No repository", which is a correct but
/// uninteresting state. The engine's own correctness against real repos is `VCSRemoteIntegrationTests`;
/// what only this tier can see is whether the rendered control does what it says.
///
/// **The jj suite needs a real `jj` ≥ 0.43 on PATH.** A jj project's remote actions are gated on BOTH tool
/// floors (a colocated jj repo drives git underneath — see `VCSToolVersions`), so on a machine with jj
/// missing or too old the sync segment correctly disables itself and the state tests fail. That's a true
/// dependency of testing a jj project's toolbar, not a flaw in the tests; the git suite has no such
/// requirement.
///
/// **Out of reach here, deliberately:** hover wells and `.help` tooltips (`.onHover` is not driven by
/// XCUITest's synthetic hover — see `ChangesPanelUITests`), and the width-degradation ladder (dropped text
/// simply isn't in the accessibility tree). Those are covered by `VCSToolbarMetricsTests` (the geometry)
/// and `VCSSyncPresentationTests` (the variant ordering and the backend vocabulary).
///
/// Run with `make app-uitest` on a real GUI login session; excluded from the unit gate.
class VCSToolbarUITestsBase: XCTestCase {

  // MARK: Backend parameterisation

  /// Launch arguments that select the backend. Empty for git — the fixture's default.
  class var backendArguments: [String] { [] }

  /// What this backend calls the ref the working copy is on, capitalised as the caption renders it.
  class var expectedRefNoun: String { "Branch" }

  /// The other backend's noun, which must NOT appear. Asserting only the positive would pass on a caption
  /// that somehow said both.
  class var wrongRefNoun: String { expectedRefNoun == "Branch" ? "Bookmark" : "Branch" }

  /// The base contributes no tests of its own — without this, XCTest would run every test three times
  /// (once per class) and the base's run would exercise whichever backend the defaults happen to name.
  override class var defaultTestSuite: XCTestSuite {
    if self == VCSToolbarUITestsBase.self {
      return XCTestSuite(name: "VCSToolbarUITestsBase (abstract)")
    }
    return super.defaultTestSuite
  }

  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(syncState: String? = nil, extraArguments: [String] = [])
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    if let syncState { app.launchArguments += ["-WorkroomUITestSyncState", syncState] }
    app.launchArguments += Self.backendArguments
    app.launchArguments += extraArguments
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// The BUTTON carrying `id`, not whatever wrapper happens to match first.
  ///
  /// SwiftUI publishes an accessibility identifier on more than one layer, so `descendants(.any)` can
  /// return a containing group: it reports `exists` and even `isHittable`, but clicking it does not
  /// invoke the button's action, and the test then fails claiming nothing happened.
  private func button(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.buttons.matching(identifier: id).firstMatch
  }

  private func toolbar(_ app: XCUIApplication) -> XCUIElement { element(app, id: "vcs.toolbar") }
  private func sync(_ app: XCUIApplication) -> XCUIElement { element(app, id: "vcs.toolbar.sync") }
  private func branch(_ app: XCUIApplication) -> XCUIElement {
    element(app, id: "vcs.toolbar.branch")
  }
  private func fetch(_ app: XCUIApplication) -> XCUIElement {
    element(app, id: "vcs.toolbar.fetch")
  }

  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool = true, _ timeout: TimeInterval = 6)
    -> Bool
  {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// Wait for an element's label to satisfy a predicate — the states are async (the model reads, then
  /// publishes), so every state assertion has to wait rather than sample once.
  @discardableResult
  private func waitLabel(_ el: XCUIElement, contains text: String, _ timeout: TimeInterval = 6)
    -> Bool
  {
    let p = NSPredicate(format: "label CONTAINS[c] %@", text)
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  // MARK: Placement

  /// **The test that pins the requirement.** The toolbar must sit ABOVE the Changes section header —
  /// that placement is the whole ask, and nothing else in the suite would notice if it moved inside a
  /// section or below the stack.
  func testToolbarSitsAboveTheChangesHeader() {
    let app = launchedApp(syncState: "ahead")
    let bar = toolbar(app)
    let header = element(app, id: "inspector.header.Changes")
    XCTAssertTrue(waitExists(bar), "the VCS toolbar should be present on the Changes section")
    XCTAssertTrue(waitExists(header), "the Changes header should be present")
    XCTAssertLessThanOrEqual(
      bar.frame.maxY, header.frame.minY + 1,
      "the toolbar must render above the Changes header, not inside or below the section stack")
  }

  /// Branch and remote state belong to the Changes section; the Files tree has no use for them, and
  /// showing the bar there would jump the layout on every activity-bar click.
  /// The flag is `-WorkroomUITestInspectorSection`. It was `-WorkroomUITestSection`, which the fixture
  /// never reads, so the app always launched on Changes and the whole test rested on an un-awaited
  /// `if toolbar(app).exists { typeKey ⌥⌘F }`: sampled before the bar rendered, the keystroke was skipped
  /// and the negative assertion passed against a toolbar that was about to appear. The Files case was
  /// never exercised. The precondition is now asserted rather than assumed.
  func testToolbarIsHiddenOnTheFilesSection() {
    let app = launchedApp(extraArguments: ["-WorkroomUITestInspectorSection", "files"])
    XCTAssertTrue(
      element(app, id: "inspector.header.Files").waitForExistence(timeout: 10),
      "the Files pane must be up before absence of the toolbar means anything")
    XCTAssertTrue(
      waitExists(toolbar(app), false), "the toolbar must not render for the Files section")
  }

  // MARK: States

  func testAheadShowsPushWithACount() {
    let app = launchedApp(syncState: "ahead")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(
      waitLabel(sync(app), contains: "Push"),
      "5 commits ahead should read as Push, got \(sync(app).label)")
    XCTAssertTrue(
      sync(app).value as? String == "5 ahead",
      "the count pill is accessibilityHidden, so the number must arrive as the button's value; "
        + "got \(String(describing: sync(app).value))")
  }

  func testBehindShowsPullWithRebase() {
    let app = launchedApp(syncState: "behind")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(
      waitLabel(sync(app), contains: "Pull"), "got \(sync(app).label)")
    XCTAssertTrue(sync(app).label.lowercased().contains("rebase"))
  }

  /// Diverged must offer PULL, not push — git refuses a non-fast-forward push, so offering Push would
  /// send the user straight into a rejection.
  func testDivergedOffersPullNotPush() {
    let app = launchedApp(syncState: "diverged")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Pull"), "got \(sync(app).label)")
    XCTAssertFalse(sync(app).label.contains("Push"))
  }

  /// A clean repo's sync segment becomes a fetch affordance and shows only the staleness line. The
  /// fixture pins the timestamp to nine minutes ago, so this is the reference design's exact string.
  func testCleanShowsOnlyTheFetchedLine() {
    let app = launchedApp(syncState: "clean")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(
      waitLabel(sync(app), contains: "9 minutes ago"), "got \(sync(app).label)")
    XCTAssertFalse(sync(app).label.contains("Push"))
    XCTAssertFalse(
      sync(app).label.contains("Last"), "\"ago\" already places it in the past")
  }

  /// A fresh workroom is `git worktree add -b` / `jj workspace add` with no counterpart on the remote —
  /// the product's DEFAULT state. It must read as Publish, never as Push against a ref that doesn't exist.
  func testNoCounterpartOffersPublish() {
    let app = launchedApp(syncState: "noCounterpart")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Publish"), "got \(sync(app).label)")
  }

  func testNoRemoteIsDisabled() {
    let app = launchedApp(syncState: "noRemote")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "No remote"), "got \(sync(app).label)")
    XCTAssertFalse(sync(app).isEnabled, "there is nothing to sync with")
  }

  func testNeverFetchedIsSaidPlainly() {
    let app = launchedApp(syncState: "neverFetched")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Never fetched"), "got \(sync(app).label)")
  }

  // MARK: Branch segment

  /// The name, and the backend's own word for it.
  ///
  /// The noun is the one thing that genuinely differs between the two suites, and getting it wrong is not
  /// cosmetic: a jj bookmark does NOT advance as you commit, which is a git branch's defining behaviour,
  /// so "branch" in a jj repo describes something the tool doesn't do. This shipped saying "Current Branch"
  /// over jj data — the git-only fixture is why nothing caught it.
  /// The segment is one accessibility element whose LABEL carries both parts, as `"Current Branch:
  /// feature/login"`. Not label + value: `.accessibilityValue` stopped applying once the segment became a
  /// non-`Button` collapsed with `children: .ignore`, and read back empty.
  func testBranchSegmentShowsTheCurrentRefAndItsBackendNoun() {
    let app = launchedApp(syncState: "ahead")
    XCTAssertTrue(waitExists(branch(app)))
    XCTAssertTrue(waitLabel(branch(app), contains: "feature/login"))
    let label = branch(app).label
    // A PREFIX check, not `contains`: a ref legitimately named `bookmark-fix` or `branch-cleanup` would
    // make a `contains` assertion on the wrong noun fail against perfectly correct code.
    XCTAssertTrue(
      label.hasPrefix("Current \(Self.expectedRefNoun)"),
      "expected the caption to lead with Current \(Self.expectedRefNoun); got \(label)")
    XCTAssertFalse(
      label.hasPrefix("Current \(Self.wrongRefNoun)"),
      "the caption must not say \(Self.wrongRefNoun); got \(label)")
    XCTAssertTrue(label.contains("feature/login"), "the name must be spoken too; got \(label)")
  }

  /// The caption is not optional, and it is not a control.
  ///
  /// It used to sit in a `ViewThatFits` ladder against a name-only variant, and `ViewThatFits` measures
  /// each variant's IDEAL width — a `.lineLimit(1)` truncating `Text` reports its FULL untruncated string —
  /// so the caption was vetoed by a long NAME rather than by a narrow cell. The segment is also display
  /// only: no `Button`, so it must expose no press action.
  func testCaptionAlwaysRendersAndTheSegmentIsNotAControl() {
    let app = launchedApp(syncState: "ahead")
    XCTAssertTrue(waitExists(branch(app)))
    XCTAssertTrue(
      waitLabel(branch(app), contains: "Current"),
      "the caption must render, not be silently dropped; got \(branch(app).label)")
    XCTAssertFalse(
      button(app, id: "vcs.toolbar.branch").exists,
      "the branch segment is display only — it must not be a button")
  }

  // MARK: The button → engine seam

  /// Clicking the sync segment must actually request the action it names. `-WorkroomUITestSyncFailure`
  /// makes the requested action observable: the failure tier renders the failed action's own label.
  func testClickingPushRequestsAPush() {
    let app = launchedApp(syncState: "ahead", extraArguments: ["-WorkroomUITestSyncFailure", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Push"))
    XCTAssertTrue(button(app, id: "vcs.toolbar.sync").isHittable)
    button(app, id: "vcs.toolbar.sync").click()
    XCTAssertTrue(
      waitLabel(sync(app), contains: "authenticate", 10),
      "a failed push must surface inline on the segment; got \(sync(app).label)")
  }

  /// The fixture delays each action, so the in-flight state is observable — and while it's in flight the
  /// segment must be disabled, which is what stops a double-click firing twice.
  func testInFlightActionDisablesTheSegment() {
    let app = launchedApp(syncState: "ahead")
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Push"))
    XCTAssertTrue(button(app, id: "vcs.toolbar.sync").isHittable)
    button(app, id: "vcs.toolbar.sync").click()
    XCTAssertTrue(
      waitLabel(sync(app), contains: "Pushing", 6),
      "the in-flight state should render; got \(sync(app).label)")
    XCTAssertFalse(sync(app).isEnabled, "a second click must not be able to fire another push")
  }

  func testClickingFetchRunsAFetch() {
    let app = launchedApp(syncState: "clean")
    XCTAssertTrue(waitExists(fetch(app)))
    XCTAssertTrue(fetch(app).isEnabled)
    XCTAssertTrue(button(app, id: "vcs.toolbar.fetch").isHittable)
    button(app, id: "vcs.toolbar.fetch").click()
    XCTAssertTrue(
      waitLabel(sync(app), contains: "Fetching", 6),
      "the sync segment reports the in-flight fetch; got \(sync(app).label)")
  }

  /// The end of the conflicted-pull path, and the only tier whose outcome is neither a success nor a
  /// failure. jj's rebase exits 0 WITH conflicts, so nothing in the failure taxonomy fires — and behind
  /// returns to 0, so before this the count tiers rendered "Push origin" over a conflicted tree and said
  /// nothing at all about it.
  ///
  /// The whole chain runs here: click → dirty-tree confirmation → fixture writer returns `.ok` → the
  /// forced status sweep lands → `noteConflictState` → this tier. A unit test can pin the tier but not
  /// that the flag ever reaches it.
  func testAPullThatLandsConflictsIsReported() {
    let app = launchedApp(syncState: "behind", extraArguments: ["-WorkroomUITestConflict", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Pull"))
    XCTAssertTrue(button(app, id: "vcs.toolbar.sync").isHittable)
    button(app, id: "vcs.toolbar.sync").click()

    // The fixture workroom is dirty, so the autostash confirmation comes first. Matched by exact label:
    // the sync segment itself is spoken "Pull origin with rebase", so this can only be the dialog.
    //
    // Matched by an EXACT-label predicate, not `app.buttons["Pull"]`: that subscript matches identifier
    // as well as label and resolved to several elements, which fails the click with "Multiple matching
    // elements found". Exactly one button is labelled "Pull" — the sync segment is spoken "Pull origin
    // with rebase" — so this can only be the dialog's confirm.
    let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Pull")).firstMatch
    XCTAssertTrue(waitExists(confirm, true, 8), "the dirty-tree confirmation should appear")
    confirm.click()

    XCTAssertTrue(
      waitLabel(sync(app), contains: "Pulled with conflicts", 15),
      "a conflicted pull must be reported, not left reading as a push offer; got \(sync(app).label)"
    )
  }

  /// A failed action must NOT blank the toolbar — the ref is still known, and the repo is unchanged.
  func testAFailedActionKeepsTheBranchVisible() {
    let app = launchedApp(syncState: "ahead", extraArguments: ["-WorkroomUITestSyncFailure", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(button(app, id: "vcs.toolbar.sync").isHittable)
    button(app, id: "vcs.toolbar.sync").click()
    XCTAssertTrue(waitLabel(sync(app), contains: "authenticate", 10))
    XCTAssertTrue(
      branch(app).label.contains("feature/login"),
      "a failed action tells you nothing new about the repo, so the snapshot must stand; got "
        + branch(app).label)
  }
}

/// The toolbar against a **git** project — the fixture's default.
final class VCSToolbarGitUITests: VCSToolbarUITestsBase {
  override class var backendArguments: [String] { [] }
  override class var expectedRefNoun: String { "Branch" }
}

/// The toolbar against a **jj** project.
///
/// `-WorkroomUITestJJProject 1` is what makes the fixture's project report `vcs: "jj"`. The fixture already
/// fed jj-SHAPED status (`@`'s change-id, commit-id, bookmarks and description) while declaring the project
/// git, which is why a jj-specific wording bug could ship unseen.
final class VCSToolbarJJUITests: VCSToolbarUITestsBase {
  override class var backendArguments: [String] { ["-WorkroomUITestJJProject", "1"] }
  override class var expectedRefNoun: String { "Bookmark" }
}
