import DaemonConnection
import Defaults
import HostDrivers
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// The bundled far-side scripts (`probe`, `install`, `resources`), run for real against this Mac's
/// own `sh`. Split from `DaemonBootstrapTests` so the parallel test runner, which schedules whole
/// classes, spreads the two halves of that class's ~65s over two workers.
final class DaemonBootstrapScriptTests: XCTestCase {
  private let host = HostID.remote(UUID())

  /// A driver whose host is this Mac's own `sh`, running the bundled far-side scripts as a host's
  /// login shell would. So `parseProbe` and `parseInstall` meet what the scripts actually print,
  /// not a hand-typed answer. `uname` is shimmed to say Linux aarch64; the rest is the Mac's own
  /// coreutils, `/sbin/sha256sum` included. The fixture proves the same on a real Linux host.
  private class LocalShellDriver: HostDriver, @unchecked Sendable {
    let path: String

    init(path: String) { self.path = path }

    func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
    func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("openStream")
    }

    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment: ["PATH": path],
        handshakeTimeout: 5, purpose: .exchange)
    }
  }

  /// As a container's driver places the daemon (#308): staged beside the entrypoint in a folder of
  /// its own, then moved over it or removed.
  private final class LocalPlacingDriver: LocalShellDriver, DaemonPlacingDriver,
    @unchecked Sendable
  {
    let folder: URL

    init(path: String, folder: URL) {
      self.folder = folder
      super.init(path: path)
    }

    func daemonPath(on host: HostID) -> String? { folder.appendingPathComponent("workroomd").path }
    func placeDaemon(_ binary: URL, on host: HostID) async throws -> (path: String, staged: Bool) {
      let staged = folder.appendingPathComponent("workroomd.new.\(UUID().uuidString.prefix(8))")
      try FileManager.default.copyItem(at: binary, to: staged)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
      return (staged.path, true)
    }
    func settleDaemon(_ staged: String, keep: Bool, on host: HostID) async throws {
      let file = URL(fileURLWithPath: staged)
      if keep {
        _ = try FileManager.default.replaceItemAt(
          folder.appendingPathComponent("workroomd"), withItemAt: file)
      } else {
        try FileManager.default.removeItem(at: file)
      }
    }
  }

  private struct LocalHost {
    let driver: LocalShellDriver
    let directory: URL
    var socket: String { directory.appendingPathComponent("workroomd.sock").path }
    var binary: String { DaemonInstall.binary(besideSocket: socket) }
  }

  /// A host directory (the socket's) with nothing in it, and a shell whose PATH has
  /// `sha256sum` or not.
  private func localHost(sha256sum: Bool = true) throws -> LocalHost {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wrb-\(UUID().uuidString.prefix(8))")
    let directory = root.appendingPathComponent("host")
    let shim = root.appendingPathComponent("shim")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let uname = shim.appendingPathComponent("uname")
    try Data(
      ("#!/bin/sh\ncase $1 in -s) echo Linux ;; -m) echo aarch64 ;; "
        + "*) exec /usr/bin/uname \"$@\" ;; esac\n").utf8
    ).write(to: uname)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uname.path)
    return LocalHost(
      driver: LocalShellDriver(path: shim.path + ":/usr/bin:/bin" + (sha256sum ? ":/sbin" : "")),
      directory: directory)
  }

  /// A daemon listening on the host's socket, as far as the scripts can tell (`-S`). The scripts
  /// never connect to it themselves: every hand-off goes through the stand-in's own answer.
  private func listen(on host: LocalHost) throws {
    let descriptor = try UnixSocketListener.listen(at: host.socket)
    addTeardownBlock { close(descriptor) }
  }

  /// A stand-in for a Linux daemon build: a script answering the subcommands the far side runs
  /// (`protocol`, `hand-off`, `list`). Its content is its build, so two stand-ins that answer
  /// differently have different digests.
  private func standIn(
    protocol status: Int = 0, protocolFirst: String = ":", handOff: String = "echo current",
    list: Int = 0
  ) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workroomd-standin-\(UUID().uuidString.prefix(8))")
    try Data(
      ("#!/bin/sh\ncase $1 in protocol) \(protocolFirst); exit \(status) ;; "
        + "hand-off) \(handOff); exit ;; "
        + "list) exit \(list) ;; esac\nexit 1\n").utf8
    ).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// `build` already installed on `host`, as an earlier connect left it.
  private func preinstall(_ build: URL, on host: LocalHost) throws {
    try FileManager.default.copyItem(at: build, to: URL(fileURLWithPath: host.binary))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.binary)
  }

  private func ensure(
    _ host: LocalHost, bundling build: URL, handOff: Bool = true, resources: URL? = nil
  ) async throws -> DaemonBootstrap.Outcome {
    try await DaemonBootstrap.ensure(
      host: self.host, driver: host.driver, socket: host.socket,
      daemon: { $0 == "aarch64" ? build : nil }, handOff: handOff, resources: resources)
  }

  /// The installed file's digest, and that no staged copy was left beside it.
  private func installed(on host: LocalHost, file: StaticString = #filePath, line: UInt = #line)
    throws -> String
  {
    let left = try FileManager.default.contentsOfDirectory(atPath: host.directory.path)
    XCTAssertFalse(left.contains { $0.contains(".new.") }, "\(left)", file: file, line: line)
    return try DaemonBootstrap.digest(of: URL(fileURLWithPath: host.binary))
  }

  /// First connect to an empty host: installed, and the supervisor's start is waited for. Then
  /// the same build again pushes nothing, whether its daemon is running or not.
  func testTheRealScriptsInstallOnAnEmptyHostAndThenPushNothing() async throws {
    let host = try localHost()
    let build = try standIn()
    let first = try await ensure(host, bundling: build)
    XCTAssertEqual(first, .init(architecture: "aarch64", pushed: true, daemon: .installed))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: build))
    let idle = try await ensure(host, bundling: build)
    XCTAssertEqual(idle, .init(architecture: "aarch64", pushed: false, daemon: .installed))
    try listen(on: host)
    let running = try await ensure(host, bundling: build)
    XCTAssertEqual(running, .init(architecture: "aarch64", pushed: false, daemon: .current))
  }

  /// The start script detaches all of ssh's descriptors, uses a fixed environment, and reports the
  /// process it made. A stale socket file does not count as a live daemon; a listening daemon does.
  func testTheRealSSHStartDetachesAndPinsTheEnvironment() async throws {
    let host = try localHost()
    let shim = try XCTUnwrap(host.driver.path.split(separator: ":").first).description
    let setsid = URL(fileURLWithPath: shim).appendingPathComponent("setsid")
    // macOS has no setsid utility; the Linux fixture exercises the real utility. This shim keeps
    // the actual backgrounding, descriptor redirections, argv and env -i in the script under test.
    try Data("#!/bin/sh\nexec \"$@\"\n".utf8).write(to: setsid)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setsid.path)
    let alive = host.directory.appendingPathComponent("alive")
    let pidFile = host.directory.appendingPathComponent("pid")
    let record = host.directory.appendingPathComponent("record")
    let body = """
      #!/bin/sh
      case $1 in
        list) test -f \(PosixShell.quoted(alive.path)); exit ;;
        serve)
          printf '%s\\n' "$*" "$HOME" "$USER" "$SHELL" "$PATH" "${MUST_NOT_LEAK:-unset}" > \(PosixShell.quoted(record.path))
          umask >> \(PosixShell.quoted(record.path))
          echo $$ > \(PosixShell.quoted(pidFile.path))
          : > \(PosixShell.quoted(alive.path))
          exec /bin/sleep 30 ;;
      esac
      exit 1
      """
    try Data(body.utf8).write(to: URL(fileURLWithPath: host.binary))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.binary)
    try listen(on: host)
    defer {
      if let text = try? String(contentsOf: pidFile, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        kill(pid, SIGKILL)
      }
    }
    let arguments = [
      "sh", "-c", try DaemonBootstrap.script(named: "start"), "start", host.binary, host.socket,
      host.directory.appendingPathComponent("screens").path, "never",
    ]
    let command = arguments.map(PosixShell.quoted).joined(separator: " ")
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "umask 027; " + command],
      environment: [
        "PATH": host.driver.path, "HOME": host.directory.path, "USER": "server-user",
        "SHELL": "/bin/sh", "MUST_NOT_LEAK": "from-ssh",
      ], handshakeTimeout: 5, purpose: .exchange)
    let start = ContinuousClock.now
    let (status, output) = try await stream.communicate(nil, timeout: 5)
    XCTAssertEqual(status, 0, output)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "ssh's descriptors stayed open")
    let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines)
    XCTAssertTrue(output.contains("WRB started \(pid)\n"), output)
    XCTAssertTrue(output.contains("WRB serving yes\n"), output)
    let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(
      String.init)
    XCTAssertEqual(
      Array(lines.dropLast()),
      [
        "serve --socket \(host.socket) --idle-timeout never --screens \(host.directory.path)/screens",
        host.directory.path, "server-user", "/bin/sh", "/usr/local/bin:/usr/bin:/bin", "unset",
      ])
    XCTAssertEqual(Int(try XCTUnwrap(lines.last), radix: 8), 0o27)
    for directory in [host.directory.path, host.directory.appendingPathComponent("screens").path] {
      let attributes = try FileManager.default.attributesOfItem(atPath: directory)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    let again = try await host.driver.exec(command, on: self.host).communicate(nil, timeout: 5)
    XCTAssertEqual(again.status, 0, again.output)
    XCTAssertEqual(again.output, "WRB serving yes\n", "the live daemon was started twice")
  }

  /// A host an older Nightly made before the daemon was renamed (#525) has `wr-agent` and no
  /// `workroomd`, and its supervisor only ever starts the old name. Nothing is pushed, and the
  /// connect fails saying to recreate the workroom (eng review D3).
  func testTheRealProbeRefusesAHostWithTheOldLayout() async throws {
    let host = try localHost()
    let old = URL(fileURLWithPath: DaemonInstall.formerBinary(besideSocket: host.socket))
    try FileManager.default.copyItem(at: try standIn(), to: old)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.path)
    do {
      _ = try await ensure(host, bundling: try standIn())
      XCTFail("an old-layout host was bootstrapped")
    } catch DaemonBootstrap.Error.olderLayout {
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: host.binary), "nothing is pushed to an old host")
  }

  // Value: protects=a host with a current workroomd and a leftover wr-agent connects normally;
  // fails_when=the probe's `[ ! -e "$binary" ]` guard goes and every host that kept wr-agent is refused;
  // why_new=the refusal test above has no workroomd on the host; seam=none; no_claim=none
  func testTheRealProbeDoesNotRefuseAHostThatHasADaemonAndAnOldBinary() async throws {
    let host = try localHost()
    let build = try standIn()
    try preinstall(build, on: host)
    let old = URL(fileURLWithPath: DaemonInstall.formerBinary(besideSocket: host.socket))
    try FileManager.default.copyItem(at: build, to: old)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.path)
    let outcome = try await ensure(host, bundling: build)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: false, daemon: .installed))
  }

  func testTheRealScriptsHandANewerBuildOffToTheRunningDaemon() async throws {
    let host = try localHost()
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    let newer = try standIn(handOff: "echo handed off")
    let outcome = try await ensure(host, bundling: newer)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, daemon: .handedOff))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: newer))
  }

  /// An installed daemon that hangs when asked its build reads as `unknown` within the probe's 5
  /// seconds, and is replaced, rather than holding the connect until the bootstrap gives up.
  func testTheRealProbeGivesUpOnAnInstalledDaemonThatHangs() async throws {
    let host = try localHost()
    try preinstall(try standIn(protocolFirst: "sleep 60"), on: host)
    let build = try standIn()
    let started = Date()
    let outcome = try await ensure(host, bundling: build)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, daemon: .installed))
    XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: build))
  }

  /// A host without `sha256sum` says its installed file is `unknown`, not `none`: the app keeps
  /// the daemon there instead of pushing to a host that would refuse the push anyway.
  func testTheRealProbeSaysUnknownOnAHostThatCannotHash() async throws {
    let host = try localHost(sha256sum: false)
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    let outcome = try await ensure(host, bundling: try standIn(handOff: "echo handed off"))
    XCTAssertEqual(
      outcome,
      .init(architecture: "aarch64", pushed: false, daemon: .keptOlder("the host has no sha256sum"))
    )
  }

  /// A host that cannot hash is not pushed the resource set either (#239), whether or not one is
  /// there: the push would be refused on every connect for the same reason.
  func testTheRealProbeKeepsTheResourceSetOffAHostThatCannotHash() async throws {
    let host = try localHost(sha256sum: false)
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    let outcome = try await ensure(
      host, bundling: try standIn(), resources: try XCTUnwrap(GhosttyResources.bundledURL))
    XCTAssertEqual(outcome.resources, .notPushed("the host has no sha256sum"))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: host.directory.path)
        .contains { $0.hasPrefix("ghostty") })
  }

  /// Refuse rather than kill: a build the running daemon refuses, or one that does not run on the
  /// host, is removed, and the file the supervisor starts from is the old one still.
  func testTheRealScriptsLeaveTheOldFileWhenTheNewOneIsRefusedOrDoesNotRun() async throws {
    let host = try localHost()
    let older = try standIn()
    try preinstall(older, on: host)
    try listen(on: host)
    let refused = try await ensure(
      host, bundling: try standIn(handOff: "echo 'error: cannot restore' >&2; exit 1"))
    XCTAssertEqual(refused.daemon, .keptOlder("refused: error: cannot restore"))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: older))
    let broken = try await ensure(host, bundling: try standIn(protocol: 1))
    XCTAssertEqual(
      broken.daemon, .keptOlder("the install failed: the bundled daemon does not run on this host"))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: older))
  }

  /// A container's daemon, placed by its driver (#308): placed.sh checks the staged build and hands
  /// off to it, and it is moved over the entrypoint; one the running daemon refuses is removed and
  /// the entrypoint left as it was.
  func testTheRealCheckOfAPlacedDaemonHandsOffOrLeavesTheEntrypoint() async throws {
    let host = try localHost()
    let folder = host.directory.deletingLastPathComponent().appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let driver = LocalPlacingDriver(path: host.driver.path, folder: folder)
    let entrypoint = folder.appendingPathComponent("workroomd")
    try FileManager.default.copyItem(at: try standIn(), to: entrypoint)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)
    try listen(on: host)
    let ensure = { (build: URL) in
      try await DaemonBootstrap.ensure(
        host: self.host, driver: driver, socket: host.socket,
        daemon: { $0 == "aarch64" ? build : nil }, resources: nil)
    }
    let staged = { try FileManager.default.contentsOfDirectory(atPath: folder.path).count }

    let newer = try standIn(handOff: "echo handed off")
    let outcome = try await ensure(newer)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, daemon: .handedOff))
    XCTAssertEqual(
      try DaemonBootstrap.digest(of: entrypoint), try DaemonBootstrap.digest(of: newer))
    XCTAssertEqual(try staged(), 1, "a staged copy was left")

    let refused = try await ensure(
      try standIn(handOff: "echo 'error: cannot restore' >&2; exit 1"))
    XCTAssertEqual(refused.daemon, .keptOlder("refused: error: cannot restore"))
    XCTAssertEqual(
      try DaemonBootstrap.digest(of: entrypoint), try DaemonBootstrap.digest(of: newer))
    XCTAssertEqual(try staged(), 1, "a refused copy was left")
  }

  /// A daemon that cannot be handed off (it predates hand-off, it did not greet, or hand-off is
  /// off) keeps running, and the new build is put in place for its next start.
  func testTheRealScriptsInstallForTheNextStartWhenTheDaemonCannotHandOff() async throws {
    let host = try localHost()
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    for (answer, why) in [
      ("echo too old; exit 3", "the daemon predates hand-off"),
      ("echo timed out; exit 92", "the daemon did not greet"),
    ] {
      let build = try standIn(handOff: answer)
      let outcome = try await ensure(host, bundling: build)
      XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, daemon: .keptOlder(why)))
      XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: build), why)
    }
    let off = try standIn(handOff: "exit 9")
    let outcome = try await ensure(host, bundling: off, handOff: false)
    XCTAssertEqual(outcome.daemon, .keptOlder("hand-off is off"))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: off))
  }

  /// A host with nothing to run fails the connect: an install that could not write, and one the
  /// supervisor never started (the install waits 10s for it, so this test takes that long).
  func testTheRealScriptsFailAHostLeftWithNothingToRun() async throws {
    let host = try localHost()
    let build = try standIn()
    do {
      _ = try await DaemonBootstrap.ensure(
        host: self.host, driver: host.driver,
        socket: "/nonexistent-\(UUID().uuidString.prefix(8))/workroomd.sock",
        daemon: { $0 == "aarch64" ? build : nil }, handOff: true)
      XCTFail("an install that could not write counted as connected")
    } catch DaemonBootstrap.Error.installFailed(let detail) {
      XCTAssertEqual(detail, "could not write beside the socket")
    }
    do {
      _ = try await ensure(host, bundling: try standIn(list: 1))
      XCTFail("a daemon nobody started counted as installed")
    } catch DaemonBootstrap.Error.installFailed(let detail) {
      XCTAssertTrue(detail.contains("supervisor"), detail)
    }
  }

  /// The install's own checks, run directly: a push that arrived short fails the digest the app
  /// sent, and a host that cannot hash refuses; either way nothing is left behind.
  func testTheRealInstallRefusesAPushItCannotCheck() async throws {
    let build = try standIn()
    let script = try DaemonBootstrap.script(named: "install")
    let cases = [
      (true, "truncated \(try DaemonBootstrap.digest(of: build))"), (false, "no-sha256sum"),
    ]
    for (sha256sum, said) in cases {
      let host = try localHost(sha256sum: sha256sum)
      let arguments = [host.binary, host.socket, "1", String(repeating: "0", count: 64)]
      let command = (["sh", "-c", script, "install"] + arguments)
        .map(PosixShell.quoted).joined(separator: " ")
      let stream = try await host.driver.exec(command, on: self.host)
      let (status, output) = try await stream.communicate(
        try Data(contentsOf: build), timeout: 10)
      XCTAssertEqual(status, 1, output)
      XCTAssertEqual(DaemonBootstrap.parseInstall(output).outcome.joined(separator: " "), said)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: host.directory.path), [])
    }
  }

  /// The real probe and push against this Mac's `sh` (#239): the set lands beside the socket with
  /// every entry also in the letter directory Linux's ncurses looks under, the same build again
  /// pushes nothing, and a push that arrives short leaves the set that was there.
  func testTheRealScriptsPushTheResourceSetOnceAndKeepItWhole() async throws {
    let host = try localHost()
    let build = try standIn()
    let bundle = try XCTUnwrap(GhosttyResources.bundledURL)
    let first = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(first.resources, .pushed)
    let set = host.directory.appendingPathComponent("ghostty")
    for path in [
      "CHECKSUMS", "terminfo/78/xterm-ghostty", "terminfo/x/xterm-ghostty", "terminfo/g/ghostty",
      "shell-integration/zsh/.zshenv", "shell-integration/bash/ghostty.bash",
    ] {
      XCTAssertEqual(
        FileManager.default.contents(atPath: set.appendingPathComponent(path).path),
        FileManager.default.contents(
          atPath: bundle.appendingPathComponent(
            path.replacingOccurrences(of: "/x/", with: "/78/")
              .replacingOccurrences(of: "/g/", with: "/67/")
          ).path), path)
    }
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: host.directory.path)
        .contains { $0.hasPrefix("ghostty.") })
    let again = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(again.resources, .current)

    // A push cut short: the stream ends before the last file's bytes.
    let script = try DaemonBootstrap.script(named: "resources")
    let command = (["sh", "-c", script, "resources", set.path, "4", "a", "4", "CHECKSUMS"])
      .map(PosixShell.quoted).joined(separator: " ")
    let stream = try await host.driver.exec(command, on: self.host)
    let (status, output) = try await stream.communicate(Data("abcdCH".utf8), timeout: 10)
    XCTAssertEqual(status, 1, output)
    XCTAssertEqual(DaemonBootstrap.parseInstall(output).outcome, ["truncated", "CHECKSUMS"])
    let after = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(after.resources, .current)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: host.directory.path)
        .contains { $0.hasPrefix("ghostty.") })
  }

  /// A set that has lost or changed a file since it was pushed is pushed again rather than kept as
  /// current for good (#239). That includes the Linux terminfo entry, which the manifest does not
  /// list but the attach looks for before it uses the set: missing, or no longer the macOS entry it
  /// was copied from.
  func testTheRealProbePushesASetThatLostOrChangedAFileAgain() async throws {
    let host = try localHost()
    let build = try standIn()
    let bundle = try XCTUnwrap(GhosttyResources.bundledURL)
    let set = host.directory.appendingPathComponent("ghostty")
    let first = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(first.resources, .pushed)
    let damage: [(String, (URL) throws -> Void)] = [
      ("terminfo/x/xterm-ghostty", { try FileManager.default.removeItem(at: $0) }),
      ("terminfo/x/xterm-ghostty", { try Data("truncated".utf8).write(to: $0) }),
      ("shell-integration/zsh/.zshenv", { try FileManager.default.removeItem(at: $0) }),
      ("shell-integration/bash/ghostty.bash", { try Data("changed\n".utf8).write(to: $0) }),
    ]
    for (path, damageIt) in damage {
      let file = set.appendingPathComponent(path)
      let original = try XCTUnwrap(FileManager.default.contents(atPath: file.path), path)
      try damageIt(file)
      let repaired = try await ensure(host, bundling: build, resources: bundle)
      XCTAssertEqual(repaired.resources, .pushed, path)
      XCTAssertEqual(FileManager.default.contents(atPath: file.path), original, path)
    }
    let again = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(again.resources, .current)
  }

  /// A push whose rename into place fails leaves the set it was replacing where it was (#239):
  /// running shells still read their terminfo and integration from it.
  func testTheRealPushKeepsTheLiveSetWhenItCannotReplaceIt() async throws {
    let host = try localHost()
    let build = try standIn()
    let bundle = try XCTUnwrap(GhosttyResources.bundledURL)
    let first = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(first.resources, .pushed)
    // The host holds an older set, and cannot rename a staged one into place.
    let manifest = host.directory.appendingPathComponent("ghostty/CHECKSUMS")
    let older = try String(contentsOf: manifest, encoding: .utf8) + "# older\n"
    try older.write(to: manifest, atomically: true, encoding: .utf8)
    let mv = host.directory.deletingLastPathComponent().appendingPathComponent("shim/mv")
    try Data(
      "#!/bin/sh\ncase $1 in *.new.*) exit 1 ;; esac\nexec /bin/mv \"$@\"\n".utf8
    ).write(to: mv)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mv.path)

    let failed = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(failed.resources, .notPushed("write-failed"))
    XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), older)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: host.directory.path)
        .filter { $0.hasPrefix("ghostty") }, ["ghostty"])
  }

  /// Two pushes racing (#239): one whose rename finds the set back in place moves into it rather
  /// than over it. It takes its set back out and says so, rather than reporting an install that
  /// did not happen.
  func testTheRealPushThatLosesARaceSaysSoAndLeavesOneSet() async throws {
    let host = try localHost()
    let build = try standIn()
    let bundle = try XCTUnwrap(GhosttyResources.bundledURL)
    let first = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(first.resources, .pushed)
    let manifest = host.directory.appendingPathComponent("ghostty/CHECKSUMS")
    let older = try String(contentsOf: manifest, encoding: .utf8) + "# older\n"
    try older.write(to: manifest, atomically: true, encoding: .utf8)
    // Another push puts its own whole set in place just before this one renames: a copy of this
    // build's, as a Mac on the same build would push.
    let mv = host.directory.deletingLastPathComponent().appendingPathComponent("shim/mv")
    try Data(
      ("#!/bin/sh\ncase $1 in *.new.*) cp -R \"$1\" \"$2\" ;; esac\nexec /bin/mv \"$@\"\n").utf8
    ).write(to: mv)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mv.path)

    let raced = try await ensure(host, bundling: build, resources: bundle)
    XCTAssertEqual(raced.resources, .notPushed("raced"))
    // One whole set, the other push's, with nothing of this one's left in it.
    let set = host.directory.appendingPathComponent("ghostty")
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: set.path)
        .contains { $0.hasPrefix("ghostty.") })
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: host.directory.path)
        .filter { $0.hasPrefix("ghostty") }, ["ghostty"])
    for (installed, bundled) in [
      ("CHECKSUMS", "CHECKSUMS"), ("terminfo/x/xterm-ghostty", "terminfo/78/xterm-ghostty"),
      ("shell-integration/zsh/.zshenv", "shell-integration/zsh/.zshenv"),
    ] {
      XCTAssertEqual(
        FileManager.default.contents(atPath: set.appendingPathComponent(installed).path),
        FileManager.default.contents(atPath: bundle.appendingPathComponent(bundled).path),
        installed)
    }
    let verified = try SessionBackendProbe.run(
      URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "cd \(PosixShell.quoted(set.path)) && /sbin/sha256sum -c CHECKSUMS"],
      timeout: 10)
    XCTAssertEqual(verified.status, 0, verified.output)
  }
}
