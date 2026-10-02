import XCTest

@testable import Workroom

final class RootPresentationTests: XCTestCase {

  func testBranchFullStrength() {
    let s = RootPresentation.make(RootRef(branch: "main", kind: .branch))
    XCTAssertEqual(s.label, "main")
    XCTAssertFalse(s.dim)
    XCTAssertEqual(s.accessibility, "Project root, on main")
  }

  func testDetachedDimmed() {
    let s = RootPresentation.make(RootRef(branch: "a1b2c3d", kind: .detached))
    XCTAssertEqual(s.label, "a1b2c3d")
    XCTAssertTrue(s.dim)
    XCTAssertEqual(s.accessibility, "Project root, detached at a1b2c3d")
  }

  func testNoneDimmedRoot() {
    let s = RootPresentation.make(.unresolved)
    XCTAssertEqual(s.label, "root")
    XCTAssertTrue(s.dim)
    XCTAssertEqual(s.accessibility, "Project root")
  }

  func testEmptyBranchNormalizedToRoot() {
    // Go may emit "" rather than null; "" must not render as an empty label.
    let s = RootPresentation.make(RootRef(branch: "", kind: .branch))
    XCTAssertEqual(s.label, "root")
  }
}
