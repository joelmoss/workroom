import XCTest

@testable import Workroom

final class RemoteProvisioningTests: XCTestCase {
  /// The clone token reaches git as configuration in its environment, an `Authorization` header
  /// for github.com only, and nowhere a process list, a remote URL or a file would show it.
  func testTheCloneTokenReachesGitOnlyAsAGitHubHeaderInItsEnvironment() throws {
    let environment = RemoteProvisioning.cloneEnvironment(token: "ghs_secret")

    XCTAssertEqual(environment["GIT_CONFIG_COUNT"], "1")
    XCTAssertEqual(environment["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraHeader")
    let value = try XCTUnwrap(environment["GIT_CONFIG_VALUE_0"])
    XCTAssertTrue(value.hasPrefix("Authorization: Basic "))
    let credentials = try XCTUnwrap(
      Data(base64Encoded: String(value.dropFirst("Authorization: Basic ".count))))
    XCTAssertEqual(String(decoding: credentials, as: UTF8.self), "x-access-token:ghs_secret")
    XCTAssertFalse(environment.values.contains { $0.contains("ghs_secret") })
  }
}
