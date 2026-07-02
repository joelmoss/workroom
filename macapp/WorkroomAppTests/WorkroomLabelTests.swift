import Defaults
import XCTest

@testable import Workroom

/// Workroom display labels (issue #41): a display-only alias stored app-side in
/// `Defaults[.workroomLabels]`, injected onto the decoded `Workroom` and shown wherever the name is.
/// Covers the model alias, the store mutators/enrichment/GC/lifecycle, the pure notification
/// resolver, the sheet's validation, and the regressions that guarantee an *unlabelled* workroom
/// renders exactly as before.
@MainActor
final class WorkroomLabelTests: XCTestCase {

  override func setUp() {
    super.setUp()
    Defaults[.workroomLabels] = [:]
  }

  override func tearDown() {
    Defaults[.workroomLabels] = [:]
    super.tearDown()
  }

  private func makeStore(_ projects: [Project], shared: ProjectStore? = nil) -> AppStore {
    let store = AppStore(projectStore: shared)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  private func key(_ project: String, _ name: String) -> String {
    TerminalTarget.workroomID(project: project, name: name)
  }

  // MARK: Model — displayName / normalizedLabel

  func testDisplayNameFallsBackToNameWhenNoLabel() {
    let wr = Workroom(
      name: "bright-fox", path: "/p/bright-fox", vcsName: "workroom/bright-fox", warnings: [])
    XCTAssertEqual(wr.displayName, "bright-fox")
  }

  func testDisplayNameUsesLabelWhenSet() {
    var wr = Workroom(
      name: "bright-fox", path: "/p/bright-fox", vcsName: "workroom/bright-fox", warnings: [])
    wr.label = "Auth refactor"
    XCTAssertEqual(wr.displayName, "Auth refactor")
  }

  func testDisplayNameTrimsAndTreatsBlankAsNoLabel() {
    var wr = Workroom(name: "fox", path: "/p/fox", vcsName: "workroom/fox", warnings: [])
    wr.label = "   "
    XCTAssertEqual(wr.displayName, "fox", "whitespace-only label is no label")
    wr.label = "  Spaced  "
    XCTAssertEqual(wr.displayName, "Spaced", "surrounding whitespace is trimmed")
    wr.label = ""
    XCTAssertEqual(wr.displayName, "fox", "empty label is no label")
  }

  func testNormalizedLabel() {
    XCTAssertNil(Workroom.normalizedLabel(nil))
    XCTAssertNil(Workroom.normalizedLabel(""))
    XCTAssertNil(Workroom.normalizedLabel("   \n\t "))
    XCTAssertEqual(Workroom.normalizedLabel("  Hi  "), "Hi")
  }

  // MARK: Model — target title

  func testTargetTitleIsDisplayName() {
    var wr = Workroom(name: "fox", path: "/p/fox", vcsName: "workroom/fox", warnings: [])
    XCTAssertEqual(wr.target(inProject: "/p").title, "fox", "REGRESSION: unlabelled title == name")
    wr.label = "Auth"
    XCTAssertEqual(wr.target(inProject: "/p").title, "Auth")
    XCTAssertEqual(
      wr.target(inProject: "/p").id, key("/p", "fox"), "id stays keyed on the real name")
  }

  // MARK: View presentation — split title bar name source (issue #113 regression)

  func testSplitTitleNameUsesLabelAwareTargetTitle() {
    var wr = Workroom(name: "fox", path: "/p/fox", vcsName: "workroom/fox", warnings: [])
    let sid = SidebarID.workroom(project: "/p", name: "fox")
    // Unlabelled → the real name (must track displayName, never diverge).
    XCTAssertEqual(
      WorkroomSplitTitlePresentation.workroomName(sid: sid, target: wr.target(inProject: "/p")),
      "fox")
    // Labelled → the LABEL, not the raw sid name — the exact #113 bug.
    wr.label = "Auth"
    XCTAssertEqual(
      WorkroomSplitTitlePresentation.workroomName(sid: sid, target: wr.target(inProject: "/p")),
      "Auth", "REGRESSION #113: split title must show the label, not the raw workspace name")
    // A non-workroom member (project root) shows only the project label → nil workroom name.
    XCTAssertNil(
      WorkroomSplitTitlePresentation.workroomName(
        sid: .project("/p"), target: wr.target(inProject: "/p")))
  }

  // MARK: Store — displayName(forWorkroom:inProject:)

  func testStoreDisplayNameLookup() {
    let store = makeStore([project("/p", workrooms: ["fox"])])
    XCTAssertEqual(store.displayName(forWorkroom: "fox", inProject: "/p"), "fox")
    store.setWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0], to: "Auth")
    XCTAssertEqual(store.displayName(forWorkroom: "fox", inProject: "/p"), "Auth")
  }

  func testStoreDisplayNameFallsBackWhenWorkroomAbsent() {
    let store = makeStore([project("/p", workrooms: ["fox"])])
    XCTAssertEqual(
      store.displayName(forWorkroom: "ghost", inProject: "/p"), "ghost",
      "an unknown workroom resolves to the passed name (mid-reload race safety)")
    XCTAssertEqual(store.displayName(forWorkroom: "fox", inProject: "/nope"), "fox")
  }

  // MARK: Store — set / remove

  func testSetWorkroomLabelWritesNormalizedDefaultsAndUpdatesProjects() {
    let store = makeStore([project("/p", workrooms: ["fox"])])
    store.setWorkroomLabel(
      store.projects[0].workrooms[0], in: store.projects[0], to: "  Auth refactor  ")
    XCTAssertEqual(
      Defaults[.workroomLabels][key("/p", "fox")], "Auth refactor", "trimmed at the write boundary")
    XCTAssertEqual(
      store.projects[0].workrooms[0].label, "Auth refactor", "the live model is updated")
    XCTAssertEqual(store.projects[0].workrooms[0].displayName, "Auth refactor")
  }

  func testSetBlankLabelRemovesIt() {
    let store = makeStore([project("/p", workrooms: ["fox"])])
    let wr = store.projects[0].workrooms[0]
    store.setWorkroomLabel(wr, in: store.projects[0], to: "Auth")
    store.setWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0], to: "   ")
    XCTAssertNil(
      Defaults[.workroomLabels][key("/p", "fox")], "blank removes the key, never stores ''")
    XCTAssertEqual(store.projects[0].workrooms[0].displayName, "fox")
  }

  func testRemoveWorkroomLabelRestoresName() {
    let store = makeStore([project("/p", workrooms: ["fox"])])
    store.setWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0], to: "Auth")
    store.removeWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0])
    XCTAssertNil(Defaults[.workroomLabels][key("/p", "fox")])
    XCTAssertEqual(store.projects[0].workrooms[0].displayName, "fox")
  }

  // MARK: Store — enrichment + prune-on-load

  func testEnrichLabelsInjectsFromDefaults() {
    let store = makeStore([])
    Defaults[.workroomLabels] = [key("/p", "fox"): "Auth"]
    let enriched = store.enrichLabels([project("/p", workrooms: ["fox", "owl"])])
    XCTAssertEqual(enriched[0].workrooms.first { $0.name == "fox" }?.label, "Auth")
    XCTAssertNil(enriched[0].workrooms.first { $0.name == "owl" }?.label)
  }

  func testPruneOrphanedLabelsDropsKeysWithNoWorkroom() {
    let store = makeStore([])
    Defaults[.workroomLabels] = [
      key("/p", "fox"): "Auth",  // live
      key("/p", "gone"): "Stale",  // deleted externally
      key("/other", "x"): "Stale2",  // project not loaded
    ]
    store.pruneOrphanedLabels(keeping: [project("/p", workrooms: ["fox"])])
    XCTAssertEqual(
      Defaults[.workroomLabels], [key("/p", "fox"): "Auth"], "only the live label survives")
  }

  // MARK: Store — lifecycle cleanup

  func testWorkroomDeleteForgetsLabel() {
    let store = makeStore([project("/p", workrooms: ["fox", "owl"])])
    store.setWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0], to: "Auth")
    store.removeWorkroomLocally(store.projects[0].workrooms[0], in: store.projects[0])
    XCTAssertNil(
      Defaults[.workroomLabels][key("/p", "fox")], "deleting the workroom clears its label")
  }

  func testProjectDeleteForgetsAllItsLabels() {
    let store = makeStore([
      project("/p", workrooms: ["fox", "owl"]), project("/q", workrooms: ["cat"]),
    ])
    store.setWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0], to: "A")
    store.setWorkroomLabel(store.projects[0].workrooms[1], in: store.projects[0], to: "B")
    store.setWorkroomLabel(store.projects[1].workrooms[0], in: store.projects[1], to: "C")
    let p = store.projects.first { $0.id == "/p" }!
    _ = store.removeProjectLocally(p)
    XCTAssertNil(Defaults[.workroomLabels][key("/p", "fox")])
    XCTAssertNil(Defaults[.workroomLabels][key("/p", "owl")])
    XCTAssertEqual(
      Defaults[.workroomLabels][key("/q", "cat")], "C", "other projects' labels untouched")
  }

  // MARK: Notifications — pure resolver

  func testNotificationSourceUsesDisplayName() {
    var fox = Workroom(name: "fox", path: "/p/fox", vcsName: "workroom/fox", warnings: [])
    fox.label = "Auth"
    let projects = [Project(path: "/p", vcs: "git", workrooms: [fox])]
    XCTAssertEqual(
      AppStore.notificationSource(forTargetID: key("/p", "fox"), in: projects), "p / Auth")
    XCTAssertEqual(
      AppStore.notificationSource(forTargetID: TerminalTarget.rootID(project: "/p"), in: projects),
      "p")
    XCTAssertEqual(
      AppStore.notificationSource(forTargetID: key("/p", "ghost"), in: projects), "",
      "a since-deleted target resolves empty so callers fall back to the stored snapshot")
  }

  // MARK: Sheet validation

  func testSheetValidation() {
    typealias M = WorkroomLabelSheetModel
    // Blank / whitespace ⇒ disabled (removal is a separate menu action).
    XCTAssertFalse(M.validate(input: "", current: nil, siblingDisplayNames: []).canSubmit)
    XCTAssertFalse(M.validate(input: "   ", current: nil, siblingDisplayNames: []).canSubmit)
    // Unchanged ⇒ disabled.
    XCTAssertFalse(M.validate(input: "Auth", current: "Auth", siblingDisplayNames: []).canSubmit)
    XCTAssertFalse(
      M.validate(input: "  Auth ", current: "Auth", siblingDisplayNames: []).canSubmit,
      "trimmed-equal counts as unchanged")
    // Collides with a sibling's display name ⇒ disabled + flagged.
    let collide = M.validate(input: "owl", current: nil, siblingDisplayNames: ["owl", "cat"])
    XCTAssertFalse(collide.canSubmit)
    XCTAssertTrue(collide.collides)
    // A real, unique change ⇒ enabled.
    let ok = M.validate(input: "Auth refactor", current: nil, siblingDisplayNames: ["owl"])
    XCTAssertTrue(ok.canSubmit)
    XCTAssertFalse(ok.collides)
  }

  // MARK: Regressions — unlabelled rendering unchanged

  func testWindowTitleRegressionAndLabel() {
    let store = makeStore([project("/Users/me/proj", workrooms: ["fox"])])
    store.selectedTargetID = .workroom(project: "/Users/me/proj", name: "fox")
    XCTAssertEqual(store.windowTitle, "proj — fox", "REGRESSION: unlabelled title unchanged")
    store.setWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0], to: "Auth")
    XCTAssertEqual(store.windowTitle, "proj — Auth")
  }

  func testOpenPickerTitleAndSearch() {
    var fox = Workroom(name: "fox", path: "/p/fox", vcsName: "workroom/fox", warnings: [])
    fox.label = "Auth"
    let owl = Workroom(name: "owl", path: "/p/owl", vcsName: "workroom/owl", warnings: [])
    let targets = OpenPickerModel.targets(from: [
      Project(path: "/p", vcs: "git", workrooms: [fox, owl])
    ])
    let foxRow = targets.first { $0.name == "fox" }!
    let owlRow = targets.first { $0.name == "owl" }!
    XCTAssertEqual(foxRow.title, "Auth", "labelled row shows the label")
    XCTAssertEqual(foxRow.name, "fox", "real name retained for the a11y id / keying")
    XCTAssertEqual(owlRow.title, "owl", "REGRESSION: unlabelled row title == name")
    XCTAssertTrue(foxRow.searchText.contains("fox"), "still findable by real name")
    XCTAssertTrue(foxRow.searchText.contains("Auth"), "and by label")
    // Sorted by shown name: "Auth" < "owl".
    let workroomRows = targets.filter { !$0.isRoot }
    XCTAssertEqual(workroomRows.map(\.title), ["Auth", "owl"], "rows sort by displayName")
  }

  // MARK: Multi-window

  func testLabelIsVisibleAcrossWindowsSharingAProjectStore() {
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)
    a.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    // Seed once via the shared store (don't re-init b's projects — that would clobber it).
    a.projects = [project("/p", workrooms: ["fox"])]
    a.setWorkroomLabel(a.projects[0].workrooms[0], in: a.projects[0], to: "Auth")
    XCTAssertEqual(
      b.displayName(forWorkroom: "fox", inProject: "/p"), "Auth",
      "the other window sees the label via the shared ProjectStore")
  }
}
