import XCTest

/// UI tests for the VCS toolbar: its placement above the Changes header, the states its sync segment
/// renders, and the button→engine seam.
///
/// Remote state is SEEDED via `-WorkroomUITestSyncState` (see `UITestFixture.remoteState`) because the
/// fixture's paths aren't real repos — a live read resolves to "No repository", which is a correct but
/// uninteresting state. The engine's own correctness against real repos is `VCSRemoteIntegrationTests`;
/// what only this tier can see is whether the rendered control does what it says.
///
/// **Out of reach here, deliberately:** hover wells and `.help` tooltips (`.onHover` is not driven by
/// XCUITest's synthetic hover — see `ChangesPanelUITests`), and the width-degradation ladder (dropped text
/// simply isn't in the accessibility tree). Those are covered by `VCSToolbarMetricsTests` (the geometry)
/// and `VCSSyncPresentationTests` (the variant ordering).
///
/// Run with `make app-uitest` on a real GUI login session; excluded from the unit gate.
final class VCSToolbarUITests: XCTestCase {

  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(syncState: String? = nil, extraArguments: [String] = [])
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    if let syncState { app.launchArguments += ["-WorkroomUITestSyncState", syncState] }
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

  /// Wait for an element's label OR value to contain `text`.
  ///
  /// Both, because which of the two carries a `Text`'s string is not ours to choose: AppKit maps some
  /// SwiftUI text elements to a static text whose LABEL is empty and whose VALUE holds the string (the
  /// same mapping the Changes header's combined element runs into). Asserting on `label` alone read as
  /// "the dialog says nothing" for a dialog that said everything.
  @discardableResult
  private func waitText(_ el: XCUIElement, contains text: String, _ timeout: TimeInterval = 6)
    -> Bool
  {
    let p = NSPredicate(
      format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
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

  // MARK: Branch segment

  /// The name, and the caption naming it a branch — always, and as display only.
  ///
  /// The segment is one accessibility element whose LABEL carries both parts, as `"Current Branch:
  /// feature/login"`. Not label + value: `.accessibilityValue` stopped applying once the segment became a
  /// non-`Button` collapsed with `children: .ignore`, and read back empty.
  ///
  /// The caption is not optional. It used to sit in a `ViewThatFits` ladder against a name-only
  /// variant, and `ViewThatFits` measures each variant's IDEAL width — a `.lineLimit(1)` truncating
  /// `Text` reports its FULL untruncated string — so the caption was vetoed by a long NAME rather than
  /// by a narrow cell. The segment is also display only: no `Button`, so it must expose no press action.
  func testBranchSegmentShowsTheRefUnderItsCaptionAndIsNotAControl() {
    let app = launchedApp(syncState: "ahead")
    XCTAssertTrue(waitExists(branch(app)))
    XCTAssertTrue(waitLabel(branch(app), contains: "feature/login"))
    let label = branch(app).label
    // A PREFIX check, not `contains`: a ref legitimately named `branch-cleanup` would make a
    // `contains` assertion pass against a caption that is wrong.
    XCTAssertTrue(
      label.hasPrefix("Current Branch"),
      "the caption must render, not be silently dropped; got \(label)")
    XCTAssertTrue(label.contains("feature/login"), "the name must be spoken too; got \(label)")
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
    // A failed action tells you nothing new about the repo, so it must not blank the toolbar.
    XCTAssertTrue(
      branch(app).label.contains("feature/login"),
      "a failed action must leave the branch visible; got " + branch(app).label)
  }

  /// `-WorkroomUITestSlowVCS` holds each fixture action, so the in-flight state is observable — and
  /// while it's in flight the segment must be disabled, which is what stops a double-click firing
  /// twice.
  func testInFlightActionDisablesTheSegment() {
    let app = launchedApp(syncState: "ahead", extraArguments: ["-WorkroomUITestSlowVCS", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Push"))
    XCTAssertTrue(button(app, id: "vcs.toolbar.sync").isHittable)
    button(app, id: "vcs.toolbar.sync").click()
    XCTAssertTrue(
      waitLabel(sync(app), contains: "Pushing", 6),
      "the in-flight state should render; got \(sync(app).label)")
    XCTAssertFalse(sync(app).isEnabled, "a second click must not be able to fire another push")
  }

  /// Slowed (`-WorkroomUITestSlowVCS`) so the in-flight "Fetching" label is observable.
  func testClickingFetchRunsAFetch() {
    let app = launchedApp(syncState: "clean", extraArguments: ["-WorkroomUITestSlowVCS", "1"])
    XCTAssertTrue(waitExists(fetch(app)))
    XCTAssertTrue(fetch(app).isEnabled)
    XCTAssertTrue(button(app, id: "vcs.toolbar.fetch").isHittable)
    button(app, id: "vcs.toolbar.fetch").click()
    XCTAssertTrue(
      waitLabel(sync(app), contains: "Fetching", 6),
      "the sync segment reports the in-flight fetch; got \(sync(app).label)")
  }

  /// The end of the conflicted-pull path, and the only tier whose outcome is neither a success nor a
  /// failure. A pull can exit 0 and still leave conflicts, so nothing in the failure taxonomy fires — and behind
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

  // MARK: The failure dialog

  /// **The reported defect, end to end.** The segment can only ever show a truncated notice, so a failure
  /// has to raise a dialog carrying the whole message and the actions. Only this tier can see that the
  /// sheet actually presents itself — a unit test can pin the copy but not that anything shows it.
  func testAFailedActionRaisesTheFailureDialog() {
    let app = launchedApp(syncState: "ahead", extraArguments: ["-WorkroomUITestSyncFailure", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Push"))
    button(app, id: "vcs.toolbar.sync").click()

    let sheet = element(app, id: "vcs.failure.sheet")
    XCTAssertTrue(waitExists(sheet, true, 10), "a failed push must put its message on screen")
    let title = element(app, id: "vcs.failure.title")
    XCTAssertTrue(
      waitText(title, contains: "Push failed"),
      "the dialog names what failed; got \(title.label) / \(String(describing: title.value))")
    // The full sentence, not the bar's truncation — the whole point of the dialog.
    let message = element(app, id: "vcs.failure.message")
    XCTAssertTrue(waitExists(message))
    XCTAssertTrue(
      waitText(message, contains: "ssh-add"),
      "the remedy must be readable in full, not hidden in a tooltip; got \(message.label) / "
        + String(describing: message.value))
  }

  /// Dismissing closes the dialog and leaves the toolbar's notice standing — the failure hasn't stopped
  /// being true just because the sheet was closed.
  func testDismissingTheDialogLeavesTheToolbarReporting() {
    let app = launchedApp(syncState: "ahead", extraArguments: ["-WorkroomUITestSyncFailure", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "Push"))
    button(app, id: "vcs.toolbar.sync").click()
    XCTAssertTrue(waitExists(element(app, id: "vcs.failure.sheet"), true, 10))

    button(app, id: "vcs.failure.dismiss").click()
    XCTAssertTrue(waitExists(element(app, id: "vcs.failure.sheet"), false, 6))
    XCTAssertTrue(
      waitLabel(sync(app), contains: "authenticate"),
      "the bar goes on reporting the failure; got \(sync(app).label)")
  }

  // MARK: A failed read

  /// **The reported defect.** A read that fails nils the snapshot, and a nil snapshot renders
  /// "No repository" — a wrong diagnosis of a healthy repo whose refs were momentarily locked, with no
  /// cause named and nothing to click. Only this tier can see that the tier actually reaches the screen:
  /// nothing rendered `model.state`, so the unit-level failure was invisible end to end.
  func testAFailedReadNamesTheCauseAndOffersARetry() {
    let app = launchedApp(extraArguments: ["-WorkroomUITestSyncReadFailure", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(
      waitLabel(sync(app), contains: "busy", 10),
      "the read's own failure must be named; got \(sync(app).label)")
    XCTAssertFalse(
      sync(app).label.contains("No repository"),
      "the repo is fine — diagnosing it as absent is the bug; got \(sync(app).label)")
    XCTAssertTrue(
      button(app, id: "vcs.toolbar.sync").isHittable,
      "the retry has to be clickable, or the tier is just a nicer dead end")
  }

  /// The details dialog is reachable for a read failure too, through the segment's context menu — the
  /// one line in the bar can't carry the explanation any more than an action's can.
  func testAFailedReadCanShowItsDetails() {
    let app = launchedApp(extraArguments: ["-WorkroomUITestSyncReadFailure", "1"])
    XCTAssertTrue(waitExists(sync(app)))
    XCTAssertTrue(waitLabel(sync(app), contains: "busy", 10))
    button(app, id: "vcs.toolbar.sync").rightClick()
    let item = app.menuItems["Show Error Details…"]
    XCTAssertTrue(item.waitForExistence(timeout: 6), "the failure tier must offer its details")
    item.click()
    XCTAssertTrue(
      waitExists(element(app, id: "vcs.failure.sheet"), true, 10),
      "a read failure's explanation belongs in the dialog, like an action's")
  }
}
