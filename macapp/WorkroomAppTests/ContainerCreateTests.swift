import HostDrivers
import WorkroomSystem
import XCTest

@testable import Workroom

final class ContainerCreateTests: XCTestCase {
  // Value: protects=a devcontainer.json only the project root has (not pushed yet) builds from the root's own Dockerfile;
  // fails_when=the build context is exported from the base commit whatever the file's origin;
  // why_new=the live suites only make containers from committed configs; seam=stub runtime; no_claim=what the runtime builds from it
  /// A devcontainer.json the base commit doesn't have is the root's copy (eng review S3), so its
  /// Dockerfile and build context are the root's too, committed or not: read from the base commit
  /// they would be missing, and the build would fail.
  func testARootConfigBuildsFromTheRootsOwnDockerfile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-create-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let project = directory.appendingPathComponent("project", isDirectory: true)
    let config = project.appendingPathComponent(".devcontainer", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try git(["init", "-q"], in: project)
    try git(
      ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base"],
      in: project)
    // Written after the commit: only the root has them.
    try "FROM uncommitted-base\n".write(
      to: config.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    let json = Data(#"{"build": {"dockerfile": "Dockerfile"}}"#.utf8)

    // The stub keeps the Dockerfile each build is handed, and answers the image inspect.
    let built = directory.appendingPathComponent("built")
    let runtime = directory.appendingPathComponent("docker")
    try """
    #!/bin/sh
    case "$1" in
      build) while [ "$1" != --file ]; do shift; done; cat "$2" >> \(PosixShell.quoted(built.path)) ;;
      image) echo '{}' ;;
    esac
    """.write(to: runtime, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "unused", user: "", identityFile: "", publicKey: "",
        daemonSocket: DaemonInstall.defaultSocket, labels: ["workroom.provisioner=test"],
        daemon: { _ in nil }))

    _ = try await ContainerCreate.prepare(
      ContainerCreate.File(
        path: ".devcontainer/devcontainer.json", data: json,
        config: try DevContainerConfig.parse(json), fromRoot: true),
      project: project.path, repository: "app", start: "HEAD", runtime: .docker, driver: driver,
      defaultImage: "unused", environment: [:],
      featureCache: directory.appendingPathComponent("features"))

    XCTAssertEqual(try String(contentsOf: built, encoding: .utf8), "FROM uncommitted-base\n")
  }

  private func git(_ arguments: [String], in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
  }
}
