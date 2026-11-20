import AppKit
import XCTest

@testable import Workroom

/// `AppEnvironment.prohibitsActivation`: the unit-test host never activates.
@MainActor
final class TestHostActivationTests: XCTestCase {
  func testOnlyAHostedUnitRunProhibitsActivation() {
    XCTAssertTrue(
      AppEnvironment.prohibitsActivation(environment: ["XCTestConfigurationFilePath": "/x"]))
    XCTAssertFalse(
      AppEnvironment.prohibitsActivation(environment: [:]),
      "a fixture or XCUITest launch has no XCTestConfigurationFilePath and must activate")
  }

  func testThisTestHostCannotActivate() {
    // The real wiring: this process is the hosted app, so launch already set the policy.
    XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
    NSApp.activate(ignoringOtherApps: true)
    XCTAssertFalse(NSApp.isActive, "a test reaching NSApp.activate must not pull the host forward")
  }
}
