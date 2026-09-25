import XCTest

@testable import Workroom

/// The app's half of the agent bootstrap (#231), against a driver whose host is a local `sh`
/// answering as the far-side scripts would. What the scripts themselves do on a Linux host is the
/// fixture's to prove (`RemoteHostIntegrationTests`, and the Rust `over_ssh_*` tests in CI).
final class AgentBootstrapTests: XCTestCase {
  /// A driver whose `exec` runs a local shell that swallows stdin and prints a canned answer.
  private final class StubDriver: HostDriver, @unchecked Sendable {
    struct Answer {
      let output: String
      var status: Int32 = 0
    }
    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var commands: [String] = []
    let traits = HostDriverTraits(
      transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
      durableDisk: false, maxLifetime: nil)

    init(_ answers: [Answer]) { self.answers = answers }

    func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
    func deriveFromBase(_ base: HostID) async throws -> HostID {
      throw HostDriverError.notImplemented("derive")
    }
    func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("openStream")
    }

    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      let answer = lock.withLock {
        commands.append(command)
        return answers.isEmpty ? Answer(output: "", status: 1) : answers.removeFirst()
      }
      return try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"),
        [
          "-c", "cat > /dev/null; printf '%s' \"$1\"; exit \"$2\"", "stub", answer.output,
          String(answer.status),
        ],
        environment: [:], handshakeTimeout: 5)
    }
  }

  private let host = HostID.remote(UUID())
  private let socket = "/run/workroom/agent.sock"
  private var agentFile: URL!
  private var digest = ""

  override func setUpWithError() throws {
    try super.setUpWithError()
    agentFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-agent-linux-\(UUID().uuidString.prefix(8))")
    try Data("not really an ELF\n".utf8).write(to: agentFile)
    digest = try AgentBootstrap.digest(of: agentFile)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: agentFile)
    try super.tearDownWithError()
  }

  private func bundled(_ architecture: String) -> URL? {
    architecture == "aarch64" ? agentFile : nil
  }

  private func ensure(
    _ driver: StubDriver, agent: ((String) -> URL?)? = nil, handOff: Bool = true
  ) async throws -> AgentBootstrap.Outcome {
    try await AgentBootstrap.ensure(
      host: host, driver: driver, socket: socket, agent: agent ?? bundled(_:), handOff: handOff)
  }

  private func probe(installed: String, handOff: String) -> StubDriver.Answer {
    .init(output: "WRB host Linux aarch64\nWRB installed \(installed)\nWRB hand-off \(handOff)\n")
  }

  func testAHostWithNoAgentGetsOneInstalledAndTheSupervisorStartsIt() async throws {
    let driver = StubDriver([
      probe(installed: "none", handOff: "none"),
      .init(output: "WRB outcome installed\nWRB serving yes\n"),
    ])
    let outcome = try await ensure(driver)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, agent: .installed))
    XCTAssertEqual(driver.commands.count, 2)
    // The probe carries the bundled digest per architecture, and `-` for one this build lacks.
    XCTAssertTrue(driver.commands[0].contains("'probe' '/run/workroom/wr-agent' "))
    XCTAssertTrue(driver.commands[0].hasSuffix("'1' '\(digest)' '-'"), driver.commands[0])
    // The install carries the digest, for the host to check what arrived against.
    XCTAssertTrue(driver.commands[1].contains("'install' '/run/workroom/wr-agent' "))
    XCTAssertTrue(driver.commands[1].hasSuffix("'1' '\(digest)'"), driver.commands[1])
  }

  /// A host holding this build with nothing listening (the supervisor's to start, as after a
  /// reboot), or with hand-off off, is pushed nothing either.
  func testAHostHoldingThisBuildWithNoAgentListeningIsPushedNothing() async throws {
    let idle = StubDriver([probe(installed: digest, handOff: "no-socket")])
    let outcome = try await ensure(idle)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: false, agent: .installed))
    let off = StubDriver([probe(installed: digest, handOff: "off")])
    let kept = try await ensure(off, handOff: false)
    XCTAssertEqual(
      kept, .init(architecture: "aarch64", pushed: false, agent: .keptOlder("hand-off is off")))
    XCTAssertTrue(off.commands[0].contains(" '0' '\(digest)'"), off.commands[0])
  }

  /// A link that dies mid-push (ssh's own 255, no report) is one failure classified one way,
  /// however far the exchange got: the agent that is there is kept, and the app connects to it.
  /// A host with nothing running fails instead. So does a probe cut short.
  func testALinkThatDiesMidPushKeepsTheAgentThatIsThere() async throws {
    let running = StubDriver([
      probe(installed: String(repeating: "0", count: 64), handOff: "none"),
      .init(output: "ssh: connection reset\n", status: 255),
    ])
    let outcome = try await ensure(running)
    XCTAssertTrue(outcome.pushed)
    XCTAssertEqual(outcome.agent, .keptOlder("the install failed: ssh: connection reset"))

    let empty = StubDriver([
      probe(installed: "none", handOff: "none"),
      .init(output: "", status: 255),
    ])
    do {
      _ = try await ensure(empty)
      XCTFail("a host with nothing running counted as connected")
    } catch AgentBootstrap.Error.transportFailed(let detail) {
      XCTAssertTrue(detail.contains("no answer"), detail)
    }

    let cut = StubDriver([
      .init(output: "WRB host Linux aarch64\nWRB installed \(digest)\n", status: 255)
    ])
    do {
      _ = try await ensure(cut)
      XCTFail("a probe cut short counted as current")
    } catch AgentBootstrap.Error.transportFailed(let detail) {
      XCTAssertTrue(detail.contains("did not finish"), detail)
    }

    // The push landed (`received`) and the link went during the checks: no outcome line, but the
    // agent that was there is still there.
    let midCheck = StubDriver([
      probe(installed: String(repeating: "0", count: 64), handOff: "none"),
      .init(output: "WRB received\n", status: 255),
    ])
    let kept = try await ensure(midCheck)
    XCTAssertEqual(kept.agent, .keptOlder("the install did not finish: WRB received"))
    let midCheckEmpty = StubDriver([
      probe(installed: "none", handOff: "none"),
      .init(output: "WRB received\n", status: 255),
    ])
    do {
      _ = try await ensure(midCheckEmpty)
      XCTFail("a host with nothing running counted as connected")
    } catch AgentBootstrap.Error.installFailed(let detail) {
      XCTAssertEqual(detail, "WRB received")
    }
  }

  /// A host without `sha256sum` cannot be compared with, and the install would refuse the push
  /// for the same reason, so it is not pushed to at all.
  func testAHostThatCannotHashIsNotPushedTo() async throws {
    let driver = StubDriver([probe(installed: "unknown", handOff: "none")])
    let outcome = try await ensure(driver)
    XCTAssertEqual(
      outcome,
      .init(architecture: "aarch64", pushed: false, agent: .keptOlder("the host has no sha256sum")))
  }

  /// A push that arrived short (a link that died mid-send) is refused by the host's digest check
  /// before anything runs, and the app connects to the agent that is there.
  func testATruncatedPushIsRefusedAndTheOldAgentIsKept() async throws {
    let driver = StubDriver([
      probe(installed: String(repeating: "0", count: 64), handOff: "none"),
      .init(output: "WRB outcome truncated \(String(repeating: "1", count: 64))\n", status: 1),
    ])
    let outcome = try await ensure(driver)
    XCTAssertTrue(outcome.pushed)
    XCTAssertEqual(
      outcome.agent,
      .keptOlder("the install failed: the push arrived incomplete"))
  }

  func testAHostAlreadyHoldingThisBuildIsPushedNothing() async throws {
    let driver = StubDriver([probe(installed: digest, handOff: "0 current")])
    let outcome = try await ensure(driver)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: false, agent: .current))
    XCTAssertEqual(driver.commands.count, 1)
  }

  func testAHostHoldingAnotherBuildIsPushedThisOneAndHandsOff() async throws {
    let driver = StubDriver([
      probe(installed: String(repeating: "0", count: 64), handOff: "none"),
      .init(output: "WRB outcome handed-off\n"),
    ])
    let outcome = try await ensure(driver)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, agent: .handedOff))
  }

  /// Refuse rather than kill: an agent that predates hand-off, or one that refused the new
  /// binary, keeps running, and the outcome says so rather than failing the connect.
  func testAnOlderAgentThatIsNotReplacedIsReportedNotFailed() async throws {
    let predates = StubDriver([
      probe(installed: "none", handOff: "none"),
      .init(output: "WRB outcome kept-older the agent predates hand-off\n"),
    ])
    let predated = try await ensure(predates)
    XCTAssertEqual(predated.agent, .keptOlder("the agent predates hand-off"))

    let refused = StubDriver([
      probe(installed: "none", handOff: "none"),
      .init(output: "WRB outcome refused error: cannot restore\n", status: 1),
    ])
    let outcome = try await ensure(refused)
    XCTAssertEqual(outcome.agent, .keptOlder("refused: error: cannot restore"))
    XCTAssertTrue(outcome.pushed)

    // The probe's own hand-off, against a file that is this build already.
    let probed = StubDriver([probe(installed: digest, handOff: "3 the agent predates hand-off")])
    let kept = try await ensure(probed)
    XCTAssertEqual(kept.agent, .keptOlder("the agent predates hand-off"))
    let handedOff = StubDriver([probe(installed: digest, handOff: "0 handed off")])
    let replaced = try await ensure(handedOff)
    XCTAssertEqual(replaced.agent, .handedOff)
    let silent = StubDriver([probe(installed: digest, handOff: "92")])
    let unsure = try await ensure(silent)
    XCTAssertEqual(unsure.agent, .keptOlder("the agent did not greet"))
  }

  func testABuildWithNoAgentForTheHostConnectsToWhatIsThereOrSaysSo() async throws {
    let running = StubDriver([probe(installed: String(repeating: "a", count: 64), handOff: "none")])
    let connected = try await ensure(running, agent: { _ in nil })
    XCTAssertEqual(connected.agent, .keptOlder("this build has no agent for aarch64"))
    let empty = StubDriver([probe(installed: "none", handOff: "none")])
    do {
      _ = try await ensure(empty, agent: { _ in nil })
      XCTFail("connected to a host with nothing to run")
    } catch AgentBootstrap.Error.noBundledAgent(let architecture) {
      XCTAssertEqual(architecture, "aarch64")
    }
  }

  func testAHostThatIsNotALinuxThisAppHasAnAgentForIsRefused() async throws {
    let mac = StubDriver([.init(output: "WRB host Darwin arm64\nWRB installed none\n")])
    do {
      _ = try await ensure(mac)
      XCTFail("bootstrapped a Mac")
    } catch AgentBootstrap.Error.unsupportedHost(let host) {
      XCTAssertEqual(host, "Darwin arm64")
    }
  }

  func testAnInstallThatDidNotEndInAnAgentFails() async throws {
    let notServing = StubDriver([
      probe(installed: "none", handOff: "none"),
      .init(output: "WRB outcome installed\nWRB serving no\n", status: 1),
    ])
    do {
      _ = try await ensure(notServing)
      XCTFail("an agent nobody started counted as installed")
    } catch AgentBootstrap.Error.installFailed(let detail) {
      XCTAssertTrue(detail.contains("supervisor"), detail)
    }
    let doesNotRun = StubDriver([
      probe(installed: "none", handOff: "none"),
      .init(output: "WRB outcome does-not-run\n", status: 1),
    ])
    do {
      _ = try await ensure(doesNotRun)
      XCTFail("a binary that does not run counted as installed")
    } catch AgentBootstrap.Error.installFailed(let detail) {
      XCTAssertTrue(detail.contains("does not run on this host"), detail)
    }
  }

  /// The probe's own hand-off, the answers the tests above leave out: `92` saying nothing listens
  /// is the supervisor's to start, and any other status is a refusal, reported as the agent said it.
  func testAProbedHandOffThatFoundNothingListeningOrWasRefused() async throws {
    let idle = StubDriver([probe(installed: digest, handOff: "92 error: no agent listening on /s")])
    let started = try await ensure(idle)
    XCTAssertEqual(started, .init(architecture: "aarch64", pushed: false, agent: .installed))
    let busy = StubDriver([probe(installed: digest, handOff: "1 busy: a client is attaching")])
    let refused = try await ensure(busy)
    XCTAssertEqual(refused.agent, .keptOlder("busy: a client is attaching"))
    let silent = StubDriver([probe(installed: digest, handOff: "1")])
    let unsaid = try await ensure(silent)
    XCTAssertEqual(unsaid.agent, .keptOlder("the hand-off was refused"))
  }

  /// An install whose agent already ran this build is current; one that could not write, or
  /// could not check what arrived, on a host with nothing running fails, naming why.
  func testAnInstallThatWasCurrentOrCouldNotWriteOnAnEmptyHost() async throws {
    let current = StubDriver([
      probe(installed: String(repeating: "0", count: 64), handOff: "none"),
      .init(output: "WRB received\nWRB outcome current\n"),
    ])
    let outcome = try await ensure(current)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, agent: .current))
    for (said, why) in [
      ("write-failed", "could not write beside the socket"),
      ("no-sha256sum", "the host has no sha256sum"),
    ] {
      let empty = StubDriver([
        probe(installed: "none", handOff: "none"),
        .init(output: "WRB outcome \(said)\n", status: 1),
      ])
      do {
        _ = try await ensure(empty)
        XCTFail("\(said) on a host with nothing running counted as connected")
      } catch AgentBootstrap.Error.installFailed(let detail) {
        XCTAssertEqual(detail, why)
      }
    }
  }

  /// `connect` is the bootstrap, then the stream: a host the bootstrap refuses is never opened,
  /// and one it accepts is (the stub's `openStream` throws, which is how that shows).
  func testConnectBootstrapsBeforeItOpensTheStream() async throws {
    let mac = StubDriver([.init(output: "WRB host Darwin arm64\nWRB installed none\n")])
    do {
      _ = try await AgentBootstrap.connect(
        host: host, driver: mac, socket: socket, agent: bundled(_:), handOff: true)
      XCTFail("connected to a Mac")
    } catch AgentBootstrap.Error.unsupportedHost {}
    XCTAssertEqual(mac.commands.count, 1)
    let current = StubDriver([probe(installed: digest, handOff: "0 current")])
    do {
      _ = try await AgentBootstrap.connect(
        host: host, driver: current, socket: socket, agent: bundled(_:), handOff: true)
      XCTFail("the stub's openStream answered")
    } catch HostDriverError.notImplemented(let what) {
      XCTAssertEqual(what, "openStream")
    }
  }

  /// The bundled binary's digest is the one `sha256sum` prints (the SHA-256 of "abc", FIPS 180-2),
  /// and an architecture this build has no agent for finds none.
  func testTheDigestIsSha256sumsAndAnUnknownArchitectureHasNoAgent() throws {
    let abc = FileManager.default.temporaryDirectory.appendingPathComponent(
      "abc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: abc) }
    try Data("abc".utf8).write(to: abc)
    XCTAssertEqual(
      try AgentBootstrap.digest(of: abc),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertNil(PersistentSessionPaths.linuxAgentURL(architecture: "riscv64"))
  }

  /// A far side that closes its output but never exits (a child of its own holding on, say) is
  /// waited for a bounded time, then ended, and the exchange throws.
  func testAnExchangeWhoseCommandClosesItsOutputButDoesNotExitIsEnded() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "exec 0<&- 1>&-; exec sleep 30"],
      environment: [:], handshakeTimeout: 5)
    let started = ContinuousClock.now
    do {
      _ = try await stream.communicate(nil, timeout: 20)
      XCTFail("a command that never exited returned")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("did not exit"), detail)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
  }

  /// A shell startup file on the host printing ahead of the script, or ssh's own stderr after
  /// it, is not the report.
  func testOnlyPrefixedLinesAreTheReport() throws {
    let report = try AgentBootstrap.parseProbe(
      "Welcome to the box\nWRB host Linux x86_64\nWRB installed none\nWRB hand-off none\n"
        + "Warning: Permanently added\n")
    XCTAssertEqual(
      report, .init(system: "Linux", architecture: "x86_64", installed: nil, handOff: .notAsked))
    XCTAssertThrowsError(try AgentBootstrap.parseProbe("Host key verification failed.\n")) {
      guard case AgentBootstrap.Error.transportFailed(let detail) = $0 else {
        return XCTFail("\($0)")
      }
      XCTAssertTrue(detail.contains("Host key verification failed"), detail)
    }
  }

  /// The scripts ship in the bundle, and parse.
  func testTheFarSideScriptsAreBundledAndParse() throws {
    for name in ["probe", "install"] {
      let script = try AgentBootstrap.script(named: name)
      XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"), name)
      let (status, output) = try SessionBackendProbe.run(
        URL(fileURLWithPath: "/bin/sh"), arguments: ["-n", "-c", script], timeout: 5)
      XCTAssertEqual(status, 0, "\(name): \(output)")
    }
  }

  /// A far side that hangs is ended, and the exchange throws rather than hanging the connect.
  func testAnExchangeThatHangsIsEnded() async throws {
    let stream = try HostStream.spawn(
      // `exec`, so the process ended is the one holding the stream's far end.
      URL(fileURLWithPath: "/bin/sh"), ["-c", "cat > /dev/null; exec sleep 30"],
      environment: [:], handshakeTimeout: 5)
    let started = ContinuousClock.now
    do {
      _ = try await stream.communicate(Data("x".utf8), timeout: 0.5)
      XCTFail("a hung exchange returned")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("moved nothing"), detail)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
  }

  /// The bound is on silence, not the exchange: a slow but steady far side that takes longer than
  /// the timeout is not ended (the `WRITE_TIMEOUT` lesson).
  func testASlowButSteadyExchangeIsNotEnded() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo x; sleep 0.2; done"],
      environment: [:], handshakeTimeout: 5)
    let (status, output) = try await stream.communicate(nil, timeout: 1)
    XCTAssertEqual(status, 0)
    XCTAssertEqual(output, String(repeating: "x\n", count: 10))
  }

  /// The same on the send side, which is the 11 MB push: a far side that reads slowly, taking
  /// longer than the bound in all, is not ended, because every piece sent resets it. One `send`
  /// of the whole input, or a bound not reset by sending, ends this one.
  func testASlowReaderIsNotEnded() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"),
      [
        "-c",
        "while [ $(( $(head -c 32768 | wc -c) )) -gt 0 ]; do sleep 0.1; done; echo drained",
      ], environment: [:], handshakeTimeout: 5)
    let (status, output) = try await stream.communicate(
      Data(repeating: 0, count: 1_000_000), timeout: 0.5)
    XCTAssertEqual(status, 0)
    XCTAssertEqual(output, "drained\n")
  }

  /// A far side that stops reading mid-push still gets to answer: what it printed before it
  /// closed its stdin comes back, with its status, rather than the send's `EPIPE` as an error.
  func testAFarSideThatStopsReadingStillAnswers() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "echo said; exec 0<&-; exit 4"],
      environment: [:], handshakeTimeout: 5)
    let (status, output) = try await stream.communicate(
      Data(repeating: 0, count: 1_000_000), timeout: 5)
    XCTAssertEqual(status, 4)
    XCTAssertEqual(output, "said\n")
  }

  /// What the command printed comes back whole, with its stderr after, and its status.
  func testAnExchangeReturnsWhatTheCommandSaidAndItsStatus() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "n=$(wc -c | tr -d ' '); echo \"got $n\"; echo oops >&2; exit 3"],
      environment: [:], handshakeTimeout: 5)
    let (status, output) = try await stream.communicate(
      Data(repeating: 0, count: 100_000), timeout: 5)
    XCTAssertEqual(status, 3)
    XCTAssertEqual(output, "got 100000\noops\n")
  }

  // MARK: - The bundled scripts, run for real

  /// A driver whose host is this Mac's own `sh`, running the bundled far-side scripts as a host's
  /// login shell would. So `parseProbe` and `parseInstall` meet what the scripts actually print,
  /// not a hand-typed answer. `uname` is shimmed to say Linux aarch64; the rest is the Mac's own
  /// coreutils, `/sbin/sha256sum` included. The fixture proves the same on a real Linux host.
  private final class LocalShellDriver: HostDriver, @unchecked Sendable {
    let path: String
    let traits = HostDriverTraits(
      transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
      durableDisk: false, maxLifetime: nil)

    init(path: String) { self.path = path }

    func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
    func deriveFromBase(_ base: HostID) async throws -> HostID {
      throw HostDriverError.notImplemented("derive")
    }
    func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("openStream")
    }

    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment: ["PATH": path],
        handshakeTimeout: 5)
    }
  }

  private struct LocalHost {
    let driver: LocalShellDriver
    let directory: URL
    var socket: String { directory.appendingPathComponent("agent.sock").path }
    var binary: String { AgentBootstrap.binary(besideSocket: socket) }
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

  /// An agent listening on the host's socket, as far as the scripts can tell (`-S`). The scripts
  /// never connect to it themselves: every hand-off goes through the stand-in's own answer.
  private func listen(on host: LocalHost) throws {
    let descriptor = try UnixSocketListener.listen(at: host.socket)
    addTeardownBlock { close(descriptor) }
  }

  /// A stand-in for a Linux agent build: a script answering the subcommands the far side runs
  /// (`protocol`, `hand-off`, `list`). Its content is its build, so two stand-ins that answer
  /// differently have different digests.
  private func standIn(
    protocol status: Int = 0, handOff: String = "echo current", list: Int = 0
  ) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-agent-standin-\(UUID().uuidString.prefix(8))")
    try Data(
      ("#!/bin/sh\ncase $1 in protocol) exit \(status) ;; hand-off) \(handOff); exit ;; "
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

  private func ensure(_ host: LocalHost, bundling build: URL, handOff: Bool = true) async throws
    -> AgentBootstrap.Outcome
  {
    try await AgentBootstrap.ensure(
      host: self.host, driver: host.driver, socket: host.socket,
      agent: { $0 == "aarch64" ? build : nil }, handOff: handOff)
  }

  /// The installed file's digest, and that no staged copy was left beside it.
  private func installed(on host: LocalHost, file: StaticString = #filePath, line: UInt = #line)
    throws -> String
  {
    let left = try FileManager.default.contentsOfDirectory(atPath: host.directory.path)
    XCTAssertFalse(left.contains { $0.contains(".new.") }, "\(left)", file: file, line: line)
    return try AgentBootstrap.digest(of: URL(fileURLWithPath: host.binary))
  }

  /// First connect to an empty host: installed, and the supervisor's start is waited for. Then
  /// the same build again pushes nothing, whether its agent is running or not.
  func testTheRealScriptsInstallOnAnEmptyHostAndThenPushNothing() async throws {
    let host = try localHost()
    let build = try standIn()
    let first = try await ensure(host, bundling: build)
    XCTAssertEqual(first, .init(architecture: "aarch64", pushed: true, agent: .installed))
    XCTAssertEqual(try installed(on: host), try AgentBootstrap.digest(of: build))
    let idle = try await ensure(host, bundling: build)
    XCTAssertEqual(idle, .init(architecture: "aarch64", pushed: false, agent: .installed))
    try listen(on: host)
    let running = try await ensure(host, bundling: build)
    XCTAssertEqual(running, .init(architecture: "aarch64", pushed: false, agent: .current))
  }

  func testTheRealScriptsHandANewerBuildOffToTheRunningAgent() async throws {
    let host = try localHost()
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    let newer = try standIn(handOff: "echo handed off")
    let outcome = try await ensure(host, bundling: newer)
    XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, agent: .handedOff))
    XCTAssertEqual(try installed(on: host), try AgentBootstrap.digest(of: newer))
  }

  /// A host without `sha256sum` says its installed file is `unknown`, not `none`: the app keeps
  /// the agent there instead of pushing to a host that would refuse the push anyway.
  func testTheRealProbeSaysUnknownOnAHostThatCannotHash() async throws {
    let host = try localHost(sha256sum: false)
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    let outcome = try await ensure(host, bundling: try standIn(handOff: "echo handed off"))
    XCTAssertEqual(
      outcome,
      .init(architecture: "aarch64", pushed: false, agent: .keptOlder("the host has no sha256sum")))
  }

  /// Refuse rather than kill: a build the running agent refuses, or one that does not run on the
  /// host, is removed, and the file the supervisor starts from is the old one still.
  func testTheRealScriptsLeaveTheOldFileWhenTheNewOneIsRefusedOrDoesNotRun() async throws {
    let host = try localHost()
    let older = try standIn()
    try preinstall(older, on: host)
    try listen(on: host)
    let refused = try await ensure(
      host, bundling: try standIn(handOff: "echo 'error: cannot restore' >&2; exit 1"))
    XCTAssertEqual(refused.agent, .keptOlder("refused: error: cannot restore"))
    XCTAssertEqual(try installed(on: host), try AgentBootstrap.digest(of: older))
    let broken = try await ensure(host, bundling: try standIn(protocol: 1))
    XCTAssertEqual(
      broken.agent, .keptOlder("the install failed: the bundled agent does not run on this host"))
    XCTAssertEqual(try installed(on: host), try AgentBootstrap.digest(of: older))
  }

  /// An agent that cannot be handed off (it predates hand-off, it did not greet, or hand-off is
  /// off) keeps running, and the new build is put in place for its next start.
  func testTheRealScriptsInstallForTheNextStartWhenTheAgentCannotHandOff() async throws {
    let host = try localHost()
    try preinstall(try standIn(), on: host)
    try listen(on: host)
    for (answer, why) in [
      ("echo too old; exit 3", "the agent predates hand-off"),
      ("echo timed out; exit 92", "the agent did not greet"),
    ] {
      let build = try standIn(handOff: answer)
      let outcome = try await ensure(host, bundling: build)
      XCTAssertEqual(outcome, .init(architecture: "aarch64", pushed: true, agent: .keptOlder(why)))
      XCTAssertEqual(try installed(on: host), try AgentBootstrap.digest(of: build), why)
    }
    let off = try standIn(handOff: "exit 9")
    let outcome = try await ensure(host, bundling: off, handOff: false)
    XCTAssertEqual(outcome.agent, .keptOlder("hand-off is off"))
    XCTAssertEqual(try installed(on: host), try AgentBootstrap.digest(of: off))
  }

  /// A host with nothing to run fails the connect: an install that could not write, and one the
  /// supervisor never started (the install waits 10s for it, so this test takes that long).
  func testTheRealScriptsFailAHostLeftWithNothingToRun() async throws {
    let host = try localHost()
    let build = try standIn()
    do {
      _ = try await AgentBootstrap.ensure(
        host: self.host, driver: host.driver,
        socket: "/nonexistent-\(UUID().uuidString.prefix(8))/agent.sock",
        agent: { $0 == "aarch64" ? build : nil }, handOff: true)
      XCTFail("an install that could not write counted as connected")
    } catch AgentBootstrap.Error.installFailed(let detail) {
      XCTAssertEqual(detail, "could not write beside the socket")
    }
    do {
      _ = try await ensure(host, bundling: try standIn(list: 1))
      XCTFail("an agent nobody started counted as installed")
    } catch AgentBootstrap.Error.installFailed(let detail) {
      XCTAssertTrue(detail.contains("supervisor"), detail)
    }
  }

  /// The install's own checks, run directly: a push that arrived short fails the digest the app
  /// sent, and a host that cannot hash refuses; either way nothing is left behind.
  func testTheRealInstallRefusesAPushItCannotCheck() async throws {
    let build = try standIn()
    let script = try AgentBootstrap.script(named: "install")
    let cases = [
      (true, "truncated \(try AgentBootstrap.digest(of: build))"), (false, "no-sha256sum"),
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
      XCTAssertEqual(AgentBootstrap.parseInstall(output).outcome.joined(separator: " "), said)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: host.directory.path), [])
    }
  }
}
