import XCTest

@testable import Workroom

/// The workroom pane title bar's trailing-control matrix (issue #139), kept pure and tested away from
/// SwiftUI for the same reason `WorkroomSplitTitlePresentation` is: the rules are easy to state and easy
/// to get subtly wrong in a view body, and a view can't be instantiated in a unit test.
///
/// The group divider is the reason this type takes "is there anything to show" as *inputs* rather than
/// letting each control decide for itself. A separator is only correct when both of its neighbours are
/// present, and either can be absent — no run command configured, or no supported editor installed.
final class WorkroomPaneToolbarPresentationTests: XCTestCase {
  private func controls(
    isMissing: Bool = false, projectPath: String? = "/a", hasEditor: Bool = true,
    multi: Bool = false
  ) -> WorkroomPaneToolbarPresentation.Controls {
    WorkroomPaneToolbarPresentation.controls(
      isMissing: isMissing, projectPath: projectPath, hasEditor: hasEditor, multi: multi)
  }

  /// The common case — a healthy solo workroom on a machine with an editor — shows both groups, the rule
  /// between them, and no way out of a split.
  func testSoloHealthyWorkroomShowsBothGroupsAndTheDivider() {
    XCTAssertEqual(
      controls(),
      .init(run: true, openIn: true, divider: true, removeFromSplit: false))
  }

  /// Run does **not** depend on a command being configured — that's the point. The button is always there
  /// for a present target, and pressing it with nothing set opens Project Settings with the warning, as
  /// ⌘R does. A configured command isn't an input here at all, which is what makes that unforgettable.
  func testRunIsNotGatedOnAConfiguredCommand() {
    // There is no `hasRunCommand` parameter to pass — the only inputs that can hide Run are a missing
    // directory and a target with no owning project.
    XCTAssertTrue(controls().run)
    XCTAssertTrue(controls(hasEditor: false).run)
    XCTAssertFalse(controls(isMissing: true).run)
    XCTAssertFalse(controls(projectPath: nil).run)
  }

  /// A vanished directory has nothing to open in an editor and nothing to run in. Leaving either visible
  /// would offer an action that can only fail — and the divider goes with them.
  func testMissingDirectoryHidesEverythingButTheWayOut() {
    let c = controls(isMissing: true, multi: true)
    XCTAssertFalse(c.run)
    XCTAssertFalse(c.openIn)
    XCTAssertFalse(c.divider)
    // The ✕ stays: popping it out of the split is the only way to get rid of a "Directory not found" pane.
    XCTAssertTrue(c.removeFromSplit)
  }

  /// No editor installed → no "Open in…", and **no divider**: a rule with nothing on its trailing side
  /// reads as a stray mark. This is the case the divider's gate exists for.
  func testNoEditorHidesTheOpenInGroupAndTheDivider() {
    let c = controls(hasEditor: false)
    XCTAssertTrue(c.run)
    XCTAssertFalse(c.openIn)
    XCTAssertFalse(c.divider)
  }

  /// Run needs an owning project to look its command up in (`Defaults[.runCommands]` is keyed by project
  /// path). "Open in…" only needs the target's own path, so it survives — and the divider does not.
  func testNoProjectPathHidesRunButKeepsOpenIn() {
    let c = controls(projectPath: nil)
    XCTAssertTrue(c.openIn)
    XCTAssertFalse(c.run)
    XCTAssertFalse(c.divider)
  }

  /// The ✕ is the one control that is genuinely split-only: a solo pane has no group to leave. It is
  /// independent of everything else.
  func testRemoveFromSplitTracksMembershipOnly() {
    XCTAssertTrue(controls(multi: true).removeFromSplit)
    XCTAssertFalse(controls(multi: false).removeFromSplit)
    XCTAssertTrue(controls(hasEditor: false, multi: true).removeFromSplit)
  }
}
