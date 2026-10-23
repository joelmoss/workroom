import WorkroomDomain
import XCTest

@testable import HostDrivers

/// Making a container any image will do for (#308): `ContainerHostDriver.create(spec:)` against a
/// stub runtime, a script that logs each call and answers as each test says, so the real argument
/// lists, the daemon's placement and the checks are what run.
final class ContainerHostDriverExecTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// A runtime that logs each call's arguments (one call a line, fields split by a unit
  /// separator), keeps `cp -`'s tar, and answers by the shell `case` arms in `answers`.
  private func stubRuntime(_ answers: String = "") throws -> URL {
    let script = directory.appendingPathComponent("runtime")
    try """
    #!/bin/sh
    log=\(directory.appendingPathComponent("calls").path)
    ( for a in "$@"; do printf '%s\\037' "$a"; done; printf '\\n' ) >> "$log"
    case "$*" in
      *"cp - "*) cat > \(directory.appendingPathComponent("copied.tar").path) ;;
    esac
    case "$*" in
    \(answers)
      *) exit 0 ;;
    esac
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private var calls: [[String]] {
    get throws {
      try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        .split(separator: "\n").map { $0.split(separator: "\u{1f}").map(String.init) }
    }
  }

  private func driver(_ runtime: URL, dialect: ContainerHostDriver.Dialect = .docker)
    throws -> ContainerHostDriver
  {
    let daemon = directory.appendingPathComponent("workroomd-linux")
    try Data("ELF".utf8).write(to: daemon)
    return ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "unused", user: "", identityFile: "", publicKey: "",
        daemonSocket: DaemonInstall.defaultSocket, labels: ["workroom.provisioner=test"],
        context: dialect == .docker ? "orbstack" : nil, dialect: dialect,
        daemon: { _ in daemon }, daemonFolder: directory.appendingPathComponent("daemon")))
  }

  private let spec = ContainerHostDriver.ContainerSpec(
    image: "mcr.microsoft.com/devcontainers/base:ubuntu", user: "vscode",
    environment: ["TZ": "Europe/London"],
    mounts: [.init(type: "volume", source: "cache", target: "/cache")],
    runArgs: ["--network=host"], privileged: true, capAdd: ["SYS_PTRACE"],
    securityOpt: ["seccomp=unconfined"], workspaceFolder: "/workspaces/app")

  /// Docker: the container is created (not started) as root with the daemon as its entrypoint, told
  /// to become the remote user and own the workspace folder; the daemon goes in by `cp -`, as a tar
  /// that unpacks at `/`; then it starts, its daemon is waited for as the remote user, and the image
  /// is checked for git through the container's shell.
  func testADockerContainerIsMadeWithTheDaemonCopiedIn() async throws {
    let driver = try driver(try stubRuntime())
    let host = try await driver.create(spec: spec)

    let made = try calls.filter { !["image", "pull"].contains($0.dropFirst(2).first ?? "") }
    let create = try XCTUnwrap(made.first { $0.contains("create") })
    XCTAssertEqual(Array(create.prefix(2)), ["--context", "orbstack"])
    for flags in [
      ["--init"], ["--restart", "unless-stopped"], ["--user", "0"], ["--env", "TZ=Europe/London"],
      ["--mount", "type=volume,source=cache,target=/cache"], ["--cap-add", "SYS_PTRACE"],
      ["--privileged"], ["--security-opt", "seccomp=unconfined"], ["--network=host"],
      ["--entrypoint", "/.workroom/bin/workroomd", "mcr.microsoft.com/devcontainers/base:ubuntu"],
    ] {
      XCTAssertTrue(contains(create, flags), "create lacks \(flags): \(create)")
    }
    XCTAssertEqual(
      Array(create.suffix(11)),
      [
        "serve", "--socket", "/run/workroom/workroomd.sock", "--idle-timeout", "never",
        "--screens", "~/.local/state/workroom/screens", "--user", "vscode", "--own",
        "/workspaces/app",
      ])
    let name = try XCTUnwrap(create.firstIndex(of: "--name").map { create[$0 + 1] })
    let steps = made.map { $0.dropFirst(2).first ?? "" }
    XCTAssertEqual(steps, ["create", "cp", "start", "exec", "exec"])
    XCTAssertEqual(made[1].suffix(2), ["-", "\(name):/"])
    XCTAssertEqual(
      Array(made[3].dropFirst(2)),
      [
        "exec", "-u", "vscode", name, "/.workroom/bin/workroomd", "list", "--socket",
        "/run/workroom/workroomd.sock",
      ])
    XCTAssertEqual(
      Array(made[4].dropFirst(2)),
      ["exec", "-i", "-u", "vscode", name, "sh", "-c", "command -v git >/dev/null 2>&1 || exit 3"])

    let listing = Process()
    listing.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    listing.arguments = ["-tvf", directory.appendingPathComponent("copied.tar").path]
    let pipe = Pipe()
    listing.standardOutput = pipe
    try listing.run()
    listing.waitUntilExit()
    let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(entries.contains(".workroom/bin/workroomd"), entries)
    XCTAssertTrue(entries.contains("-rwxr-xr-x"), "the daemon isn't executable: \(entries)")

    XCTAssertEqual(
      driver.record(of: host), ContainerHostRecord(user: "vscode", image: nil, context: "orbstack"))
    XCTAssertTrue(driver.isContainer(host))
  }

  /// Apple: no copying into a container before it starts, so the daemon's folder on this Mac is
  /// mounted read-only; and Docker's run flags, privileged mode and security options aren't passed.
  func testAnAppleContainerMountsTheDaemon() async throws {
    let driver = try driver(try stubRuntime(), dialect: .apple)
    _ = try await driver.create(spec: spec)

    let create = try XCTUnwrap(calls.first { $0.first == "create" })
    XCTAssertTrue(
      contains(
        create,
        [
          "--mount",
          "type=bind,source=\(directory.appendingPathComponent("daemon").path),"
            + "target=/.workroom/bin,readonly",
        ]), "\(create)")
    XCTAssertTrue(contains(create, ["--cap-add", "SYS_PTRACE"]))
    XCTAssertFalse(create.contains("--privileged"))
    XCTAssertFalse(create.contains("--network=host"))
    XCTAssertFalse(create.contains("--restart"))
    XCTAssertFalse(try calls.contains { $0.first == "cp" })
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("daemon/workroomd")), Data("ELF".utf8))
  }

  /// An image with no git fails the create with what to do, and its container goes.
  func testAnImageWithoutGitIsRefusedAndItsContainerRemoved() async throws {
    let driver = try driver(try stubRuntime(#"*"exec -i"*"command -v git"*) exit 3 ;;"#))
    do {
      _ = try await driver.create(spec: spec)
      XCTFail("an image without git was taken")
    } catch let error as HostDriverError {
      XCTAssertTrue(error.localizedDescription.contains("has no git"), error.localizedDescription)
    }
    XCTAssertTrue(try calls.contains { $0.dropFirst(2).starts(with: ["rm", "--force"]) })
  }

  /// No user in the spec is the one the image's devcontainer metadata names (the devcontainers
  /// images run as root and name `vscode` there), else the image's own, from its config; none
  /// there is root.
  func testTheRemoteUserDefaultsToTheImagesOwnThenRoot() async throws {
    var spec = spec
    spec.user = nil
    let driver = try driver(
      try stubRuntime(
        #""--context orbstack image inspect --format {{json .Config}}"*) echo '{"User":"node"}' ;;"#
      ))
    let host = try await driver.create(spec: spec)
    XCTAssertEqual(driver.record(of: host)?.user, "node")

    let metadata = #"[{\"id\":\"git\"},{\"remoteUser\":\"vscode\"}]"#
    let devcontainer = try self.driver(
      try stubRuntime(
        #""--context orbstack image inspect --format {{json .Config}}"*) "#
          + #"echo '{"User":"root","Labels":{"devcontainer.metadata":"\#(metadata)"}}' ;;"#))
    let devcontainerHost = try await devcontainer.create(spec: spec)
    XCTAssertEqual(devcontainer.record(of: devcontainerHost)?.user, "vscode")

    let rootDriver = try self.driver(try stubRuntime())
    let rootHost = try await rootDriver.create(spec: spec)
    XCTAssertEqual(rootDriver.record(of: rootHost)?.user, "root")
  }

  /// A later build's daemon (#308): Docker stages it beside the entrypoint under a name of its own,
  /// and moves it over the entrypoint, or removes it, as root, whose folder it is.
  func testADockerContainersDaemonIsStagedThenMovedIntoPlaceAsRoot() async throws {
    let driver = try driver(try stubRuntime())
    let host = try await driver.create(spec: spec)
    let name = try XCTUnwrap(calls.first { $0.contains("create") }).drop { $0 != "--name" }
      .dropFirst().first
    try FileManager.default.removeItem(at: directory.appendingPathComponent("calls"))
    XCTAssertEqual(driver.daemonPath(on: host), "/.workroom/bin/workroomd")

    let placed = try await driver.placeDaemon(
      directory.appendingPathComponent("workroomd-linux"), on: host)
    XCTAssertTrue(placed.staged)
    XCTAssertTrue(placed.path.hasPrefix("/.workroom/bin/workroomd.new."), placed.path)
    XCTAssertEqual(try calls.last?.suffix(2), ["-", "\(name ?? ""):/"])
    try await driver.settleDaemon(placed.path, keep: true, on: host)
    try await driver.settleDaemon(placed.path, keep: false, on: host)
    XCTAssertEqual(
      try calls.suffix(2).map { Array($0.dropFirst(2)) },
      [
        ["exec", "-u", "0", name ?? "", "mv", "-f", placed.path, "/.workroom/bin/workroomd"],
        ["exec", "-u", "0", name ?? "", "rm", "-f", placed.path],
      ])
  }

  /// A record a later launch adopts is reached the same way; one from a container made before #308
  /// (it has an ssh host key) is refused, to be made again.
  func testAdoptingTakesExecRecordsAndRefusesSSHOnes() throws {
    let driver = try driver(try stubRuntime())
    let id = UUID()
    try driver.adopt(id, ContainerHostRecord(user: "vscode", image: nil, context: "orbstack"))
    XCTAssertTrue(driver.isContainer(.remote(id)))
    XCTAssertEqual(driver.record(of: .remote(id))?.user, "vscode")
    let command = try driver.attachCommand(
      to: .remote(id), session: UUID(), workingDirectory: "/w", restored: false, metadata: [],
      runCommand: nil)
    XCTAssertTrue(command.contains("'exec' '-i' '-t' '-u' 'vscode'"), command)

    XCTAssertThrowsError(
      try driver.adopt(
        UUID(),
        ContainerHostRecord(
          address: "127.0.0.1", port: 2222, user: "workroom", hostKey: "ssh-ed25519 AAAA",
          image: nil, context: "orbstack"))
    ) { XCTAssertEqual($0 as? HostDriverError, .olderContainer) }
  }

  private func contains(_ arguments: [String], _ run: [String]) -> Bool {
    guard arguments.count >= run.count else { return false }
    return (0...(arguments.count - run.count)).contains {
      Array(arguments[$0..<($0 + run.count)]) == run
    }
  }
}
