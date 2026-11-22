import DaemonConnection
import Defaults
import HostDrivers
import WorkroomDomain
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
    /// The host user's home, when a test gives it one; none otherwise, as the scripts need none.
    var home: String?

    init(path: String) { self.path = path }

    func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
    func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("openStream")
    }

    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", command],
        environment: ["PATH": path].merging(home.map { ["HOME": $0] } ?? [:]) { $1 },
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
  /// differently have different digests. `marker` is the build number the app reads out of the
  /// file's bytes (`DaemonBootstrap.buildNumber(in:)`), for a stand-in that is the app's bundle.
  private func standIn(
    protocol status: Int = 0, protocolFirst: String = ":", handOff: String = "echo current",
    list: Int = 0, marker: UInt64? = nil, daemonBuild: String? = nil, stamp: String = "",
    workroomSkill cli: String? = nil
  ) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workroomd-standin-\(UUID().uuidString.prefix(8))")
    let buildLine: String = marker.map { "# WORKROOMD-BUILD:\($0);\n" } ?? ""
    let daemonLine: String = daemonBuild.map { "# WORKROOMD-DAEMON-BUILD:\($0);\n" } ?? ""
    let markerLine: String = buildLine + daemonLine + (stamp.isEmpty ? "" : "# \(stamp)\n")
    let body: String =
      "case $1 in protocol) \(protocolFirst); exit \(status) ;; "
      + "hand-off) \(handOff); exit ;; "
      + (cli.map { "skill) exec \(PosixShell.quoted($0)) \"$@\" ;; " } ?? "")
      + "list) exit \(list) ;; esac\nexit 1\n"
    try Data(("#!/bin/sh\n" + markerLine + body).utf8).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// `build` already installed on `host`, as an earlier connect left it.
  private func preinstall(_ build: URL, on host: LocalHost) throws {
    try FileManager.default.copyItem(at: build, to: URL(fileURLWithPath: host.binary))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.binary)
  }

  private func ensure(
    _ host: LocalHost, bundling build: URL, handOff: Bool = true, resources: URL? = nil,
    workroomSkill: DaemonBootstrap.WorkroomSkillPolicy = .leave
  ) async throws -> DaemonBootstrap.Outcome {
    try await DaemonBootstrap.ensure(
      host: self.host, driver: host.driver, socket: host.socket,
      daemon: { $0 == "aarch64" ? build : nil }, handOff: handOff, resources: resources,
      workroomSkill: workroomSkill)
  }

  /// The real probe, and a host binary that answers `skill` as this build's does (it runs
  /// the bundled CLI), in a host home of its own holding only `.claude` (#697): the skill is
  /// installed there only with the setting on, left alone by a build that never had it on, and
  /// removed once the setting is turned off, after which the probe finds nothing more to remove.
  func testTheRealProbeAndBinaryInstallTheWorkroomSkillOnlyWhenOn() async throws {
    let host = try localHost()
    let home = host.directory.deletingLastPathComponent().appendingPathComponent("home")
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    host.driver.home = home.path
    let cli = try WorkroomCLI.bundledBinaryURL()
    let build = try standIn(workroomSkill: cli.path)
    try preinstall(build, on: host)
    try listen(on: host)
    let skill = home.appendingPathComponent(".claude/skills/workroom")
    let file = skill.appendingPathComponent("SKILL.md")

    var outcome = try await ensure(host, bundling: build)
    XCTAssertEqual(outcome.daemon, .current)
    XCTAssertNil(outcome.workroomSkill)
    XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path), "off writes nothing")

    outcome = try await ensure(host, bundling: build, workroomSkill: .install)
    XCTAssertEqual(outcome.workroomSkill?.summary, "claude installed, codex no-agent")
    XCTAssertTrue(
      try String(contentsOf: file, encoding: .utf8).hasPrefix("---\nname: workroom\n"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path),
      "no Codex on the host, so no ~/.codex")

    outcome = try await ensure(host, bundling: build)
    XCTAssertNil(outcome.workroomSkill, "a build that never had it on leaves it")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

    outcome = try await ensure(host, bundling: build, workroomSkill: .remove)
    XCTAssertEqual(outcome.workroomSkill?.summary, "claude removed, codex absent")
    XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))

    outcome = try await ensure(host, bundling: build, workroomSkill: .remove)
    XCTAssertNil(outcome.workroomSkill, "the probe found no skill, so nothing ran")
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

  /// How the host's systemd answers the start script (#665), through PATH shims: `loginctl` says
  /// whether the user lingers, `systemd-run` runs its command as the user manager would (its own
  /// environment, the unit's umask, no descriptors from ssh) or fails as a host's can, and
  /// `systemctl` names the unit's main pid. Each records the argv it was given.
  private struct Systemd {
    enum Run { case starts, fails, missing }
    var linger: String? = "yes"
    var run: Run = .starts
  }

  /// A start-script run on a local host, with a stand-in daemon that records how it was started.
  private struct StartHost {
    let host: LocalHost
    let shim: URL
    let alive: URL
    let pidFile: URL
    let record: URL
    var units: URL { shim.appendingPathComponent("units") }
    var screens: String { host.directory.appendingPathComponent("screens").path }
    func calls(_ tool: String) -> [String] {
      ((try? String(contentsOf: shim.appendingPathComponent("\(tool).calls"), encoding: .utf8))
        ?? "").split(separator: "\n").map(String.init)
    }
    var daemonPID: String? {
      (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(
        in: .whitespacesAndNewlines)
    }
  }

  private func startHost(systemd: Systemd?, setsid: Bool = true) throws -> StartHost {
    let host = try localHost()
    let shim = URL(
      fileURLWithPath: try XCTUnwrap(host.driver.path.split(separator: ":").first).description)
    func tool(_ name: String, _ body: String) throws {
      let url = shim.appendingPathComponent(name)
      try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let q = { (url: URL) in PosixShell.quoted(url.path) }
    // macOS has no setsid utility; the Linux fixture exercises the real one. This shim keeps the
    // actual backgrounding, descriptor redirections, argv and env -i in the script under test.
    if setsid { try tool("setsid", "exec \"$@\"\n") }
    let units = shim.appendingPathComponent("units")
    try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
    if let systemd {
      if let linger = systemd.linger {
        try tool(
          "loginctl",
          "printf '%s\\n' \"$*\" >> \(q(shim.appendingPathComponent("loginctl.calls")))\n"
            + "echo Linger=\(linger)\n")
      }
      try tool(
        "systemctl",
        """
        printf '%s\\n' "$*" >> \(q(shim.appendingPathComponent("systemctl.calls")))
        case $* in *' show '*) eval "unit=\\${$#}"; cat \(q(units))/"${unit%.service}" ;; esac
        exit 0

        """)
      switch systemd.run {
      case .missing: break
      case .fails:
        try tool(
          "systemd-run",
          "printf '%s\\n' \"$*\" >> \(q(shim.appendingPathComponent("systemd-run.calls")))\n"
            + "echo 'Failed to connect to bus: No medium found' >&2\nexit 1\n")
      case .starts:
        try tool(
          "systemd-run",
          """
          printf '%s\\n' "$*" >> \(q(shim.appendingPathComponent("systemd-run.calls")))
          unit= mask=
          while [ "$1" != -- ]; do
            case $1 in --unit=*) unit=${1#--unit=} ;; UMask=*) mask=${1#UMask=} ;; esac
            shift
          done
          shift
          if [ -e \(q(units))/"$unit" ]; then
            echo "Failed to start transient service unit: Unit $unit.service was already loaded or has a fragment file." >&2
            exit 1
          fi
          ( umask "${mask:-022}"; exec /usr/bin/env -i PATH=/usr/bin:/bin MANAGER=yes "$@" ) \\
            < /dev/null > /dev/null 2>&1 &
          echo $! > \(q(units))/"$unit"

          """)
      }
    }
    let alive = host.directory.appendingPathComponent("alive")
    let pidFile = host.directory.appendingPathComponent("pid")
    let record = host.directory.appendingPathComponent("record")
    let body = """
      #!/bin/sh
      case $1 in
        list) test -f \(q(alive)); exit ;;
        serve)
          printf '%s\\n' "$*" "$HOME" "$USER" "$SHELL" "$PATH" "${MUST_NOT_LEAK:-unset}" "${MANAGER:-unset}" > \(q(record))
          umask >> \(q(record))
          echo $$ > \(q(pidFile))
          : > \(q(alive))
          exec /bin/sleep 30 ;;
      esac
      exit 1
      """
    try Data(body.utf8).write(to: URL(fileURLWithPath: host.binary))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.binary)
    try listen(on: host)
    let started = StartHost(
      host: host, shim: shim, alive: alive, pidFile: pidFile, record: record)
    addTeardownBlock {
      if let pid = started.daemonPID.flatMap(Int32.init) { kill(pid, SIGKILL) }
    }
    return started
  }

  /// start.sh run as `DaemonBootstrap` runs it over the app's ssh login: umask 027, the login's
  /// environment plus a variable that must not reach the daemon.
  private func runStart(_ start: StartHost) async throws -> (status: Int32, output: String) {
    let arguments = [
      "sh", "-c", try DaemonBootstrap.script(named: "start"), "start", start.host.binary,
      start.host.socket, start.screens, "never",
    ]
    let command = arguments.map(PosixShell.quoted).joined(separator: " ")
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "umask 027; " + command],
      environment: [
        "PATH": start.host.driver.path, "HOME": start.host.directory.path, "USER": "server-user",
        "SHELL": "/bin/sh", "MUST_NOT_LEAK": "from-ssh",
      ], handshakeTimeout: 5, purpose: .exchange)
    let begun = ContinuousClock.now
    let result = try await stream.communicate(nil, timeout: 5)
    XCTAssertLessThan(ContinuousClock.now - begun, .seconds(5), "ssh's descriptors stayed open")
    return result
  }

  /// The daemon got the fixed argv, environment and the login's umask, however it was started.
  private func assertPinned(
    _ start: StartHost, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let lines = try String(contentsOf: start.record, encoding: .utf8).split(separator: "\n").map(
      String.init)
    XCTAssertEqual(
      Array(lines.dropLast()),
      [
        "serve --socket \(start.host.socket) --idle-timeout never --screens \(start.screens)",
        start.host.directory.path, "server-user", "/bin/sh", "/usr/local/bin:/usr/bin:/bin",
        "unset", "unset",
      ], file: file, line: line)
    XCTAssertEqual(Int(try XCTUnwrap(lines.last), radix: 8), 0o27, file: file, line: line)
  }

  /// The unit name start.sh derives from the socket path: `cksum`'s CRC of it.
  private func unitName(for socket: String) async throws -> String {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "printf %s \"$1\" | cksum", "sh", socket],
      environment: ["PATH": "/usr/bin:/bin"], handshakeTimeout: 5, purpose: .exchange)
    let (_, output) = try await stream.communicate(nil, timeout: 5)
    return "workroomd-" + (output.split(separator: " ").first.map(String.init) ?? "")
  }

  /// A user who lingers gets the daemon as a transient unit under their own systemd manager, which
  /// logout doesn't end (#665): named from the socket, collected when it ends, output to null so
  /// the daemon logs beside its socket, only its own process ended, and no restart policy. The
  /// daemon still gets today's fixed argv and environment, and setsid isn't needed.
  func testTheRealSSHStartRunsALingeringUsersDaemonAsAUserUnit() async throws {
    let start = try startHost(systemd: Systemd(), setsid: false)
    let (status, output) = try await runStart(start)
    XCTAssertEqual(status, 0, output)
    let pid = try XCTUnwrap(start.daemonPID, output)
    XCTAssertTrue(output.contains("WRB started \(pid)\n"), output)
    XCTAssertTrue(output.contains("WRB serving yes\n"), output)
    XCTAssertFalse(output.contains("systemd-run-failed"), output)
    XCTAssertEqual(start.calls("loginctl"), ["show-user server-user -p Linger"])
    let unit = try await unitName(for: start.host.socket)
    let runs = start.calls("systemd-run")
    XCTAssertEqual(runs.count, 1, "\(runs)")
    let run = try XCTUnwrap(runs.first)
    for option in [
      "--user", "--unit=\(unit)", "--collect", "-p KillMode=process", "-p UMask=0027",
      "-p StandardInput=null", "-p StandardOutput=null", "-p StandardError=null",
    ] {
      XCTAssertTrue(run.contains(option), "no \(option) in \(run)")
    }
    XCTAssertFalse(run.contains("Restart"), run)
    XCTAssertTrue(
      start.calls("systemctl").contains("--user show -p MainPID --value \(unit).service"),
      "\(start.calls("systemctl"))")
    try assertPinned(start)
  }

  /// No linger, no `loginctl` or no `systemd-run`: today's detached start, unchanged (#665). A
  /// default server's user manager stops soon after the last login, so a unit there would die.
  func testTheRealSSHStartKeepsTodaysStartWithoutLingerOrSystemd() async throws {
    for systemd in [
      Systemd(linger: "no"), Systemd(linger: nil), Systemd(run: .missing), nil,
    ] {
      let start = try startHost(systemd: systemd)
      let (status, output) = try await runStart(start)
      XCTAssertEqual(status, 0, output)
      let pid = try XCTUnwrap(start.daemonPID, output)
      XCTAssertTrue(output.contains("WRB started \(pid)\n"), output)
      XCTAssertTrue(output.contains("WRB serving yes\n"), output)
      XCTAssertFalse(output.contains("systemd-run-failed"), output)
      XCTAssertEqual(start.calls("systemd-run"), [], "\(String(describing: systemd))")
      try assertPinned(start)
    }
  }

  /// A lingering user whose systemd manager can't take the unit (no user bus, say) still gets a
  /// daemon, the detached way, and the report says why the unit failed, so a later survival error
  /// doesn't send them to enable the linger they already have.
  func testTheRealSSHStartFallsBackAndSaysWhyWhenSystemdRunFails() async throws {
    let start = try startHost(systemd: Systemd(run: .fails))
    let (status, output) = try await runStart(start)
    XCTAssertEqual(status, 0, output)
    XCTAssertTrue(
      output.contains("WRB systemd-run-failed Failed to connect to bus: No medium found\n"),
      output)
    let pid = try XCTUnwrap(start.daemonPID, output)
    XCTAssertTrue(output.contains("WRB started \(pid)\n"), output)
    XCTAssertTrue(output.contains("WRB serving yes\n"), output)
    XCTAssertEqual(start.calls("systemd-run").count, 2, "both names were tried")
    try assertPinned(start)
  }

  /// A unit a crashed daemon left a session's process in stays loaded, and its name can't be
  /// reused until that process ends. The start takes a name of its own instead of falling back to
  /// a daemon that logout would end (#665).
  func testTheRealSSHStartTakesItsOwnUnitNameWhenALeftoverHoldsTheSharedOne() async throws {
    let start = try startHost(systemd: Systemd())
    let shared = try await unitName(for: start.host.socket)
    // Loaded, as the shim's systemd-run sees a unit it already has.
    try Data("1\n".utf8).write(to: start.units.appendingPathComponent(shared))
    let (status, output) = try await runStart(start)
    XCTAssertEqual(status, 0, output)
    XCTAssertFalse(output.contains("systemd-run-failed"), output)
    let runs = start.calls("systemd-run")
    XCTAssertEqual(runs.count, 2, "\(runs)")
    XCTAssertTrue(runs[0].contains("--unit=\(shared) "), runs[0])
    XCTAssertNotNil(
      runs[1].range(of: "--unit=\(shared)-[0-9]+ ", options: .regularExpression), runs[1])
    let pid = try XCTUnwrap(start.daemonPID, output)
    XCTAssertTrue(output.contains("WRB started \(pid)\n"), output)
    try assertPinned(start)
  }

  /// A daemon that already answers is kept on either path: nothing is started.
  func testTheRealSSHStartKeepsALiveDaemonWhetherTheUserLingersOrNot() async throws {
    for systemd in [Systemd(), nil] {
      let start = try startHost(systemd: systemd)
      try Data().write(to: start.alive)
      let (status, output) = try await runStart(start)
      XCTAssertEqual(status, 0, output)
      XCTAssertEqual(output, "WRB serving yes\n")
      XCTAssertEqual(start.calls("systemd-run"), [])
      XCTAssertEqual(start.calls("loginctl"), [])
    }
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

  /// A newer build whose CLI commands alone changed (#680): another file, which is installed, and
  /// a daemon that answers `current` because its daemon build is the same, so nothing is handed
  /// off. The decision is the daemon's (`vcs/crates/workroomd/tests/daemon_bootstrap.rs`); here
  /// the app reads the real script's report of it.
  func testTheRealScriptsInstallACLIOnlyBuildWithoutHandingOff() async throws {
    let host = try localHost()
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    let cliOnly = try standIn(handOff: "echo current; :")
    let outcome = try await ensure(host, bundling: cliOnly)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, daemon: .current))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: cliOnly))
  }

  /// A host this build set up (#681, ADR 0078): the installed file is still `workroomd` (ADR 0057),
  /// a regular file, with a relative `workroom` link beside it for the host's panes. An older app
  /// (a lower build) connecting finds `workroomd`, sees the host is newer, and pushes nothing, so
  /// the link still names this build's file. The probe and its reading are v3.1.0's in everything
  /// this path runs, so a lower build of this code is that older app.
  func testAHostThisBuildSetUpKeepsWorkroomdAndAnOlderAppSeesItIsNewer() async throws {
    let host = try localHost()
    let ours = try standIn(protocolFirst: "echo build-number 200", marker: 200)
    let first = try await ensure(host, bundling: ours)
    XCTAssertEqual(first, .init(architecture: "aarch64", pushed: true, daemon: .installed))
    let link = host.directory.appendingPathComponent("workroom").path
    func assertLayout(_ why: String) throws {
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link), "workroomd", why)
      let attributes = try FileManager.default.attributesOfItem(atPath: host.binary)
      XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular, why)
      XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: ours), why)
    }
    try assertLayout("after this build's install")

    try listen(on: host)
    let older = try standIn(protocolFirst: "echo build-number 100", marker: 100)
    let outcome = try await ensure(host, bundling: older)
    XCTAssertEqual(
      outcome,
      .init(
        architecture: "aarch64", pushed: false,
        daemon: .keptNewer("the host runs build 200, newer than this app's 100")))
    try assertLayout("after an older app connected")
  }

  /// A Nightly and a stable app of one commit share a host (#681): their binaries are the same build
  /// and daemon build, and differ only in the version and channel stamped in. Neither pushes over
  /// the other; a build newer than the host's is still pushed.
  func testTheSameBuildOfTheSameDaemonStampedForAnotherChannelIsNotPushed() async throws {
    let host = try localHost()
    let answers = "echo build-number 200; echo daemon-build ab12"
    let stable = try standIn(
      protocolFirst: answers, marker: 200, daemonBuild: "ab12", stamp: "stable 3.2.0")
    try preinstall(stable, on: host)
    try listen(on: host)
    let nightly = try standIn(
      protocolFirst: answers, marker: 200, daemonBuild: "ab12", stamp: "nightly 3.2.0-nightly.9")
    let outcome = try await ensure(host, bundling: nightly)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: false, daemon: .current))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: stable))

    let newer = try standIn(
      protocolFirst: "echo build-number 201; echo daemon-build ab12", handOff: "echo current; :",
      marker: 201, daemonBuild: "ab12")
    let pushed = try await ensure(host, bundling: newer)
    XCTAssertEqual(pushed, .init(architecture: "aarch64", pushed: true, daemon: .current))
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: newer))
  }

  /// A link is made only where nothing but a link is: a file of the user's at `workroom` beside the
  /// daemon is left as it was, and the install still goes in.
  func testTheRealInstallLeavesAFileAtTheLinksNameAlone() async throws {
    let host = try localHost()
    let mine = host.directory.appendingPathComponent("workroom")
    try Data("not the daemon's\n".utf8).write(to: mine)
    let build = try standIn()
    let outcome = try await ensure(host, bundling: build)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, daemon: .installed))
    XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "not the daemon's\n")
    XCTAssertEqual(try installed(on: host), try DaemonBootstrap.digest(of: build))
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
      // The GPL-3.0 the bash and zsh integration are under goes beside them (#714).
      "shell-integration/zsh/LICENSE", "shell-integration/bash/LICENSE",
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
