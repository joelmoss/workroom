import Defaults
import XCTest

@testable import Workroom

/// `SettingsPane` drives the Settings-window sidebar. Two things must hold: `allCases` is the sidebar
/// order (a silent reorder would move the panes), and a stored raw string that matches no case falls
/// back to `.general` (a rename or corrupt `Defaults` value must not crash or blank the window). The
/// fallback is provided by `Defaults` + `PreferRawRepresentable` — this pins it.
final class SettingsPaneTests: XCTestCase {

  /// The raw UserDefaults key behind `Defaults.Keys.settingsSelectedPane` — used to save/restore the
  /// real stored value so the test never leaks into the user's defaults, and to inject a corrupt one.
  private let key = "settings.selectedPane"
  private var saved: Any?

  override func setUp() {
    super.setUp()
    saved = UserDefaults.app.object(forKey: key)
  }

  override func tearDown() {
    if let saved {
      UserDefaults.app.set(saved, forKey: key)
    } else {
      UserDefaults.app.removeObject(forKey: key)
    }
    super.tearDown()
  }

  func testAllCasesOrderMatchesSidebarOrder() {
    XCTAssertEqual(
      SettingsPane.allCases,
      [.general, .notifications, .appearance, .terminal, .agent, .projects, .remoteHosts, .about])
  }

  func testEveryCaseHasNonEmptyLabelAndSystemImage() {
    for pane in SettingsPane.allCases {
      XCTAssertFalse(pane.label.isEmpty, "\(pane) has an empty label")
      XCTAssertFalse(pane.systemImage.isEmpty, "\(pane) has an empty systemImage")
    }
  }

  func testDefaultsToGeneralWhenUnset() {
    UserDefaults.app.removeObject(forKey: key)
    XCTAssertEqual(Defaults[.settingsSelectedPane], .general)
  }

  /// Value: protects=the Settings header's back and forward buttons walk the panes and projects visited, as
  /// System Settings' do; fails_when=back forgets a pane, forward survives a new choice, or choosing
  /// the open pane adds a step; why_new=new history; seam=none; no_claim=the buttons' rendering
  func testBackAndForwardWalkThePlacesVisited() {
    let general = SettingsLocation(pane: .general)
    let terminal = SettingsLocation(pane: .terminal)
    let projects = SettingsLocation(pane: .projects)
    let project = SettingsLocation(pane: .projects, project: "/a")
    var history = SettingsHistory()
    XCTAssertFalse(history.canGoBack)
    history.leave(general, for: general)
    XCTAssertFalse(history.canGoBack, "choosing where you are added a step")
    history.leave(general, for: terminal)
    history.leave(terminal, for: projects)
    history.leave(projects, for: project)
    XCTAssertEqual(history.goBack(from: project), projects, "back from a project skipped its list")
    XCTAssertEqual(history.goForward(from: projects), project, "forward lost the project")
    XCTAssertEqual(history.goBack(from: project), projects)
    XCTAssertEqual(history.goBack(from: projects), terminal)
    XCTAssertEqual(history.goBack(from: terminal), general)
    XCTAssertNil(history.goBack(from: general))
    XCTAssertEqual(history.goForward(from: general), terminal)
    history.leave(terminal, for: SettingsLocation(pane: .agent))
    XCTAssertFalse(history.canGoForward, "a new choice kept the old forward steps")
    XCTAssertEqual(history.goBack(from: SettingsLocation(pane: .agent)), terminal)
  }

  /// Value: protects=a main window's request opens Settings on that project, warned only when Run
  /// found no command; fails_when=the pane isn't switched, an open window isn't told, or a plain
  /// request keeps an earlier warning; why_new=Project Settings moved into Settings; seam=none;
  /// no_claim=the window opening
  @MainActor
  func testAProjectRequestShowsThatProjectWarnedOnlyForRun() {
    let route = SettingsRoute()
    Defaults[.settingsSelectedPane] = .general
    route.show(project: "/a", runWarning: true)
    XCTAssertEqual(Defaults[.settingsSelectedPane], .projects)
    XCTAssertEqual(route.takeRequest(), "/a")
    XCTAssertNil(route.takeRequest(), "a request was gone to twice")
    XCTAssertEqual(route.warnedProject, "/a")
    XCTAssertEqual(route.requests, 1)
    route.leave(project: "/a")
    XCTAssertNil(route.warnedProject, "leaving the project kept Run's warning")
    route.show(project: "/a", runWarning: true)
    route.show(project: "/a", runWarning: false)
    XCTAssertNil(route.warnedProject, "a plain request kept Run's warning")
    XCTAssertEqual(route.requests, 3, "an open Settings window wasn't told")
  }

  /// A `PreferRawRepresentable` enum persists as its bare raw string, so a corrupt/renamed value is
  /// simulated by writing a plain string straight to the suite — it can't be injected through the
  /// typed `Key`. Deserialising it yields `nil`, and `Defaults` falls back to the key's default.
  func testCorruptStoredValueFallsBackToGeneral() {
    UserDefaults.app.set("bogus", forKey: key)
    XCTAssertEqual(Defaults[.settingsSelectedPane], .general)
  }
}

/// Settings ▸ Projects saves only what was edited (#575 review).
final class ProjectSettingsDraftTests: XCTestCase {
  /// Value: protects=leaving a project's settings never writes back a base branch changed
  /// elsewhere; fails_when=an untouched field saves its stale value over the CLI's change;
  /// why_new=review finding (Codex, both passes); seam=none; no_claim=the CLI write
  func testAnUntouchedBaseBranchFollowsAChangeMadeElsewhere() {
    var draft = ProjectSettingsDraft(run: .empty, baseBranch: "main")
    XCTAssertNil(draft.branchToSave(), "an untouched field saved")

    draft.branchSaved("develop")
    XCTAssertEqual(draft.baseBranch, "develop")
    XCTAssertNil(draft.branchToSave(), "the stale branch was written back")

    draft.baseBranch = "release "
    XCTAssertEqual(draft.branchToSave(), "release")
    XCTAssertNil(draft.branchToSave(), "one edit saved twice")
  }

  /// Value: protects=a base branch the CLI rejects isn't treated as saved: its error is kept to
  /// show, and Return tries again; fails_when=the draft counts a send as saved, so the field shows
  /// a branch new workrooms don't use and nothing retries; why_new=review finding (Codex);
  /// seam=none; no_claim=the CLI's validation
  func testARejectedBaseBranchIsRetriedAndItsErrorKept() {
    var draft = ProjectSettingsDraft(run: .empty, baseBranch: "main")
    draft.baseBranch = "featur"
    XCTAssertEqual(draft.branchToSave(), "featur")
    XCTAssertNil(draft.branchToSave(), "a save under way was sent again")

    draft.branchSaveEnded("featur", error: "No branch featur on origin.")
    XCTAssertEqual(draft.branchError, "No branch featur on origin.")
    XCTAssertEqual(draft.branchToSave(), "featur", "a rejected branch wasn't retried")

    draft.branchSaveEnded("featur", error: nil)
    XCTAssertNil(draft.branchError)
    XCTAssertNil(draft.branchToSave(), "an accepted branch was saved again")
  }

  /// Value: protects=changing a base branch back while its save is under way saves the change
  /// back, and the save landing doesn't overwrite the field; fails_when=the revert matches the old
  /// saved value so nothing is sent, and the reload puts the superseded branch in the field;
  /// why_new=review finding (Codex, adversarial); seam=none; no_claim=the CLI write
  func testRevertingABaseBranchWhileItSavesSavesTheRevert() {
    var draft = ProjectSettingsDraft(run: .empty, baseBranch: "main")
    draft.baseBranch = "develop"
    XCTAssertEqual(draft.branchToSave(), "develop")
    draft.baseBranch = "main"
    XCTAssertEqual(draft.branchToSave(), "main", "the change back wasn't sent")

    draft.branchSaved("develop")  // the first save's reload lands
    XCTAssertEqual(draft.baseBranch, "main", "the landing save overwrote the field")
    draft.branchSaveEnded("develop", error: nil)
    draft.branchSaveEnded("main", error: nil)
    XCTAssertNil(draft.branchToSave())
  }

  /// Value: protects=a refusal's warning goes once the field is back to the saved branch;
  /// fails_when=the warning stays beside a branch that is saved; why_new=review finding
  /// (maintainability, testing, state machines); seam=none; no_claim=the icon's rendering
  func testARefusalsWarningGoesWhenTheFieldIsBackToTheSavedBranch() {
    var draft = ProjectSettingsDraft(run: .empty, baseBranch: "main")
    draft.baseBranch = "featur"
    _ = draft.branchToSave()
    draft.branchSaveEnded("featur", error: "No branch featur on origin.")
    draft.baseBranch = "main"
    XCTAssertNil(draft.branchToSave())
    XCTAssertNil(draft.branchError, "the warning stayed on a saved branch")
  }

  /// Value: protects=a half-typed base branch survives a change made elsewhere and is still
  /// saved; fails_when=an outside change overwrites what you're typing; why_new=review finding
  /// (testing); seam=none; no_claim=the CLI write
  func testATypedBaseBranchSurvivesAChangeMadeElsewhere() {
    var draft = ProjectSettingsDraft(run: .empty, baseBranch: "main")
    draft.baseBranch = "feat"
    draft.branchSaved("develop")
    XCTAssertEqual(draft.baseBranch, "feat", "an outside change overwrote the typing")
    XCTAssertEqual(draft.branchToSave(), "feat")
  }

  /// Value: protects=clearing the run command to retype it keeps auto-run, and no auto-run is
  /// saved without a command; fails_when=auto-run is lost on a clear, or a blank command saves
  /// auto-run on; why_new=review finding (Claude adversarial); seam=none; no_claim=the toggle
  func testClearingTheCommandToRetypeItKeepsAutoRun() {
    var draft = ProjectSettingsDraft(
      run: RunConfig(command: "npm run dev", autoRun: true), baseBranch: nil)
    XCTAssertNil(draft.runToSave(), "an untouched run config saved")

    draft.command = ""
    XCTAssertEqual(draft.runToSave(), RunConfig(command: "", autoRun: false))
    XCTAssertTrue(draft.autoRun, "clearing the command turned auto-run off")

    draft.command = "bin/dev"
    XCTAssertEqual(draft.runToSave(), RunConfig(command: "bin/dev", autoRun: true))
  }
}
