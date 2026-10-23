import HostDrivers
import XCTest

@testable import Workroom

/// `ContainerHostDriver` on Apple's real `container` runtime (#309, #308): the same cases as
/// Docker's (`ContainerIntegrationTestCase`). Opt-in: Apple's runtime needs Apple silicon and a VM
/// per container, which CI's macOS runners can't give it, so these run on a Mac by hand before a
/// release, with `container system start` run first:
///
///   TEST_RUNNER_WR_APPLE_CONTAINER_TESTS=1 TEST_RUNNER_WR_LINUX_DAEMON=<workroomd-linux-aarch64> \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/AppleContainerIntegrationTests
final class AppleContainerIntegrationTests: ContainerIntegrationTestCase {
  override var dialect: ContainerHostDriver.Dialect { .apple }
  override var optIn: String { "WR_APPLE_CONTAINER_TESTS" }

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
}
