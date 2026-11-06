import Foundation
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import HostDrivers

final class HostCapabilitiesTests: XCTestCase {
  /// Value: protects=a pane whose host no driver holds says it couldn't reach the host, and reads
  /// no attach a real driver recorded (ADR 0067); fails_when=it attaches, reads a last attach other
  /// than none, or counts its link as one a network change breaks; why_new=it replaces a
  /// `ContainerHostDriver` holding no host; seam=none; no_claim=the notice's wording
  func testAnUnreachableHostsPaneSaysWhyAndReadsNothing() {
    let driver = UnreachableHostDriver()
    let host = HostID.remote(UUID())
    XCTAssertThrowsError(
      try driver.attachCommand(
        to: host, session: UUID(), workingDirectory: "/w", restored: true, metadata: [],
        runCommand: nil)
    ) {
      XCTAssertEqual($0 as? HostDriverError, .unknownHost(host))
      XCTAssertEqual($0.localizedDescription, "This driver has no such host.")
    }
    XCTAssertEqual(driver.lastAttach(of: UUID(), on: host), .unrecorded)
    XCTAssertFalse(driver.hostRefusedLastAttach(of: UUID(), on: host))
    XCTAssertFalse(driver.linkCrossesNetwork)
  }

  /// Value: protects=only a container's pane link stays on this Mac, so a network change reattaches
  /// every other remote pane; fails_when=a driver's answer flips; why_new=it was a type check in the
  /// app; seam=none; no_claim=the reattach itself (GhosttySurfaceView)
  func testOnlyAContainersLinkStaysOnThisMac() {
    let directory = FileManager.default.temporaryDirectory
    XCTAssertFalse(ContainerHostDriver(hosts: [:], directory: directory).linkCrossesNetwork)
    XCTAssertTrue(Self.ssh(directory).linkCrossesNetwork)
  }

  /// Value: protects=an SSH host's descriptor carries what a relaunch reaches it by, and a reload
  /// takes it back; fails_when=record or adopt drops the destination or the home; why_new=new
  /// capability over `adopt(home:)`; seam=none; no_claim=the home's checks (SSHHostDriverTests)
  func testAnSSHHostsRecordIsWhatAReloadAdopts() throws {
    let directory = FileManager.default.temporaryDirectory
    let made = Self.ssh(directory)
    try made.adopt(home: "/home/joel")
    var descriptor = HostDescriptor(driver: HostKind.ssh.driver)
    made.record(made.hostID, in: &descriptor)
    XCTAssertEqual(descriptor.sshDestination, "myserver")
    XCTAssertEqual(descriptor.sshHome, "/home/joel")

    let reloaded = Self.ssh(directory)
    try reloaded.adopt(descriptor)
    XCTAssertEqual(reloaded.home, "/home/joel")
  }

  private static func ssh(_ directory: URL) -> SSHHostDriver {
    SSHHostDriver(
      configuration: .init(destination: "myserver", sshAgent: nil), directory: directory)
  }
}
