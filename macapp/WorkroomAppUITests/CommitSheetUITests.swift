import XCTest

/// The commit dialog's seam: the Changes header button opens it, the selection drives the button's
/// count, jj is offered no per-file selection at all, and a rejected commit keeps the hook's output.
///
/// **What only this tier can see.** `VCSCommitIntegrationTests` proves what git and jj actually do,
/// but it drives `CLIVCSWriter` directly and never renders anything. Everything below is about the
/// path between a click and a `VCSCommitRequest` — which button is live, what the label claims, which
/// controls exist per backend, and whether a failure survives to the screen. `FixtureVCSWriter`
/// answers the write, so no real repo is touched.
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run, so
/// these live in a separate scheme, excluded from `make app-test`.
final class CommitSheetUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extraArguments
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// A clickable control, scoped to `.button`.
  ///
  /// Not `descendants(matching: .any)`: that resolves to whichever element carries the identifier
  /// first, which can be a container rather than the control — clicking it then lands on the
  /// container's centre and silently does nothing, which is exactly how the checkbox failure
  /// presented (the count never moved and no assertion pointed at the cause).
  private func button(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.buttons.matching(identifier: id).firstMatch
  }

  /// Open the dialog from the Changes section header and wait for it.
  @discardableResult
  private func openSheet(_ app: XCUIApplication) -> XCUIElement {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      element(app, id: "inspector.header.Changes").waitForExistence(timeout: 10),
      "the Changes section should exist")
    let open = button(app, id: "changes.commitButton")
    XCTAssertTrue(open.waitForExistence(timeout: 10), "the Changes header should offer Commit")
    open.click()
    let sheet = element(app, id: "commit.sheet")
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the commit dialog should open")
    return sheet
  }

  private func typeSummary(_ app: XCUIApplication, _ text: String) {
    let field = element(app, id: "commit.summary")
    XCTAssertTrue(field.waitForExistence(timeout: 5), "the summary field should exist")
    field.click()
    field.typeText(text)
  }

  // MARK: - git

  /// The whole point of the dialog: it names what it is about to record, per file, before you commit.
  func testGitSheetListsFilesWithCheckboxes() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)

    XCTAssertTrue(
      button(app, id: "commit.file.check.Gemfile").waitForExistence(timeout: 5),
      "a git file row should carry an inclusion checkbox")
    XCTAssertTrue(
      button(app, id: "commit.selectAll").exists, "and a bulk select-all affordance")
  }

  /// A blocked state must be readable, not hidden in a tooltip nobody hovers on a dead-looking
  /// button — so the reason renders as its own element and Commit is genuinely disabled.
  func testCommitIsBlockedUntilThereIsASummary() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)

    let blocked = element(app, id: "commit.blocked")
    XCTAssertTrue(blocked.waitForExistence(timeout: 5), "the reason should be stated on screen")
    XCTAssertTrue(
      (blocked.label + blocked.value.debugDescription).contains("summary"),
      "and should name the missing summary, got: \(blocked.label)")

    let commit = button(app, id: "commit.commit")
    XCTAssertTrue(commit.exists)
    XCTAssertFalse(commit.isEnabled, "Commit stays disabled with no summary")

    typeSummary(app, "Add session login")
    let enabled = NSPredicate(format: "isEnabled == true")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: enabled, object: commit)], timeout: 5),
      .completed, "typing a summary should enable Commit")
  }

  /// The count is the honest claim about what will be recorded, so it has to track the checkboxes —
  /// once the list scrolls, the label is the only thing the user can verify against.
  func testDeselectingAFileChangesTheCommitCount() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)
    typeSummary(app, "Add session login")

    let commit = button(app, id: "commit.commit")
    XCTAssertTrue(commit.waitForExistence(timeout: 5))
    let before = commit.label
    XCTAssertTrue(before.contains("file"), "the label should name a count, got: \(before)")

    button(app, id: "commit.file.check.Gemfile").click()

    let changed = NSPredicate(format: "label != %@", before)
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: changed, object: commit)], timeout: 5),
      .completed, "excluding a file should change the count, still read: \(commit.label)")
  }

  /// Select-all is what makes "commit only this file" cheap; without it that intent costs one click
  /// per unwanted file.
  func testSelectAllTogglesEveryFile() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)
    typeSummary(app, "Add session login")

    let commit = button(app, id: "commit.commit")
    XCTAssertTrue(commit.waitForExistence(timeout: 5))
    button(app, id: "commit.selectAll").click()

    // Everything excluded ⇒ nothing to commit, which is a blocked state with its own message.
    let blocked = element(app, id: "commit.blocked")
    XCTAssertTrue(
      blocked.waitForExistence(timeout: 5), "deselecting everything should block the commit")
    XCTAssertFalse(commit.isEnabled, "and Commit should not be live with nothing selected")
  }

  // MARK: - jj

  /// jj has no index and commits the whole change, so rendering checkboxes whose only effect would be
  /// to disable the button is a designed dead end.
  func testJJSheetOffersNoPerFileSelection() throws {
    // `-WorkroomUITestJJProject` is the flag that matters: the fixture's PROJECT declares `vcs: "git"`
    // by default and only this makes it jj. `-WorkroomUITestGitWorkroom` changes the status SHAPE
    // (whether `jjWorkingCopy` is populated), not the backend the sheet resolves — so without this the
    // sheet correctly rendered git checkboxes and the test was asserting against the wrong backend.
    let app = launchedApp(extraArguments: ["-WorkroomUITestJJProject", "1"])
    openSheet(app)

    XCTAssertTrue(
      element(app, id: "commit.summary").waitForExistence(timeout: 5), "the sheet should render")
    XCTAssertFalse(
      button(app, id: "commit.file.check.Gemfile").exists,
      "jj must not offer per-file checkboxes")
    XCTAssertFalse(
      button(app, id: "commit.selectAll").exists, "nor a select-all for a selection it can't make")
  }

  /// Each backend's second verb is its own named button, not a menu item. A menu holding exactly one
  /// entry costs a click and leaves the control unnamed until it's opened.
  func testGitOffersAmendAsItsOwnButton() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)

    let amend = button(app, id: "commit.amend")
    XCTAssertTrue(amend.waitForExistence(timeout: 5), "git should offer Amend directly")
    XCTAssertEqual(amend.label, "Amend last commit")
    XCTAssertFalse(
      button(app, id: "commit.describe").exists, "and never jj's verb")

    // Amend rewords the last commit, so it needs a message just as Commit does.
    XCTAssertFalse(amend.isEnabled, "no summary yet")
    typeSummary(app, "Reworded")
    let enabled = NSPredicate(format: "isEnabled == true")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: enabled, object: amend)], timeout: 5),
      .completed)
  }

  func testJJOffersDescribeAsItsOwnButton() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestJJProject", "1"])
    openSheet(app)

    let describe = button(app, id: "commit.describe")
    XCTAssertTrue(describe.waitForExistence(timeout: 5), "jj should offer Describe directly")
    XCTAssertEqual(describe.label, "Describe")
    XCTAssertFalse(
      button(app, id: "commit.amend").exists, "jj has no amend — it must not be offered")
  }

  // MARK: - Render cap

  /// A cap on drawn rows is only safe if it cannot lie about the commit. The dialog draws 200, but
  /// the button must still claim — and the commit still record — all 257.
  func testTheRenderCapLimitsWhatIsDrawnNotWhatIsCommitted() throws {
    let app = launchedApp(extraArguments: [
      "-WorkroomUITestGitWorkroom", "1", "-WorkroomUITestHugeChangeSet", "1",
    ])
    openSheet(app)

    let notice = element(app, id: "commit.renderCapNotice")
    XCTAssertTrue(
      notice.waitForExistence(timeout: 10),
      "a truncated list must say so — a silent cap reads as 'this is everything'")

    typeSummary(app, "Vendor drop")
    let commit = button(app, id: "commit.commit")
    XCTAssertTrue(commit.waitForExistence(timeout: 5))
    XCTAssertTrue(
      commit.label.contains("257"),
      "the count must be the real total, not the drawn one, got: \(commit.label)")
  }

  // MARK: - Amend target

  /// Amend replaces HEAD's message with whatever is typed for a NEW commit, so which message it
  /// destroys has to be on screen before the click — not recoverable only from the reflog after it.
  func testTheAmendTargetIsNamedOnScreen() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)

    let notice = element(app, id: "commit.amendTarget")
    XCTAssertTrue(
      notice.waitForExistence(timeout: 10), "the commit Amend would rewrite must be named")
    XCTAssertTrue(
      (notice.label + notice.value.debugDescription).lowercased().contains("amend"),
      "and the line must say what it is about to replace, got: \(notice.label)")
  }

  /// jj has no amend, so it gets no such line.
  func testJJShowsNoAmendTarget() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestJJProject", "1"])
    openSheet(app)
    XCTAssertTrue(element(app, id: "commit.summary").waitForExistence(timeout: 5))
    XCTAssertFalse(element(app, id: "commit.amendTarget").exists)
  }

  // MARK: - Failure

  /// The defining moment. A hook's output is the most useful text in the whole taxonomy, so a
  /// rejected commit must keep the dialog open, keep the draft, and still carry the output.
  func testARejectedCommitKeepsTheSheetAndTheHookOutput() throws {
    let app = launchedApp(
      extraArguments: ["-WorkroomUITestGitWorkroom", "1", "-WorkroomUITestSyncFailure", "1"])
    openSheet(app)
    typeSummary(app, "Add session login")

    button(app, id: "commit.commit").click()

    // The fixture writer delays deliberately so the in-flight state is observable rather than
    // instantaneous, hence the generous timeout.
    XCTAssertTrue(
      element(app, id: "commit.failure").waitForExistence(timeout: 20),
      "a rejected commit should report itself in the dialog")
    XCTAssertTrue(
      element(app, id: "commit.sheet").exists, "and the dialog must stay open, draft intact")
    XCTAssertTrue(
      element(app, id: "commit.summary").exists, "the typed summary is not thrown away")
    XCTAssertTrue(
      element(app, id: "commit.failure.detailsToggle").exists,
      "the hook's own output must be reachable, not flattened to one line")
  }

  // MARK: - Success and dismissal

  /// A successful commit closes the dialog — the Changes list becoming clean is the confirmation.
  func testASuccessfulCommitClosesTheSheet() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)
    typeSummary(app, "Add session login")

    button(app, id: "commit.commit").click()

    let sheet = element(app, id: "commit.sheet")
    let gone = NSPredicate(format: "exists == false")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: sheet)], timeout: 20),
      .completed, "the dialog should close once the commit lands")
  }

  func testCancelClosesTheSheetWithoutCommitting() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestGitWorkroom", "1"])
    openSheet(app)

    button(app, id: "commit.cancel").click()

    let sheet = element(app, id: "commit.sheet")
    let gone = NSPredicate(format: "exists == false")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: sheet)], timeout: 5),
      .completed, "Cancel should dismiss the dialog")
  }
}
