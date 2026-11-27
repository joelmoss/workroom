import XCTest

/// The toast a restored pane shows when its gone session's program resumes (ADR 0082, #825), on
/// the fixture workroom's first terminal, which `-WorkroomUITestResume` puts in the state a
/// launch that handed its record to the relay leaves, before its daemon says how it went. No
/// daemon is involved: the status goes straight into the monitor, and from there through the same
/// binding and pane as a real status event's.
///
/// The toast is one accessibility element whose label is its message (`PaneNoticeToast`), so the
/// label is what is asserted.
final class ResumeToastUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp(resume: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestResume", resume]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func toast(_ app: XCUIApplication, _ message: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", message))
      .firstMatch
  }

  /// Value: protects=a resumed pane saying "Resumed Claude Code" once its daemon says the program
  /// started; fails_when=the binding stops passing `resumeStarted` to the pane, the pane stops
  /// toasting it, or the toast says something else; why_new=new (#825, an acceptance criterion);
  /// seam=`-WorkroomUITestResume started`
  func testAResumedPaneSaysItResumed() {
    let app = launchedApp(resume: "started")
    XCTAssertTrue(
      toast(app, "Resumed Claude Code").waitForExistence(timeout: 15),
      "the pane's toast says the program resumed")
    XCTAssertFalse(toast(app, "Couldn't resume Claude Code").exists)
  }

  /// Value: protects=a pane whose resumed program exited with an error at once saying "Couldn't
  /// resume Claude Code" in place of "Resumed"; fails_when=the binding stops passing
  /// `resumeFailed` to the pane, or the pane leaves the "Resumed" toast up; why_new=new (#825, an
  /// acceptance criterion); seam=`-WorkroomUITestResume failed`
  func testAPaneWhoseResumeFailedSaysSo() {
    let app = launchedApp(resume: "failed")
    XCTAssertTrue(
      toast(app, "Couldn't resume Claude Code").waitForExistence(timeout: 15),
      "the pane's toast says the program couldn't be resumed")
    XCTAssertFalse(toast(app, "Resumed Claude Code").exists, "the failure replaced it")
  }
}
