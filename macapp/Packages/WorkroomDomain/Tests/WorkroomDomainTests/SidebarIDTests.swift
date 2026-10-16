import Foundation
import WorkroomDomain
import XCTest

final class SidebarIDTests: XCTestCase {
  func testCreationBelongsToItsProjectOnly() {
    let id = SidebarID.creation(project: "/p", id: UUID())
    XCTAssertTrue(id.belongsToProject("/p"))
    XCTAssertFalse(id.belongsToProject("/q"))
  }
}
