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
        runtime: runtime, image: "unused", user: "",
        daemonSocket: DaemonInstall.defaultSocket, labels: ["workroom.provisioner=test"],
        daemon: { _ in nil }))

    let prepare = { (fromRoot: Bool) in
      _ = try await ContainerCreate.prepare(
        ContainerCreate.File(
          path: ".devcontainer/devcontainer.json", data: json,
          config: try DevContainerConfig.parse(json), fromRoot: fromRoot),
        project: project.path, repository: "app", start: "HEAD", runtime: .docker,
        driver: driver, defaultImage: "unused", environment: [:],
        featureCache: directory.appendingPathComponent("features"))
    }

    try await prepare(true)
    XCTAssertEqual(try String(contentsOf: built, encoding: .utf8), "FROM uncommitted-base\n")

    // From the base commit, which has no Dockerfile, the export says so rather than the build
    // failing on a missing file.
    do {
      try await prepare(false)
      XCTFail("a Dockerfile the base commit doesn't have was built")
    } catch ContainerCreate.Failure.exportFailed {
    } catch {
      XCTFail("not the export's failure: \(error)")
    }
  }

  // Value: protects=a devcontainer.json's build context and dockerfile stay inside the repository;
  // fails_when=`..` past the root is followed, or `.`/`..` within it stop collapsing;
  // why_new=no test named the guard; seam=none; no_claim=git archive itself
  /// Paths are the file's folder's, collapsed; one that climbs above the repository is refused
  /// before anything reads it.
  func testABuildPathCannotLeaveTheRepository() throws {
    XCTAssertEqual(try ContainerCreate.repositoryPath(".devcontainer", "..", file: "f"), ".")
    XCTAssertEqual(
      try ContainerCreate.repositoryPath(".devcontainer", "./a/../Dockerfile", file: "f"),
      ".devcontainer/Dockerfile")
    XCTAssertEqual(try ContainerCreate.repositoryPath("", ".", file: "f"), ".")
    for (folder, path) in [(".devcontainer", "../.."), ("", ".."), ("a", "../../b")] {
      XCTAssertThrowsError(try ContainerCreate.repositoryPath(folder, path, file: "f")) {
        XCTAssertEqual(
          $0 as? ContainerCreate.Failure, .outsideRepository(file: "f", path: path), path)
      }
    }
  }

  // Value: protects=initializeCommand runs on this Mac in the project's folder, and its failure stops the create before the runtime is touched;
  // fails_when=it runs elsewhere, its exit status is ignored, or the image is pulled first;
  // why_new=no test ran initializeCommand; seam=stub runtime; no_claim=a real image pull
  /// A file that names neither an image nor a build has none to make, and says so.
  func testInitializeCommandRunsOnThisMacFirstAndItsFailureStopsTheCreate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-create-\(UUID().uuidString)", isDirectory: true)
    let project = directory.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let calls = directory.appendingPathComponent("calls")
    let runtime = directory.appendingPathComponent("docker")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> \(PosixShell.quoted(calls.path))
    [ "$1" = image ] && echo '{}'
    exit 0
    """.write(to: runtime, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "unused", user: "",
        daemonSocket: DaemonInstall.defaultSocket, labels: ["workroom.provisioner=test"],
        daemon: { _ in nil }))
    let prepare = { (json: String) in
      _ = try await ContainerCreate.prepare(
        ContainerCreate.File(
          path: ".devcontainer/devcontainer.json", data: Data(json.utf8),
          config: try DevContainerConfig.parse(Data(json.utf8))),
        project: project.path, repository: "app", start: "HEAD", runtime: .docker,
        driver: driver, defaultImage: "unused", environment: [:],
        featureCache: directory.appendingPathComponent("features"))
    }

    do {
      try await prepare(#"{"image": "x", "initializeCommand": "echo boom >&2; exit 3"}"#)
      XCTFail("a failed initializeCommand went on")
    } catch {
      XCTAssertEqual(error as? ContainerCreate.Failure, .initializeFailed("it exited 3: boom"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "the runtime was asked")

    try await prepare(
      #"{"image": "x", "initializeCommand": "pwd -P > ran; echo ${localWorkspaceFolderBasename} > name"}"#
    )
    XCTAssertEqual(
      try String(contentsOf: project.appendingPathComponent("name"), encoding: .utf8), "project\n",
      "the command's variables weren't substituted")
    let ran = try String(contentsOf: project.appendingPathComponent("ran"), encoding: .utf8)
      .trimmingCharacters(in: .newlines)
    XCTAssertEqual(
      URL(fileURLWithPath: ran).resolvingSymlinksInPath().path,
      project.resolvingSymlinksInPath().path)

    // The container's own lifecycle commands are substituted too, in the scripts it will run.
    let made = try await ContainerCreate.prepare(
      ContainerCreate.File(
        path: ".devcontainer/devcontainer.json",
        data: Data(#"{"image": "x", "onCreateCommand": "cd ${containerWorkspaceFolder}"}"#.utf8),
        config: try DevContainerConfig.parse(
          Data(#"{"image": "x", "onCreateCommand": "cd ${containerWorkspaceFolder}"}"#.utf8))),
      project: project.path, repository: "app", start: "HEAD", runtime: .docker,
      driver: driver, defaultImage: "unused", environment: [:],
      featureCache: directory.appendingPathComponent("features"))
    let script = try XCTUnwrap(made.hooks.first?.script)
    XCTAssertTrue(script.contains("cd /workspaces/app"), script)

    do {
      try await prepare(#"{"name": "no image"}"#)
      XCTFail("a file with no image was made into a container")
    } catch {
      XCTAssertEqual(
        error as? ContainerCreate.Failure, .noImage(file: ".devcontainer/devcontainer.json"))
    }
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
