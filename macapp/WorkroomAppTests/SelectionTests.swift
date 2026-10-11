import WorkroomDomain
import XCTest

@testable import Workroom

final class SelectionTests: XCTestCase {

  /// Guards D4: a load/refresh must never auto-select a root (or any target). The store's
  /// `apply` routes selection through `validatedSelection`, which can only return the
  /// existing selection or nil — never a fabricated one.
  func testValidatedSelectionNeverAutoSelects() {
    let proj = Project(path: "/a", vcs: "git", workrooms: [])

    // No prior selection stays nil — the root is NOT auto-selected.
    XCTAssertNil(AppStore.validatedSelection(nil, in: [proj]))

    // A still-valid root selection is preserved (the user picked it).
    XCTAssertEqual(
      AppStore.validatedSelection(.root(project: "/a"), in: [proj]),
      .root(project: "/a"))

    // A selection whose project/workroom no longer exists is dropped.
    XCTAssertNil(AppStore.validatedSelection(.root(project: "/gone"), in: [proj]))
    XCTAssertNil(AppStore.validatedSelection(.workroom(project: "/a", name: "missing"), in: [proj]))
  }

  func testValidatedSelectionKeepsExistingWorkroom() {
    let wr = Workroom(name: "sunny", path: "/wr/sunny", vcsName: "workroom/sunny", warnings: [])
    let proj = Project(path: "/a", vcs: "git", workrooms: [wr])
    XCTAssertEqual(
      AppStore.validatedSelection(.workroom(project: "/a", name: "sunny"), in: [proj]),
      .workroom(project: "/a", name: "sunny"))
  }
}
