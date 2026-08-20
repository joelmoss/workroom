import Foundation
import XCTest

@testable import Workroom

/// Pure-rule tests for the onboarding wizard's show-gate (issue #151), mirroring
/// `AddProjectSheetModelTests` — no SwiftUI rendering, no window.
final class OnboardingGateTests: XCTestCase {

  func testShowsOnFreshInstallWithNoProjects() {
    XCTAssertTrue(
      OnboardingGate.shouldShow(hasCompleted: false, projectsEmpty: true, override: nil))
  }

  func testHiddenOnceCompleted() {
    XCTAssertFalse(
      OnboardingGate.shouldShow(hasCompleted: true, projectsEmpty: true, override: nil))
  }

  func testHiddenWhenAProjectAlreadyExists() {
    XCTAssertFalse(
      OnboardingGate.shouldShow(hasCompleted: false, projectsEmpty: false, override: nil))
  }

  func testHiddenWhenCompletedAndAProjectExists() {
    XCTAssertFalse(
      OnboardingGate.shouldShow(hasCompleted: true, projectsEmpty: false, override: nil))
  }

  func testOverrideForcesShowRegardlessOfState() {
    XCTAssertTrue(
      OnboardingGate.shouldShow(hasCompleted: true, projectsEmpty: false, override: true))
  }

  func testOverrideForcesHideRegardlessOfState() {
    XCTAssertFalse(
      OnboardingGate.shouldShow(hasCompleted: false, projectsEmpty: true, override: false))
  }

  // MARK: mightShow — the synchronous, pre-bootstrap approximation driving whether the launch
  // window hides itself before `projectsEmpty` is known.

  func testMightShowIsTrueWhenNotCompleted() {
    XCTAssertTrue(OnboardingGate.mightShow(hasCompleted: false, override: nil))
  }

  func testMightShowIsFalseOnceCompleted() {
    XCTAssertFalse(OnboardingGate.mightShow(hasCompleted: true, override: nil))
  }

  func testMightShowOverrideForcesTrueRegardlessOfCompletion() {
    XCTAssertTrue(OnboardingGate.mightShow(hasCompleted: true, override: true))
  }

  func testMightShowOverrideForcesFalseRegardlessOfCompletion() {
    XCTAssertFalse(OnboardingGate.mightShow(hasCompleted: false, override: false))
  }
}
