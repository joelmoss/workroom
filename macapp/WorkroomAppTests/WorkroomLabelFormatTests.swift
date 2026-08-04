import XCTest

@testable import Workroom

/// `WorkroomLabel` (issue #132, T7): the one formatter behind the workroom tab chip's tooltip, the
/// split pane title bar's, a notification's origin line, and the quick-switcher rail. Four surfaces
/// used to build this string themselves and two had already drifted on the separator, so these tests
/// pin the shared format, the root/branch distinction, and the rail's prefix-dropping rule (D12).
@MainActor
final class WorkroomLabelFormatTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
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

  // MARK: Formatting

  func testFullTitleFormat() {
    XCTAssertEqual(
      WorkroomLabel(project: "platform", workroom: "fix-auth").full, "platform / fix-auth")
    XCTAssertEqual(
      WorkroomLabel(project: "platform").full, "platform", "a root shows only the project")
    XCTAssertEqual(
      WorkroomLabel(project: "platform", branch: "main").full, "platform",
      "a branch is state, never part of the title")
  }

  func testFullTitleMatchesNotificationSourceFormat() {
    var fox = Workroom(name: "fox", path: "/p/fox", vcsName: "workroom/fox", warnings: [])
    fox.label = "Auth"
    let projects = [Project(path: "/p", vcs: "git", workrooms: [fox])]
    // The regression this extraction exists to prevent: the chip's tooltip and the notification
    // origin line must be one format. Before T7 the chip rendered "p/Auth" and this rendered "p / Auth".
    XCTAssertEqual(
      AppStore.notificationSource(
        forTargetID: TerminalTarget.workroomID(project: "/p", name: "fox"), in: projects),
      WorkroomLabel(project: "p", workroom: "Auth").full)
  }

  func testDistinguishingSegment() {
    XCTAssertEqual(
      WorkroomLabel(project: "platform", workroom: "fix-auth").distinguishing, "fix-auth")
    XCTAssertEqual(
      WorkroomLabel(project: "platform", branch: "main").distinguishing, "platform",
      "a root is distinguished by its project, NOT its branch")
  }

  // MARK: Rail titles (D12)

  func testRailTitlesDropASharedProjectPrefix() {
    let labels = [
      WorkroomLabel(project: "workroom", workroom: "partitioned-crescent"),
      WorkroomLabel(project: "workroom", workroom: "partitioned-cascade"),
      WorkroomLabel(project: "workroom"),
    ]
    XCTAssertEqual(
      WorkroomLabel.railTitles(labels),
      ["partitioned-crescent", "partitioned-cascade", "workroom"],
      "one project on the rail ⇒ the prefix distinguishes nothing and costs width")
  }

  func testRailTitlesKeepTheProjectWhenItDisambiguates() {
    let labels = [
      WorkroomLabel(project: "workroom", workroom: "fox"),
      WorkroomLabel(project: "platform", workroom: "fox"),
    ]
    XCTAssertEqual(
      WorkroomLabel.railTitles(labels), ["workroom / fox", "platform / fox"],
      "two same-named workrooms across projects must not both read \"fox\"")
  }

  func testRailTitlesEdgeCases() {
    XCTAssertEqual(WorkroomLabel.railTitles([]), [])
    XCTAssertEqual(
      WorkroomLabel.railTitles([WorkroomLabel(project: "p", workroom: "fox")]), ["fox"],
      "a single card needs no prefix")
    XCTAssertEqual(
      WorkroomLabel.railTitles([
        WorkroomLabel(project: "p", workroom: "fox"), WorkroomLabel(project: "p"),
      ]).count, 2, "index-aligned with the input")
  }

  // MARK: Resolution — AppStore.label(for:)

  func testLabelResolvesWorkroomDisplayName() {
    let store = makeStore([project("/Users/me/platform", workrooms: ["fox"])])
    let sid = SidebarID.workroom(project: "/Users/me/platform", name: "fox")
    XCTAssertEqual(store.label(for: sid), WorkroomLabel(project: "platform", workroom: "fox"))
    // A relabel (issue #41) must show through — the resolver reads displayName, not the sid's name.
    store.setWorkroomLabel(store.projects[0].workrooms[0], in: store.projects[0], to: "Auth")
    XCTAssertEqual(store.label(for: sid).workroom, "Auth")
    XCTAssertEqual(store.label(for: sid).full, "platform / Auth")
  }

  func testLabelForRootCarriesBranchButNotInTheTitle() {
    let store = makeStore([project("/Users/me/platform", workrooms: [])])
    let sid = SidebarID.root(project: "/Users/me/platform")
    // Unresolved: RootPresentation.make renders "root" as a PLACEHOLDER — it must not pose as a branch.
    XCTAssertNil(store.label(for: sid).branch, "an unresolved ref has no branch")
    XCTAssertEqual(store.label(for: sid).full, "platform")
    store.rootRefs["/Users/me/platform"] = RootRef(branch: "main", kind: .branch)
    XCTAssertEqual(store.label(for: sid).branch, "main")
    XCTAssertNil(store.label(for: sid).workroom)
    XCTAssertEqual(store.label(for: sid).full, "platform", "branch stays out of the title")
  }

  func testLabelForUnknownProjectDegradesToEmptyProject() {
    let store = makeStore([])
    XCTAssertEqual(
      store.label(for: .workroom(project: "/gone", name: "fox")),
      WorkroomLabel(project: "gone", workroom: "fox"),
      "the path's last component is used even when the project isn't loaded (mid-reload race)")
  }
}
