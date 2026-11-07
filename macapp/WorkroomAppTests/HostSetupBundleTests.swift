import HostDrivers
import XCTest

@testable import Workroom

/// The host-setup scripts a provider create runs are in the app's bundle, where `HostSetup.bundled`
/// finds them. The drivers' own tests read them from the checkout.
final class HostSetupBundleTests: XCTestCase {
  func testTheSetupScriptShipsInTheBundle() throws {
    let script = try HostSetup.bundled.systemdScript()
    XCTAssertTrue(script.contains("workroom-daemon.service"))
  }

  // Value: protects=every exe.dev create can set up the VM's git; fails_when=the script is renamed,
  // moved out of host-setup, or the name it is loaded by drifts; why_new=exedev-github_test.sh reads
  // the source tree, not the app bundle, and the live suite is not run in CI; seam=none;
  // no_claim=what the script does on a VM
  /// The git setup a create runs on each VM ships in the app's bundle.
  func testTheGitHubSetupScriptShipsInTheBundle() throws {
    XCTAssertTrue(try HostSetup.bundled.exeDevGitHubScript().contains("github.int.exe.xyz"))
  }
}
