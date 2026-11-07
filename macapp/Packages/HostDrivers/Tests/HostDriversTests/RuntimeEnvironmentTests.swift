import XCTest

@testable import HostDrivers

/// The environment a container runtime's CLI runs with (#586): `docker build` execs Docker
/// Desktop's credential helper by `PATH`, which a Finder-launched app's lacks.
final class RuntimeEnvironmentTests: XCTestCase {
  private let docker = URL(
    fileURLWithPath: "/Applications/Docker.app/Contents/Resources/bin/docker")
  private let resources = "/Applications/Docker.app/Contents/Resources/bin"
  private let userBin = URL(fileURLWithPath: "/Users/me/.docker/bin", isDirectory: true)

  private func path(_ environment: [String: String]) -> [String] {
    environment["PATH"]?.split(separator: ":").map(String.init) ?? []
  }

  /// The runtime's own folder, where Docker.app keeps `docker-credential-desktop`, comes first.
  func testRuntimeFolderComesFirst() {
    let environment = ContainerHostDriver.runtimeEnvironment(
      ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], runtime: docker, userBin: nil)
    XCTAssertEqual(path(environment), [resources, "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
  }

  /// A per-user install's `~/.docker/bin` comes after the runtime's folder, before the rest.
  func testUserBinComesSecond() {
    let environment = ContainerHostDriver.runtimeEnvironment(
      ["PATH": "/usr/bin:/bin"], runtime: docker, userBin: userBin)
    XCTAssertEqual(path(environment), [resources, userBin.path, "/usr/bin", "/bin"])
  }

  /// A folder already on `PATH` moves to the front rather than appearing twice, and a runtime that
  /// is itself in `~/.docker/bin` lists that folder once.
  func testNoFolderAppearsTwice() {
    let environment = ContainerHostDriver.runtimeEnvironment(
      ["PATH": "/usr/bin:\(userBin.path):\(resources):/bin:\(resources)"], runtime: docker,
      userBin: userBin)
    XCTAssertEqual(path(environment), [resources, userBin.path, "/usr/bin", "/bin"])

    let inUserBin = ContainerHostDriver.runtimeEnvironment(
      ["PATH": "/usr/bin"], runtime: userBin.appendingPathComponent("docker"), userBin: userBin)
    XCTAssertEqual(path(inUserBin), [userBin.path, "/usr/bin"])
  }

  /// An app with no `PATH` at all still hands the runtime its own folders.
  func testMissingPath() {
    XCTAssertEqual(
      path(ContainerHostDriver.runtimeEnvironment([:], runtime: docker, userBin: userBin)),
      [resources, userBin.path])
    XCTAssertEqual(
      path(ContainerHostDriver.runtimeEnvironment(["PATH": ""], runtime: docker, userBin: nil)),
      [resources])
  }

  /// The other variables pass through as they were, and nothing else of the app's does.
  func testOtherKeysUnchanged() {
    let inherited = [
      "HOME": "/Users/me", "PATH": "/usr/bin", "DOCKER_HOST": "unix:///tmp/d.sock",
      "DOCKER_CONTEXT": "colima", "DOCKER_CONFIG": "/Users/me/.dockercfg",
      "GH_TOKEN": "secret", "SHELL": "/bin/zsh",
    ]
    let environment = ContainerHostDriver.runtimeEnvironment(
      inherited, runtime: URL(fileURLWithPath: "/opt/homebrew/bin/container"), userBin: nil)
    XCTAssertEqual(
      environment,
      [
        "HOME": "/Users/me", "PATH": "/opt/homebrew/bin:/usr/bin",
        "DOCKER_HOST": "unix:///tmp/d.sock", "DOCKER_CONTEXT": "colima",
        "DOCKER_CONFIG": "/Users/me/.dockercfg",
      ])
  }
}
