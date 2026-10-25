import HostDrivers
import WorkroomDomain
import XCTest

@testable import Workroom

/// `ContainerHostDriver` on Docker (#252, #308): containers made from a stock image, reached
/// through `docker exec`. Opt-in, on a Mac with Docker running:
///
///   TEST_RUNNER_WR_DOCKER_CONTAINER_TESTS=1 TEST_RUNNER_WR_LINUX_DAEMON=<workroomd-linux-<arch>> \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/ContainerProvisioningIntegrationTests
final class ContainerProvisioningIntegrationTests: ContainerIntegrationTestCase {
  override var dialect: ContainerHostDriver.Dialect { .docker }
  override var optIn: String { "WR_DOCKER_CONTAINER_TESTS" }

  func testAContainerServesAndDestroyingItLeavesNothing() async throws {
    try await aContainerServesAndDestroyingItLeavesNothing()
  }

  func testAStoppedContainerIsStartedAgain() async throws {
    try await aStoppedContainerIsStartedAgain()
  }

  func testACreateThatFailsAtEachStepLeavesNothing() async throws {
    try await aCreateThatFailsAtEachStepLeavesNothing()
  }

  func testACreateThatCannotRemoveItsContainerSaysWhatIsLeft() async throws {
    try await aCreateThatCannotRemoveItsContainerSaysWhatIsLeft()
  }

  func testAPaneIsShownItsLastScreenAfterARestart() async throws {
    try await aPaneIsShownItsLastScreenAfterARestart()
  }

  func testARunTabRunsItsCommand() async throws { try await aRunTabRunsItsCommand() }

  func testAStoppedRunPublishesItsStateWhileItsTerminalStaysOpen() async throws {
    try await aStoppedRunPublishesItsStateWhileItsTerminalStaysOpen()
  }

  func testALaterLaunchAdoptsARecordedContainer() async throws {
    try await aLaterLaunchAdoptsARecordedContainer()
  }

  func testTheSweepRemovesOnlyUnrecordedContainersPastTheirGrace() async throws {
    try await theSweepRemovesOnlyUnrecordedContainersPastTheirGrace()
  }

  func testConcurrentCreatesEachGetTheirOwnContainer() async throws {
    try await concurrentCreatesEachGetTheirOwnContainer()
  }

  func testAPortIsForwardedToThisMac() async throws { try await aPortIsForwardedToThisMac() }

  @MainActor
  func testGitAsksThisMacForCredentials() async throws { try await gitAsksThisMacForCredentials() }

  func testTheWorkroomsScriptsRunInTheContainer() async throws {
    try await theWorkroomsScriptsRunInTheContainer()
  }

  func testANewerBuildIsPlacedAndHandedOff() async throws {
    try await aNewerBuildIsPlacedAndHandedOff()
  }

  // Value: protects=a workroom an older build derived keeps the commit image it runs from through
  // every sweep, and deleting it removes that image; fails_when=destroy stops removing a record's
  // image or the sweep stops keeping a recorded host's; why_new=the derive tests that reached
  // these paths went with deriveFromBase; seam=none
  /// A host an older build derived from a base records the image it was run from, which only it
  /// uses: the sweep keeps that image while the host is recorded, and destroying the host takes the
  /// image with it. Docker only: Apple's derive was never shipped.
  func testAnOlderBuildsDerivedHostKeepsItsImageUntilItIsDestroyed() async throws {
    let earlier = driver(folder: "earlier")
    let host = try await create(earlier, image: try await gitImage(earlier))
    guard case .remote(let id) = host else { return XCTFail("not a remote host") }
    // As an older build's derive committed it: the driver's labels, and made long ago.
    let labels = [label!, "\(ContainerHostDriver.createdLabel)=0"].flatMap {
      ["--change", "LABEL \($0)"]
    }
    let image = try cli(["commit"] + labels + [ContainerHostDriver.containerName(id)])
    XCTAssertTrue(ContainerHostDriver.isImageID(image), image)
    let record = try XCTUnwrap(earlier.record(of: host))

    let later = driver(folder: "later")
    try later.adopt(
      id, ContainerHostRecord(user: record.user, image: image, context: record.context))
    for _ in 0..<2 {
      let failures = await later.sweep(keeping: [id], grace: 0)
      XCTAssertEqual(failures, [])
    }
    func exists() throws -> Bool {
      try cli(["image", "inspect", "--format", "{{.Id}}", image]) == image
    }
    XCTAssertTrue(try exists(), "the sweep took a recorded host's image")

    try await later.destroy(host)
    XCTAssertEqual(try ours(), [])
    XCTAssertFalse(try exists(), "destroying the host left its image")
  }

  /// A record naming an image that is not an older derive's commit is refused: `destroy` removes
  /// it by force.
  func testAdoptRefusesARecordWhoseImageIsNotAnImageID() throws {
    XCTAssertThrowsError(
      try driver().adopt(
        UUID(), ContainerHostRecord(user: "root", image: "debian:bookworm", context: nil)))
  }
}
