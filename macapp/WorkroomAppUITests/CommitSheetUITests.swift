import XCTest

/// The commit dialog's seam: the Changes header button opens it, the selection drives the button's
/// count, and a rejected commit keeps the hook's output.
///
/// **What only this tier can see.** `VCSCommitIntegrationTests` proves what git actually does,
/// but it drives `CLIVCSWriter` directly and never renders anything. Everything below is about the
/// path between a click and a `VCSCommitRequest` — which button is live, what the label claims, which
/// controls exist, and whether a failure survives to the screen. `FixtureVCSWriter`
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

  /// One launch walks the git sheet in the order its state allows: the read-only checks on the fresh
  /// sheet first, then the summary, the checkboxes, select-all, Cancel, and last a reopened sheet
  /// that commits (a successful commit closes the dialog, so it has to be the final step).
  func testGitSheetListsFilesGatesCommitAndClosesOnCancelAndCommit() throws {
    let app = launchedApp()
    openSheet(app)
    let commit = button(app, id: "commit.commit")
    let amend = button(app, id: "commit.amend")
    let blocked = element(app, id: "commit.blocked")

    // 1. The whole point of the dialog: it names what it is about to record, per file, before you
    // commit.
    XCTAssertTrue(
      button(app, id: "commit.file.check.Gemfile").waitForExistence(timeout: 5),
      "a git file row should carry an inclusion checkbox")
    XCTAssertTrue(
      button(app, id: "commit.selectAll").exists, "and a bulk select-all affordance")

    // 2. Amend replaces HEAD's message with whatever is typed for a NEW commit, so which message it
    // destroys has to be on screen before the click — not recoverable only from the reflog after it.
    let target = element(app, id: "commit.amendTarget")
    XCTAssertTrue(
      target.waitForExistence(timeout: 10), "the commit Amend would rewrite must be named")
    XCTAssertTrue(
      (target.label + target.value.debugDescription).lowercased().contains("amend"),
      "and the line must say what it is about to replace, got: \(target.label)")

    // 3. A blocked state must be readable, not hidden in a tooltip nobody hovers on a dead-looking
    // button — so the reason renders as its own element and Commit is genuinely disabled.
    XCTAssertTrue(blocked.waitForExistence(timeout: 5), "the reason should be stated on screen")
    XCTAssertTrue(
      (blocked.label + blocked.value.debugDescription).contains("summary"),
      "and should name the missing summary, got: \(blocked.label)")
    XCTAssertTrue(commit.exists)
    XCTAssertFalse(commit.isEnabled, "Commit stays disabled with no summary")

    // The second verb is its own named button, not a menu item. A menu holding exactly one
    // entry costs a click and leaves the control unnamed until it's opened.
    XCTAssertTrue(amend.waitForExistence(timeout: 5), "git should offer Amend directly")
    XCTAssertEqual(amend.label, "Amend last commit")
    // Amend rewords the last commit, so it needs a message just as Commit does.
    XCTAssertFalse(amend.isEnabled, "no summary yet")

    // 4. Typing a summary enables both verbs and clears the reason. The reason's absence is only
    // meaningful because step 3 proved it renders, and it matters below: the select-all step waits
    // for the reason to appear, which a stale element would satisfy.
    typeSummary(app, "Add session login")
    let enabled = NSPredicate(format: "isEnabled == true")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: enabled, object: commit)], timeout: 5),
      .completed, "typing a summary should enable Commit")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: enabled, object: amend)], timeout: 5),
      .completed, "and Amend, which needs a message just as Commit does")
    XCTAssertTrue(blocked.waitForNonExistence(timeout: 5), "a summary lifts the blocked reason")

    // 5. The count is the honest claim about what will be recorded, so it has to track the
    // checkboxes — once the list scrolls, the label is the only thing the user can verify against.
    let before = commit.label
    XCTAssertTrue(before.contains("file"), "the label should name a count, got: \(before)")
    button(app, id: "commit.file.check.Gemfile").click()
    let changed = NSPredicate(format: "label != %@", before)
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: changed, object: commit)], timeout: 5),
      .completed, "excluding a file should change the count, still read: \(commit.label)")

    // 6. Select-all is what makes "commit only this file" cheap; without it that intent costs one
    // click per unwanted file. One file is excluded now, so the first click re-includes everything
    // (the count returns to `before`) and the second excludes everything.
    button(app, id: "commit.selectAll").click()
    let restored = NSPredicate(format: "label == %@", before)
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: restored, object: commit)], timeout: 5),
      .completed, "select-all with a file excluded should include every file again")
    XCTAssertFalse(blocked.exists, "with every file selected nothing blocks the commit")
    button(app, id: "commit.selectAll").click()
    // Everything excluded ⇒ nothing to commit, which is a blocked state with its own message.
    XCTAssertTrue(
      blocked.waitForExistence(timeout: 5), "deselecting everything should block the commit")
    XCTAssertTrue(
      (blocked.label + blocked.value.debugDescription).contains("Select at least one file"),
      "with the reason for an empty selection, got: \(blocked.label)")
    XCTAssertFalse(commit.isEnabled, "and Commit should not be live with nothing selected")

    // 7. Cancel dismisses the dialog. The sheet is proven open by the steps above, so its absence
    // is real.
    let sheet = element(app, id: "commit.sheet")
    XCTAssertTrue(sheet.exists, "the dialog is still open before Cancel")
    button(app, id: "commit.cancel").click()
    let gone = NSPredicate(format: "exists == false")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: sheet)], timeout: 5),
      .completed, "Cancel should dismiss the dialog")

    // 8. A reopened dialog starts clean: no summary and the full selection, so the reason is the
    // summary one (not the empty-selection one left over from step 6) and Commit is dead again.
    // That makes typing the summary below meaningful.
    openSheet(app)
    XCTAssertTrue(
      blocked.waitForExistence(timeout: 5), "a reopened dialog states its reason again")
    XCTAssertTrue(
      (blocked.label + blocked.value.debugDescription).contains("summary"),
      "the draft starts fresh, with a summary missing, got: \(blocked.label)")
    XCTAssertFalse(commit.isEnabled, "Commit starts disabled on a reopened dialog")

    // 9. A successful commit closes the dialog — the Changes list becoming clean is the
    // confirmation. Last, because it ends the sheet.
    typeSummary(app, "Add session login")
    commit.click()
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: sheet)], timeout: 20),
      .completed, "the dialog should close once the commit lands")
  }

  // MARK: - Render cap

  /// A cap on drawn rows is only safe if it cannot lie about the commit. The dialog draws 200, but
  /// the button must still claim — and the commit still record — every changed file.
  ///
  /// The count is `UITestFixture.changedFiles`: 8 base entries + the 250 `hugeChangeSet` ones. It
  /// read 257 until a DELETED source was added to the base list (so `PaneTitleBarUITests` could
  /// assert "Open File" goes disabled), and nothing here moved with it. Keep the two in step.
  func testTheRenderCapLimitsWhatIsDrawnNotWhatIsCommitted() throws {
    let app = launchedApp(extraArguments: ["-WorkroomUITestHugeChangeSet", "1"])
    openSheet(app)

    let notice = element(app, id: "commit.renderCapNotice")
    XCTAssertTrue(
      notice.waitForExistence(timeout: 10),
      "a truncated list must say so — a silent cap reads as 'this is everything'")

    typeSummary(app, "Vendor drop")
    let commit = button(app, id: "commit.commit")
    XCTAssertTrue(commit.waitForExistence(timeout: 5))
    XCTAssertTrue(
      commit.label.contains("258"),
      "the count must be the real total, not the drawn one, got: \(commit.label)")
  }

  // MARK: - Failure

  /// The defining moment. A hook's output is the most useful text in the whole taxonomy, so a
  /// rejected commit must keep the dialog open, keep the draft, and still carry the output.
  func testARejectedCommitKeepsTheSheetAndTheHookOutput() throws {
    let app = launchedApp(
      extraArguments: ["-WorkroomUITestSyncFailure", "1"])
    openSheet(app)
    typeSummary(app, "Add session login")

    button(app, id: "commit.commit").click()

    XCTAssertTrue(
      element(app, id: "commit.failure").waitForExistence(timeout: 10),
      "a rejected commit should report itself in the dialog")
    XCTAssertTrue(
      element(app, id: "commit.sheet").exists, "and the dialog must stay open, draft intact")
    XCTAssertTrue(
      element(app, id: "commit.summary").exists, "the typed summary is not thrown away")
    XCTAssertTrue(
      element(app, id: "commit.failure.detailsToggle").exists,
      "the hook's own output must be reachable, not flattened to one line")
  }
}
