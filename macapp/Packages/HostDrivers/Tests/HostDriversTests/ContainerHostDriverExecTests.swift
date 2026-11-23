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

  /// The `workroom` link beside a daemon folder's `workroomd` (ADR 0078): made, put right when it
  /// names something else, and never made over a file that is not a link.
  func testTheDaemonFolderGetsAWorkroomLinkOnlyWhereNothingButALinkIs() throws {
    let folder = directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("workroom").path
    try ContainerHostDriver.linkCommand(in: folder)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "workroomd")
    try ContainerHostDriver.linkCommand(in: folder)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "workroomd")

    try FileManager.default.removeItem(atPath: link)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "elsewhere")
    try ContainerHostDriver.linkCommand(in: folder)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "workroomd")

    try FileManager.default.removeItem(atPath: link)
    try Data("someone's\n".utf8).write(to: URL(fileURLWithPath: link))
    try ContainerHostDriver.linkCommand(in: folder)
    XCTAssertEqual(try String(contentsOfFile: link, encoding: .utf8), "someone's\n")
  }

  /// `tar -tv` of the last tar the runtime was handed by `cp -`.
  private func copiedEntries() throws -> String {
    let listing = Process()
    listing.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    listing.arguments = ["-tvf", directory.appendingPathComponent("copied.tar").path]
    let pipe = Pipe()
    listing.standardOutput = pipe
    try listing.run()
    listing.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }

  private var calls: [[String]] {
    get throws {
      try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        .split(separator: "\n").map { $0.split(separator: "\u{1f}").map(String.init) }
    }
  }

  private func driver(_ runtime: URL, dialect: ContainerRuntime = .docker)
    throws -> ContainerHostDriver
  {
    let daemon = directory.appendingPathComponent("workroomd-linux")
    try Data("ELF".utf8).write(to: daemon)
    return ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "unused", user: "",
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
      [
        "exec", "-i", "-u", "vscode", name, "sh", "-c",
        ContainerExecTransport.ownHome + "command -v git >/dev/null 2>&1 || exit 3",
      ])

    let entries = try copiedEntries()
    XCTAssertTrue(entries.contains(".workroom/bin/workroomd"), entries)
    XCTAssertTrue(entries.contains("-rwxr-xr-x"), "the daemon isn't executable: \(entries)")
    // The name the container's panes run it by (ADR 0078), relative to the file it names.
    XCTAssertTrue(entries.contains(".workroom/bin/workroom -> workroomd"), entries)

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

  // Value: protects=Apple creates at once all share one daemon folder on this Mac and each still
  // succeeds, with the `workroom` link and the daemon left right; fails_when=two creates both see
  // no link, a wrong link or no daemon, and the second to make it fails with "already exists"
  // (Cocoa 516) or finds the other's removal; why_new=only one create at a time was tested, and the
  // live concurrent test failed every run; seam=stub runtime; no_claim=the runtime's own handling
  // of a shared bind mount
  /// Apple creates at once share the daemon's folder on this Mac: each makes its container, and
  /// the folder ends with the one daemon and its `workroom` link, however the creates interleave
  /// and whatever the folder held: nothing, a link to something else and an older daemon, or the
  /// right ones already; and a file at `workroom` that is not a link is still left alone.
  /// The runtime holds each round of `image inspect`s (the image's check, then its user's read,
  /// the last call before the daemon's folder) until every create has made one, then lets them go
  /// together, so the creates reach the folder at the same moment, as the live ones do.
  func testAppleCreatesAtOnceShareTheDaemonFolder() async throws {
    let creates = 8
    let slots = directory.appendingPathComponent("slots").path
    // Bounded by the clock (read every thousand turns, which a slow machine only makes later), so
    // a create that fails before its inspect fails the test rather than hanging it.
    let driver = try driver(
      try stubRuntime(
        """
        "image inspect "*)
          i=0; while ! mkdir "\(slots)/$i" 2> /dev/null; do i=$((i + 1)); done
          last=$(( (i / \(creates) + 1) * \(creates) - 1 )); n=0
          deadline=$(( $(date +%s) + 120 ))
          while [ ! -d "\(slots)/$last" ]; do
            n=$((n + 1))
            if [ $((n % 1000)) = 0 ] && [ "$(date +%s)" -gt "$deadline" ]; then exit 9; fi
          done
          echo '[]' ;;
        """), dialect: .apple)
    let folder = directory.appendingPathComponent("daemon")
    let link = folder.appendingPathComponent("workroom").path
    let daemon = folder.appendingPathComponent("workroomd")
    var userless = spec
    userless.user = nil
    let spec = userless
    for round in 0..<12 {
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(atPath: slots)
      try FileManager.default.createDirectory(atPath: slots, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      switch round % 4 {
      case 1:
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "elsewhere")
        try Data("OLD".utf8).write(to: daemon)
      case 2:
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "workroomd")
        try Data("ELF".utf8).write(to: daemon)
      case 3: try Data("someone's\n".utf8).write(to: URL(fileURLWithPath: link))
      default: break
      }
      let before = try? FileManager.default.attributesOfItem(atPath: daemon.path)[.systemFileNumber]
      let hosts = try await withThrowingTaskGroup(of: HostID.self) { group in
        for _ in 0..<creates { group.addTask { try await driver.create(spec: spec) } }
        return try await group.reduce(into: [HostID]()) { $0.append($1) }
      }
      XCTAssertEqual(Set(hosts).count, creates, "round \(round)")
      if round % 4 == 2 {
        // The daemon its containers may be running from is the same file: not replaced by itself.
        let after = try FileManager.default.attributesOfItem(atPath: daemon.path)[.systemFileNumber]
        XCTAssertEqual(after as? Int, before as? Int, "round \(round): the daemon was replaced")
      }
      if round % 4 == 3 {
        XCTAssertEqual(try String(contentsOfFile: link, encoding: .utf8), "someone's\n")
      } else {
        XCTAssertEqual(
          try FileManager.default.destinationOfSymbolicLink(atPath: link), "workroomd",
          "round \(round)")
      }
      XCTAssertEqual(try Data(contentsOf: daemon), Data("ELF".utf8), "round \(round)")
      let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
      XCTAssertEqual(left, ["workroom", "workroomd"], "round \(round): staged files left")
    }
  }

  // Value: protects=a staged daemon a killed create left in Apple's folder is removed, and nothing
  // else is: not a staging whose maker still holds its lock (however long it has slept), not an
  // earlier version's `.workroomd-<UUID>`, not a name of another shape, not a link, FIFO or
  // folder; fails_when=the sweep goes by name or age rather than the lock, or follows a link, or
  // blocks on a FIFO; why_new=nothing removed what a killed create left;
  // seam=removeAbandonedDaemons, with a staging's lock held by a file of the test's own;
  // no_claim=a create killed by the system
  /// A staged daemon a create left (killed mid-copy, its lock gone with it) is removed, and only
  /// that: a staging whose maker still holds its lock stays, as do an earlier version's staged
  /// name (which had no lock), names of another shape, and a link, FIFO or folder of the staged
  /// name; the daemon and its link stay too.
  func testOnlyAnAbandonedStagedDaemonIsRemovedFromApplesFolder() throws {
    let folder = directory.appendingPathComponent("daemon")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manager = FileManager.default
    func staging() -> String { ContainerHostDriver.stagedDaemonPrefix + UUID().uuidString }
    // Made exclusively and locked as it is made, as `stageDaemon` makes one.
    func locked(_ name: String) throws -> Int32 {
      let file = open(
        folder.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_EXLOCK, 0o700)
      guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      return file
    }
    let held = staging()
    let holder = try locked(held)
    defer { close(holder) }
    let abandoned = staging()
    close(try locked(abandoned))
    let linked = staging()
    let fifo = staging()
    let folderNamed = staging()
    let keptNames = [
      "workroomd", ".workroomd-\(UUID().uuidString)",
      ContainerHostDriver.stagedDaemonPrefix + UUID().uuidString.lowercased(),
      ContainerHostDriver.stagedDaemonPrefix + "notauuid", "staging-\(UUID().uuidString)",
      ".workroomd-staging\(UUID().uuidString)",
    ]
    for name in keptNames {
      try Data("ELF".utf8).write(to: folder.appendingPathComponent(name))
    }
    let outside = directory.appendingPathComponent("outside")
    try Data("someone's".utf8).write(to: outside)
    try manager.createSymbolicLink(
      atPath: folder.appendingPathComponent(linked).path, withDestinationPath: outside.path)
    XCTAssertEqual(mkfifo(folder.appendingPathComponent(fifo).path, 0o600), 0)
    try manager.createDirectory(
      at: folder.appendingPathComponent(folderNamed), withIntermediateDirectories: false)
    try manager.createSymbolicLink(
      atPath: folder.appendingPathComponent("workroom").path, withDestinationPath: "workroomd")
    let everything = Set(try manager.contentsOfDirectory(atPath: folder.path))

    ContainerHostDriver.removeAbandonedDaemons(in: folder)
    XCTAssertEqual(
      Set(try manager.contentsOfDirectory(atPath: folder.path)),
      everything.subtracting([abandoned]))
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "someone's")

    // Once its maker lets go (it has gone), the held one is abandoned too.
    ContainerHostDriver.removeAbandonedDaemons(in: folder)
    XCTAssertTrue(manager.fileExists(atPath: folder.appendingPathComponent(held).path))
    XCTAssertEqual(flock(holder, LOCK_UN), 0)
    ContainerHostDriver.removeAbandonedDaemons(in: folder)
    XCTAssertEqual(
      Set(try manager.contentsOfDirectory(atPath: folder.path)),
      everything.subtracting([abandoned, held]))
  }

  /// A staging that fails part way leaves nothing behind in Apple's folder: here the "daemon" is
  /// a file no one can read, so the staged file is made, then can't be filled.
  func testAFailedStagingInApplesFolderLeavesNoCopy() async throws {
    let runtime = try stubRuntime()
    let notAFile = directory.appendingPathComponent("unreadable-daemon")
    try Data("ELF".utf8).write(to: notAFile)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: notAFile.path)
    let folder = directory.appendingPathComponent("daemon")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("OLD".utf8).write(to: folder.appendingPathComponent("workroomd"))
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "unused", user: "",
        daemonSocket: DaemonInstall.defaultSocket, labels: ["workroom.provisioner=test"],
        context: nil, dialect: .apple, daemon: { _ in notAFile }, daemonFolder: folder))
    do {
      _ = try await driver.create(spec: spec)
      XCTFail("a daemon that can't be put in place was taken")
    } catch {}
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
      ["workroom", "workroomd"])
    XCTAssertEqual(
      try Data(contentsOf: folder.appendingPathComponent("workroomd")), Data("OLD".utf8))
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

  // Value: protects=a create's owned volumes are labelled on its container and recorded for its delete, and a failed create removes
  // them after its container; fails_when=the label or record is dropped, or a failed create leaves them; why_new=only an adopted
  // record's destroy was tested; seam=stub runtime; no_claim=the runtime's own volume handling
  /// The volumes a container owns travel with it: on its label (for a sweep), in its record (for a
  /// delete after a relaunch), and out with it when its create fails.
  func testACreatesOwnedVolumesAreLabelledRecordedAndRemovedOnFailure() async throws {
    var owning = spec
    owning.ownedVolumes = ["dind-1", "cache-1"]
    let made = try driver(try stubRuntime())
    let host = try await made.create(spec: owning)
    XCTAssertEqual(made.record(of: host)?.volumes, ["dind-1", "cache-1"])
    let create = try XCTUnwrap(try calls.first { $0.contains("create") })
    XCTAssertTrue(contains(create, ["--label", "workroom.volumes=dind-1,cache-1"]), "\(create)")

    try FileManager.default.removeItem(at: directory.appendingPathComponent("calls"))
    let failing = try driver(try stubRuntime(#"*"exec -i"*"command -v git"*) exit 3 ;;"#))
    do {
      _ = try await failing.create(spec: owning)
      XCTFail("an image without git was taken")
    } catch {}
    let calls = try calls
    let removal = try XCTUnwrap(calls.firstIndex { contains($0, ["rm", "--force"]) }, "\(calls)")
    let volumes = try XCTUnwrap(
      calls.firstIndex { contains($0, ["volume", "rm", "dind-1", "cache-1"]) }, "\(calls)")
    XCTAssertLessThan(removal, volumes)
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

  // Value: protects=a placement in a running Docker container never unpacks a `workroom` link over
  // the running one, and makes it by one rename of a link of its own; fails_when=the tar carries
  // the link again (Docker removes then makes it, so a placement alongside finds it gone or fails),
  // or the link is made in place; why_new=placements overlap (a connect's and a retried
  // bootstrap's); seam=stub runtime; no_claim=the image's own ln and mv
  /// A later build's daemon (#308): Docker stages it beside the entrypoint under a name of its own,
  /// and moves it over the entrypoint, or removes it, as root, whose folder it is. The tar holds
  /// the staged daemon alone; the `workroom` link is made under a name of the placement's own and
  /// moved over whatever is there, so two placements at once never share or remove a name.
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
    let id = String(placed.path.dropFirst("/.workroom/bin/workroomd.new.".count))
    let placing = try calls.map { Array($0.dropFirst(2)) }
    XCTAssertEqual(placing.first?.suffix(2), ["-", "\(name ?? ""):/"])
    XCTAssertEqual(
      Array(placing.dropFirst()),
      [
        ["exec", "-u", "0", name ?? "", "ln", "-s", "workroomd", "/.workroom/bin/.workroom-\(id)"],
        [
          "exec", "-u", "0", name ?? "", "mv", "-f", "/.workroom/bin/.workroom-\(id)",
          "/.workroom/bin/workroom",
        ],
      ])
    let entries = try copiedEntries()
    XCTAssertTrue(entries.contains(".workroom/bin/workroomd.new.\(id)"), entries)
    XCTAssertFalse(entries.contains(".workroom/bin/workroom "), entries)

    let again = try await driver.placeDaemon(
      directory.appendingPathComponent("workroomd-linux"), on: host)
    XCTAssertNotEqual(again.path, placed.path)
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
  /// (it has an ssh host key) is taken on only to be destroyed: reaching it is refused, to be made
  /// again.
  func testAdoptingTakesExecRecordsAndRefusesToReachSSHOnes() throws {
    let driver = try driver(try stubRuntime())
    let id = UUID()
    try driver.adopt(id, ContainerHostRecord(user: "vscode", image: nil, context: "orbstack"))
    XCTAssertTrue(driver.isContainer(.remote(id)))
    XCTAssertEqual(driver.record(of: .remote(id))?.user, "vscode")
    let command = try driver.attachCommand(
      to: .remote(id), session: UUID(), workingDirectory: "/w", restored: false, metadata: [],
      runCommand: nil)
    XCTAssertTrue(command.contains("'exec' '-i' '-t' '-u' 'vscode'"), command)

    let older = UUID()
    let record = ContainerHostRecord(
      address: "127.0.0.1", port: 2222, user: "workroom", hostKey: "ssh-ed25519 AAAA",
      image: nil, context: "orbstack")
    try driver.adopt(older, record)
    XCTAssertFalse(driver.isContainer(.remote(older)))
    XCTAssertEqual(driver.record(of: .remote(older)), record)
    XCTAssertThrowsError(
      try driver.attachCommand(
        to: .remote(older), session: UUID(), workingDirectory: "/w", restored: false,
        metadata: [], runCommand: nil)
    ) { XCTAssertEqual($0 as? HostDriverError, .olderContainer) }
  }

  // Value: protects=a deleted container workroom takes the named volumes made for it (docker-in-docker's) with it, after a relaunch too;
  // fails_when=destroy stops removing them, or the record stops carrying them; why_new=destroy only removed the container and its
  // anonymous volumes; seam=stub runtime; no_claim=what the runtime itself does with `volume rm`
  /// The volumes a container owns go with it, after it: a later launch's driver knows them from
  /// the record, and one already gone counts as removed.
  func testDestroyRemovesTheVolumesTheContainerOwns() async throws {
    let driver = try driver(
      try stubRuntime(#"*"volume rm"*) echo 'Error: No such volume: v' >&2; exit 1 ;;"#))
    let id = UUID()
    try driver.adopt(
      id,
      ContainerHostRecord(
        user: "vscode", image: nil, context: "orbstack", volumes: ["dind-var-lib-docker-abc"]))
    XCTAssertEqual(driver.record(of: .remote(id))?.volumes, ["dind-var-lib-docker-abc"])

    try await driver.destroy(.remote(id))
    let calls = try calls
    let removal = try XCTUnwrap(
      calls.firstIndex { contains($0, ["rm", "--force", "--volumes"]) }, "\(calls)")
    let volumes = try XCTUnwrap(
      calls.firstIndex { contains($0, ["volume", "rm", "dind-var-lib-docker-abc"]) }, "\(calls)")
    XCTAssertLessThan(removal, volumes, "a volume in use can't be removed")
  }

  private func contains(_ arguments: [String], _ run: [String]) -> Bool {
    guard arguments.count >= run.count else { return false }
    return (0...(arguments.count - run.count)).contains {
      Array(arguments[$0..<($0 + run.count)]) == run
    }
  }
}
