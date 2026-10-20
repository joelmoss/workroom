import XCTest

@testable import HostDrivers

/// Telling a runtime that didn't answer from a missing image, by what its CLI prints (#309).
final class RuntimeDownTests: XCTestCase {
  /// Docker 29's words for a stopped daemon and an unopenable socket (measured with 29.8.1), and
  /// the older CLI's.
  func testDockerNotAnsweringIsRuntimeDown() {
    for said in [
      "docker image exited 1: failed to connect to the docker API at unix:///Users/me/.docker/run/"
        + "docker.sock; check if the path is correct and if the daemon is running: dial unix "
        + "/Users/me/.docker/run/docker.sock: connect: no such file or directory",
      "docker pull exited 1: permission denied while trying to connect to the docker API at "
        + "unix:///Users/me/.docker/run/docker.sock",
      "docker image exited 1: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. "
        + "Is the docker daemon running?",
    ] {
      let down = ContainerHostDriver.runtimeDown(said, apple: false)
      XCTAssertEqual(down?.localizedDescription.contains("Docker didn't answer"), true, said)
    }
  }

  /// A runtime that answered: the image is missing, or the registry refused it.
  func testDockerAnsweringIsNotRuntimeDown() {
    XCTAssertNil(
      ContainerHostDriver.runtimeDown(
        "docker image exited 1: Error response from daemon: No such image: workroom-host",
        apple: false))
    XCTAssertNil(
      ContainerHostDriver.runtimeDown(
        "docker pull exited 1: Error response from daemon: pull access denied for workroom-host",
        apple: false))
  }

  /// Apple's `container` with its system service stopped (measured with 1.5.0).
  func testAppleServiceStoppedIsRuntimeDown() {
    let said =
      "container image exited 1: Error: interrupted: \"XPC connection error: Connection invalid\"\n"
      + "Ensure container system service has been started with `container system start`."
    let down = ContainerHostDriver.runtimeDown(said, apple: true)
    XCTAssertEqual(down?.localizedDescription.contains("container system start"), true)
  }
}
