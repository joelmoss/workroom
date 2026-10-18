import AgentConnection
import Defaults
import HostDrivers
import WorkroomSystem
import WorkroomVCS
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
    /// Where `openStream` connects, or nil for one that throws.
    var streamSocket: String?

    init(_ answers: [Answer]) { self.answers = answers }

    func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
    func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
    func openStream(to host: HostID) async throws -> HostStream {
      guard let streamSocket else { throw HostDriverError.notImplemented("openStream") }
      return try HostStream.spawn(
        URL(fileURLWithPath: "/usr/bin/nc"), ["-U", streamSocket], environment: [:],
        handshakeTimeout: 5, purpose: .connection)
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
        environment: [:], handshakeTimeout: 5, purpose: .exchange)
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

  /// The bootstrap with no Ghostty resource set, so each stub answers the agent's exchanges only;
  /// the set's own tests pass one.
  private func ensure(
    _ driver: StubDriver, agent: ((String) -> URL?)? = nil, handOff: Bool = true,
    resources: URL? = nil
  ) async throws -> AgentBootstrap.Outcome {
    try await AgentBootstrap.ensure(
      host: host, driver: driver, socket: socket, agent: agent ?? bundled(_:), handOff: handOff,
      resources: resources)
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
    // The probe carries the bundled digest per architecture, `-` for one this build lacks, and
    // where the Ghostty resource set goes.
    XCTAssertTrue(driver.commands[0].contains("'probe' '/run/workroom/wr-agent' "))
    XCTAssertTrue(
      driver.commands[0].hasSuffix("'1' '\(digest)' '-' '/run/workroom/ghostty'"),
      driver.commands[0])
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

  /// A bundled agent with build number `build`, as `handoff::BUILD_MARKER` keeps it in the binary.
  private func numberedAgent(_ build: UInt64) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-agent-linux-\(UUID().uuidString.prefix(8))")
    try Data("ELF bytes\0WR-AGENT-BUILD:\(build);\0more bytes\n".utf8).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func probe(installed: String, build: UInt64) -> StubDriver.Answer {
    .init(
      output:
        "WRB host Linux aarch64\nWRB installed \(installed)\nWRB build \(build)\nWRB hand-off none\n"
    )
  }

  /// Two Macs on different builds would otherwise each replace the host's agent with their own on
  /// every connect, and the older one would take the newer agent's services away (#255, D13).
  func testAHostRunningANewerBuildIsKeptAndNotPushedTo() async throws {
    let agent = try numberedAgent(100)
    let driver = StubDriver([probe(installed: String(repeating: "0", count: 64), build: 200)])
    let outcome = try await ensure(driver, agent: { $0 == "aarch64" ? agent : nil })
    XCTAssertEqual(
      outcome,
      .init(
        architecture: "aarch64", pushed: false,
        agent: .keptNewer("the host runs build 200, newer than this app's 100")))
    XCTAssertEqual(driver.commands.count, 1, "nothing was pushed")

    // Nor its terminfo and shell integration, which the newer agent's panes share.
    let withResources = StubDriver([probe(installed: String(repeating: "0", count: 64), build: 200)]
    )
    let kept = try await ensure(
      withResources, agent: { $0 == "aarch64" ? agent : nil },
      resources: try XCTUnwrap(GhosttyResources.bundledURL))
    XCTAssertEqual(kept.resources, .notPushed("the host runs a newer build"))
    XCTAssertEqual(withResources.commands.count, 1, "the resource set was pushed")
  }

  /// An older build, the same build under another hash (a dev build), or an agent that predates
  /// build numbers is replaced as before.
  func testAHostRunningAnOlderOrUnnumberedBuildIsPushedTo() async throws {
    let agent = try numberedAgent(200)
    for answer in [
      probe(installed: String(repeating: "0", count: 64), build: 100),
      probe(installed: String(repeating: "0", count: 64), build: 200),
      probe(installed: String(repeating: "0", count: 64), handOff: "none"),
    ] {
      let driver = StubDriver([answer, .init(output: "WRB outcome handed-off\n")])
      let outcome = try await ensure(driver, agent: { $0 == "aarch64" ? agent : nil })
      XCTAssertEqual(outcome.agent, .handedOff, answer.output)
      XCTAssertTrue(outcome.pushed, answer.output)
    }
  }

  func testTheBuildNumberIsReadFromTheBundledAgentsMarker() {
    XCTAssertEqual(
      AgentBootstrap.buildNumber(in: Data("x\0WR-AGENT-BUILD:1791188654;\0y".utf8)), 1_791_188_654)
    XCTAssertEqual(AgentBootstrap.buildNumber(in: Data("no marker here".utf8)), 0)
    XCTAssertEqual(AgentBootstrap.buildNumber(in: Data("WR-AGENT-BUILD:12".utf8)), 0, "cut short")
    XCTAssertEqual(AgentBootstrap.buildNumber(in: Data("WR-AGENT-BUILD:;".utf8)), 0, "empty")
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
        host: host, driver: mac, socket: socket, agent: bundled(_:), handOff: true,
        resources: nil)
      XCTFail("connected to a Mac")
    } catch AgentBootstrap.Error.unsupportedHost {}
    XCTAssertEqual(mac.commands.count, 1)
    let current = StubDriver([probe(installed: digest, handOff: "0 current")])
    do {
      _ = try await AgentBootstrap.connect(
        host: host, driver: current, socket: socket, agent: bundled(_:), handOff: true,
        resources: nil)
      XCTFail("the stub's openStream answered")
    } catch HostDriverError.notImplemented(let what) {
      XCTAssertEqual(what, "openStream")
    }
  }

  /// The Ghostty resource set (#239) is keyed by the hash of its `CHECKSUMS`: a host the probe
  /// finds holding it is pushed nothing, one without it gets every file the manifest lists and the
  /// manifest itself, and a push that fails is reported without failing the connect.
  func testTheResourceSetIsPushedOnlyToAHostWithoutIt() async throws {
    // A set of two small files: the stub only answers, and the bundle's own 70 KB go through the
    // real scripts below and on the fixture.
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-set-\(UUID().uuidString.prefix(8))")
    addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
    var manifest = ""
    for (path, content) in [
      ("terminfo/78/xterm-ghostty", "entry"), ("shell-integration/zsh/.zshenv", "zsh"),
    ] {
      let file = bundle.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: file)
      manifest += "\(try AgentBootstrap.digest(of: file))  \(path)\n"
    }
    try Data(manifest.utf8).write(to: bundle.appendingPathComponent("CHECKSUMS"))
    let set = try AgentBootstrap.digest(of: bundle.appendingPathComponent("CHECKSUMS"))
    let resources = "WRB resources \(set)\n"
    let current = StubDriver([
      .init(output: probe(installed: digest, handOff: "0 current").output + resources)
    ])
    let kept = try await ensure(current, resources: bundle)
    XCTAssertEqual(kept.resources, .current)
    XCTAssertEqual(current.commands.count, 1)
    XCTAssertTrue(
      current.commands[0].hasSuffix(" '-' '/run/workroom/ghostty'"), current.commands[0])

    let empty = StubDriver([
      probe(installed: digest, handOff: "0 current"),
      .init(output: "WRB received\nWRB outcome installed\n"),
    ])
    let pushed = try await ensure(empty, resources: bundle)
    XCTAssertEqual(pushed.resources, .pushed)
    XCTAssertEqual(pushed.agent, .current)
    let command = empty.commands[1]
    XCTAssertTrue(command.contains("'resources' '/run/workroom/ghostty' "), command)
    XCTAssertTrue(command.contains(" 'terminfo/78/xterm-ghostty' "), command)
    XCTAssertTrue(command.contains(" 'shell-integration/zsh/.zshenv' "), command)
    XCTAssertTrue(command.hasSuffix(" 'CHECKSUMS'"), command)

    let failing = StubDriver([
      probe(installed: digest, handOff: "0 current"),
      .init(output: "WRB received\nWRB outcome corrupt\n", status: 1),
    ])
    let failed = try await ensure(failing, resources: bundle)
    XCTAssertEqual(failed.resources, .notPushed("corrupt"))
    XCTAssertEqual(failed.agent, .current)
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
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
    let started = ContinuousClock.now
    do {
      _ = try await stream.communicate(nil, timeout: 20)
      XCTFail("a command that never exited returned")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("did not exit"), detail)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
  }

  // Value: protects=a carrier that closes its output and ignores SIGTERM, with no silence or
  // cancel, does not outlive the failed exchange; fails_when=that path stops escalating to SIGKILL
  // after its grace (#316); why_new=the test above's `sleep` dies on the first SIGTERM, and the
  // other carrier tests were already sent SIGTERM by the watchdog or a cancel; seam=none
  func testACarrierThatClosesItsOutputAndIgnoresSIGTERMIsKilled() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; exec 0<&- 1>&-; exec sleep 30"],
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
    defer { stopIfStillRunning(stream) }
    let started = ContinuousClock.now
    do {
      _ = try await stream.communicate(nil, timeout: 20)
      XCTFail("a command that never exited returned")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("did not exit"), detail)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
    assertGone(stream)
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
    for name in ["probe", "install", "resources"] {
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
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
    let started = ContinuousClock.now
    do {
      _ = try await stream.communicate(Data("x".utf8), timeout: 0.5)
      XCTFail("a hung exchange returned")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("moved nothing"), detail)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
  }

  /// A carrier that reads nothing and ignores SIGTERM (ignored dispositions survive the `exec`),
  /// so only the sockets' own shutdown can wake an exchange blocked sending to it.
  private func carrierThatNeitherReadsNorYieldsToSIGTERM() throws -> HostStream {
    try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; exec sleep 30"],
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
  }

  /// The carrier has exited and been reaped. Not `kill(pid, 0)`, which a reused pid would pass
  /// (see `AgentHarness.waitForExit`): an unexited child of ours reads 0 here.
  /// Failure-path cleanup for a carrier that ignores SIGTERM: a SIGKILL only while it is still an
  /// unexited child of ours, whose pid cannot have been reused. A passing test has seen it reaped.
  private func stopIfStillRunning(_ stream: HostStream) {
    if waitpid(stream.processIdentifier, nil, WNOHANG) == 0 {
      kill(stream.processIdentifier, SIGKILL)
    }
  }

  private func assertGone(_ stream: HostStream, line: UInt = #line) {
    XCTAssertNotEqual(
      waitpid(stream.processIdentifier, nil, WNOHANG), 0, "the carrier is still running", line: line
    )
  }

  // Value: protects=a push blocked on a far side that never reads is ended when the link goes
  // silent, reported as silence, and the carrier does not outlive it; fails_when=the watchdog
  // stops shutting down the carrier's input socket (#305), the exit check runs before the
  // watchdog's, or the exchange stops escalating to SIGKILL (#316); why_new=
  // testAnExchangeThatHangsIsEnded sends 1 byte, which never blocks; seam=none
  func testASilentFarSideThatNeverReadsDoesNotHoldABlockedPushOpen() async throws {
    let stream = try carrierThatNeitherReadsNorYieldsToSIGTERM()
    defer { stopIfStillRunning(stream) }
    let started = ContinuousClock.now
    do {
      _ = try await stream.communicate(Data(repeating: 0, count: 8_000_000), timeout: 0.5)
      XCTFail("a push nobody read returned")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("moved nothing"), detail)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
    assertGone(stream)
  }

  // Value: protects=a child of the carrier's own that holds the socket and ignores SIGTERM does not
  // outlive the exchange; fails_when=the escalation SIGKILLs only the carrier, not its tree (#316);
  // why_new=every other carrier test is a single process; seam=none
  func testASilentCarriersOwnChildIsKilledWithIt() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "carrier-child-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; wait"],
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
    defer { stopIfStillRunning(stream) }
    do {
      // Long enough for the shell to set its trap and write the pid before the silence ends it.
      _ = try await stream.communicate(nil, timeout: 2)
      XCTFail("a silent carrier returned")
    } catch HostConnectionError.serviceUnavailable(let detail) {
      XCTAssertTrue(detail.contains("moved nothing"), detail)
    }
    assertGone(stream)
    let child = try XCTUnwrap(
      pid_t(
        String(decoding: try Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines)))
    // Not our child, so no `waitpid`: launchd reaps it once its parent is gone. A second is far
    // too short for its pid to come round again.
    for _ in 0..<50 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
    let alive = kill(child, 0) == 0
    if alive { kill(child, SIGKILL) }
    XCTAssertFalse(alive, "the carrier's own child is still running")
  }

  // Value: protects=cancelling an exchange blocked sending ends it at once, and the carrier does
  // not outlive it; fails_when=cancel stops shutting down the carrier's input socket (#305), or
  // the exchange stops escalating to SIGKILL (#316); why_new=no test cancels an exchange at all;
  // seam=none
  func testCancellingAPushBlockedOnAFarSideThatNeverReadsEndsIt() async throws {
    let stream = try carrierThatNeitherReadsNorYieldsToSIGTERM()
    defer { stopIfStillRunning(stream) }
    let started = ContinuousClock.now
    let exchange = Task {
      try await stream.communicate(Data(repeating: 0, count: 8_000_000), timeout: 60)
    }
    try await Task.sleep(for: .milliseconds(300))
    exchange.cancel()
    do {
      _ = try await exchange.value
      XCTFail("a cancelled exchange returned")
    } catch is CancellationError {
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
    assertGone(stream)
  }

  /// The bound is on silence, not the exchange: a slow but steady far side that takes longer than
  /// the timeout is not ended (the `WRITE_TIMEOUT` lesson).
  func testASlowButSteadyExchangeIsNotEnded() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo x; sleep 0.2; done"],
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
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
      ], environment: [:], handshakeTimeout: 5, purpose: .exchange)
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
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
    let (status, output) = try await stream.communicate(
      Data(repeating: 0, count: 1_000_000), timeout: 5)
    XCTAssertEqual(status, 4)
    XCTAssertEqual(output, "said\n")
  }

  /// What the command printed comes back whole, with its stderr after, and its status.
  ///
  /// Many times over: the end of the input once failed to wake a `wc` blocked in `read`, in about
  /// one exchange in twenty here (#305), which one exchange would catch only now and then.
  func testAnExchangeReturnsWhatTheCommandSaidAndItsStatus() async throws {
    for attempt in 1...40 {
      let stream = try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "n=$(wc -c | tr -d ' '); echo \"got $n\"; echo oops >&2; exit 3"],
        environment: [:], handshakeTimeout: 5, purpose: .exchange)
      let (status, output) = try await stream.communicate(
        Data(repeating: 0, count: 100_000), timeout: 5)
      XCTAssertEqual(status, 3, "attempt \(attempt)")
      XCTAssertEqual(output, "got 100000\noops\n", "attempt \(attempt)")
    }
  }

  /// A host's shell startup can print anything ahead of the script; only the last 1 MiB is kept,
  /// and the report, which comes after all of it, is in that.
  func testAChattyStartupDoesNotDropTheReport() async throws {
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "head -c 3000000 /dev/zero | tr '\\0' x; echo; echo 'WRB host Linux aarch64'"],
      environment: [:], handshakeTimeout: 5, purpose: .exchange)
    let (status, output) = try await stream.communicate(nil, timeout: 5)
    XCTAssertEqual(status, 0)
    XCTAssertLessThanOrEqual(output.utf8.count, 1024 * 1024)
    XCTAssertTrue(output.hasSuffix("WRB host Linux aarch64\n"), String(output.suffix(40)))
  }

}
