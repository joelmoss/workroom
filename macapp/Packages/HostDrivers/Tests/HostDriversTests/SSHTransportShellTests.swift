import Foundation
import XCTest

@testable import HostDrivers

final class SSHTransportShellTests: XCTestCase {
  /// Trust must persist the captured key; a discard device must never report a successful trust.
  func testKnownHostTrustRejectsDiscardTargetsAndKeepsRegularFileSymlinks() throws {
    let root = URL(fileURLWithPath: "/private/tmp/known-hosts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let discarded = root.appendingPathComponent("discard")
    try FileManager.default.createSymbolicLink(
      at: discarded, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
    for target in [URL(fileURLWithPath: "/dev/null"), discarded, root] {
      XCTAssertThrowsError(try SSHTransport.appendKnownHost("fixture-public-key", to: target)) {
        XCTAssertTrue($0.localizedDescription.contains("UserKnownHostsFile"))
        XCTAssertTrue($0.localizedDescription.contains("regular file"))
      }
    }
    let file = root.appendingPathComponent("known_hosts")
    try SSHTransport.appendKnownHost("first-key", to: file)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    try SSHTransport.appendKnownHost("second-key", to: alias)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first-key\nsecond-key\n")
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), file.path)
  }

  /// A stand-in for the Mac's `workroomd attach`: it records its arguments (one per line) and its
  /// environment beside itself, then exits with `status`.
  private struct FakeClient {
    let root: URL
    var path: String { root.appendingPathComponent("workroomd").path }
    var arguments: [String] {
      ((try? String(contentsOf: root.appendingPathComponent("argv"), encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
    var environment: [String: String] {
      let text =
        (try? String(contentsOf: root.appendingPathComponent("env"), encoding: .utf8)) ?? ""
      return Dictionary(
        text.split(separator: "\n").compactMap { line -> (String, String)? in
          guard let equals = line.firstIndex(of: "=") else { return nil }
          return (String(line[..<equals]), String(line[line.index(after: equals)...]))
        }, uniquingKeysWith: { _, last in last })
    }

    /// `logging`, when given, is what its ssh says in the log the pane names with `-E`.
    init(exiting status: Int32 = 0, logging: String? = nil) throws {
      root = URL(fileURLWithPath: "/private/tmp/attach-client-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let here = root.path
      let log =
        logging.map {
          "previous=; for argument in \"$@\"; do [ \"$previous\" = -E ] && "
            + "printf '%s\\n' \(SSHTransport.shellQuoted($0)) > \"$argument\"; "
            + "previous=$argument; done"
        } ?? ""
      try """
      #!/bin/sh
      for argument in "$@"; do printf '%s\\n' "$argument"; done > '\(here)/argv'
      env > '\(here)/env'
      \(log)
      exit \(status)
      """.write(toFile: path, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
  }

  /// Runs a pane's attach command as libghostty would, with `environment` over this process's.
  private func runPane(_ command: String, environment: [String: String] = [:]) throws
    -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
  }

  private static let socket = "/run/workroom/daemon/workroomd.sock"

  private func paneCommand(
    client: FakeClient, session: UUID, restored: Bool = false,
    metadata: [(key: String, value: String)] = [], runCommand: String? = nil
  ) -> String {
    SSHTransport.attachCommand(
      via: SSHTransport.Route(
        options: ["-F", "/hosts/ssh_config"], destination: "workroom-host",
        environment: ["SSH_AUTH_SOCK": "/agent.sock"]),
      in: client.root, daemonSocket: Self.socket, session: session, workingDirectory: "/w",
      restored: restored, metadata: metadata, runCommand: runCommand, client: client.path)
  }

  // Value: protects=ADR 0074's one attach path, the Mac's client dialing the host's relay over
  // `ssh -T`; fails_when=a pane runs `ssh -t … attach` on the host again, or ssh's `LocalCommand`
  // writes into the framed stream; why_new=#628 moves the attach client to the Mac; seam=the
  // pane's attach command
  /// A pane runs the Mac's `workroomd attach --dial`, whose command is ssh without a terminal to
  /// the host's `relay`, logging to the pane's attach log; a restored pane's is `--no-create`.
  func testAPaneRunsTheMacsClientDialingTheHostsRelayOverSshWithoutATerminal() throws {
    let client = try FakeClient()
    defer { try? FileManager.default.removeItem(at: client.root) }
    let session = UUID()
    let log = SSHTransport.attachLog(session, in: client.root).path

    let fresh = try runPane(paneCommand(client: client, session: session))
    XCTAssertEqual(fresh.status, 0, fresh.output)
    let arguments = client.arguments
    XCTAssertEqual(
      Array(arguments.dropLast()),
      [
        "attach", "--dial", "/usr/bin/ssh", "-F", "/hosts/ssh_config", "-E", log, "-T",
        "workroom-host",
      ])
    XCTAssertEqual(
      arguments.last,
      SSHTransport.loginShellCommand(SSHTransport.hostRelayCommand(socket: Self.socket)))

    _ = try runPane(paneCommand(client: client, session: session, restored: true))
    XCTAssertEqual(Array(client.arguments.prefix(3)), ["attach", "--no-create", "--dial"])
  }

  // Value: protects=the session contract a remote pane hands its host (metadata, keepalive, run
  // command); fails_when=one of them stops reaching the client, or a session variable the app
  // inherited goes to the host as this session's; why_new=the client now runs in the pane's own
  // environment on the Mac (#628); seam=the pane's attach command
  /// The client is given the session's id, working directory, keepalive opt-in, workroom and
  /// title, `xterm-ghostty`, the route's ssh agent, and a run tab's command; the pane's own
  /// session variables are cleared first.
  func testThePanesClientCarriesTheSessionContractAndNoInheritedSessionVariables() throws {
    let client = try FakeClient()
    defer { try? FileManager.default.removeItem(at: client.root) }
    let session = UUID()
    let inherited = [
      "WORKROOM_SESSION_RUN": "1", "WORKROOM_SESSION_COMMAND": "rm -rf ~",
      "WORKROOM_SESSION_SHELL": "/bin/zsh", "WORKROOM_SESSION_SOCKET": "/mac.sock",
      "WORKROOM_SESSION_PROJECT": "/Users/me/secret", "TERM": "xterm-256color",
    ]
    _ = try runPane(
      paneCommand(
        client: client, session: session,
        metadata: [
          (key: "workroom", value: "/w/one"), (key: "title", value: "Build"),
          (key: "project", value: "/Users/me/p"), (key: "tab", value: ""),
        ]), environment: inherited)
    var environment = client.environment
    XCTAssertEqual(environment["TERM"], "xterm-ghostty")
    XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/agent.sock")
    XCTAssertEqual(environment["WORKROOM_SESSION_ID"], session.uuidString)
    XCTAssertEqual(environment["WORKROOM_SESSION_CWD"], "/w")
    XCTAssertEqual(environment["WORKROOM_SESSION_KEEPALIVE"], "1")
    XCTAssertEqual(environment["WORKROOM_SESSION_WORKROOM"], "/w/one")
    XCTAssertEqual(environment["WORKROOM_SESSION_TITLE"], "Build")
    for name in [
      "WORKROOM_SESSION_RUN", "WORKROOM_SESSION_COMMAND", "WORKROOM_SESSION_SHELL",
      "WORKROOM_SESSION_SOCKET", "WORKROOM_SESSION_PROJECT", "WORKROOM_SESSION_TAB",
    ] {
      XCTAssertNil(environment[name], name)
    }

    _ = try runPane(paneCommand(client: client, session: session, runCommand: "bin/dev 'web'"))
    environment = client.environment
    XCTAssertEqual(environment["WORKROOM_SESSION_RUN"], "1")
    XCTAssertEqual(environment["WORKROOM_SESSION_COMMAND"], "bin/dev 'web'")
  }

  // Value: protects=refusal detection and the retry notice for a client-run pane; fails_when=the
  // wrapper stops recording the client's status, or shows the notice for a stop; why_new=the
  // wrapper now wraps the Mac's client rather than ssh (#628); seam=the pane's attach command
  /// The wrapper records the client's status and says the pane keeps trying for a 255, and only
  /// for that: a host's stop (1, the former layout) is the session's end, not a lost link.
  func testThePaneRecordsTheClientsStatusAndSaysItKeepsTryingOnlyForALostLink() throws {
    for (status, lastAttach) in [(Int32(255), LastAttach.lostLink), (1, .finished), (0, .finished)]
    {
      let client = try FakeClient(exiting: status)
      defer { try? FileManager.default.removeItem(at: client.root) }
      let session = UUID()
      let pane = try runPane(paneCommand(client: client, session: session))
      XCTAssertEqual(pane.status, status, pane.output)
      XCTAssertTrue(
        pane.output.hasPrefix("\u{1b}7workroom: waiting for this terminal's host..."), pane.output)
      XCTAssertEqual(pane.output.contains(SSHTransport.retryNotice), status == 255, pane.output)
      XCTAssertEqual(SSHTransport.lastAttach(of: session, in: client.root), lastAttach)
      XCTAssertFalse(SSHTransport.refusedLastAttach(of: session, in: client.root))
    }
  }

  // Value: protects=a pane stops on a host that refused it for good and keeps trying through a
  // lost link (#241); fails_when=a refusal in ssh's log isn't read as one, a refusal shows the
  // retry notice instead of ssh's reason, or a lost link stops showing it; seam=the pane's attach
  // command and `SSHTransport.refusedLastAttach`
  /// A changed host key, which ssh logs and exits 255 for, is a refusal: its reason is on screen
  /// and no retry notice is. A link that timed out, also 255, is not: the notice says the pane
  /// keeps trying, and ssh's reason stays in the log.
  func testARefusedAttachShowsSshsReasonAndALostLinkShowsTheRetryNotice() throws {
    let refusal = "Host key verification failed."
    let refused = try FakeClient(exiting: 255, logging: refusal)
    defer { try? FileManager.default.removeItem(at: refused.root) }
    let session = UUID()
    let pane = try runPane(paneCommand(client: refused, session: session))
    XCTAssertEqual(pane.status, 255, pane.output)
    XCTAssertTrue(SSHTransport.refusedLastAttach(of: session, in: refused.root))
    XCTAssertTrue(pane.output.contains(refusal), pane.output)
    XCTAssertFalse(pane.output.contains(SSHTransport.retryNotice), pane.output)

    let timeout = "ssh: connect to host ssh.example.invalid port 22: Operation timed out"
    let lost = try FakeClient(exiting: 255, logging: timeout)
    defer { try? FileManager.default.removeItem(at: lost.root) }
    let dropped = UUID()
    let retried = try runPane(paneCommand(client: lost, session: dropped))
    XCTAssertEqual(retried.status, 255, retried.output)
    XCTAssertFalse(SSHTransport.refusedLastAttach(of: dropped, in: lost.root))
    XCTAssertEqual(SSHTransport.lastAttach(of: dropped, in: lost.root), .lostLink)
    XCTAssertTrue(retried.output.contains(SSHTransport.retryNotice), retried.output)
    XCTAssertFalse(retried.output.contains(timeout), retried.output)
  }

  // Value: protects=a pane waiting on a host whose daemon the app couldn't update yet says so,
  // rather than that the host can't be reached (review #2); fails_when=the app's notice doesn't
  // replace the retry notice, or reaches the pane for anything but a lost link; seam=the pane's
  // attach command with `SSHTransport.withRetryNotice`
  func testAPaneSaysWhatTheAppSaysItIsWaitingFor() throws {
    let notice = "This terminal's host runs an older Workroom daemon (it's busy)."
    for status in [Int32(255), 1] {
      let client = try FakeClient(exiting: status)
      defer { try? FileManager.default.removeItem(at: client.root) }
      let pane = try runPane(
        SSHTransport.withRetryNotice(notice, paneCommand(client: client, session: UUID())))
      XCTAssertEqual(pane.status, status, pane.output)
      XCTAssertEqual(pane.output.contains(notice), status == 255, pane.output)
      XCTAssertFalse(pane.output.contains(SSHTransport.retryNotice), pane.output)
    }
  }

  /// Runs what a pane's ssh runs on the host, for a daemon socket under `root`.
  private func runOnHost(root: String) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
      "-c",
      SSHTransport.loginShellCommand(
        SSHTransport.hostRelayCommand(socket: root + "/daemon/workroomd.sock")),
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
  }

  // Value: protects=the statuses the Mac's client turns into retry or stop; fails_when=a host
  // with no daemon yet stops the pane, a former-layout host is retried forever, or the relay is
  // not what runs; why_new=the host side is now a guard in front of `relay` (#628); seam=the
  // command a pane's ssh runs on the host
  /// No daemon yet exits 255 (retry); only the former `wr-agent` exits 1 with its reason on
  /// stderr (stop); an installed daemon's `relay` replaces the shell, on the pane's socket.
  func testTheHostSideRelaysToTheInstalledDaemonOrSaysWhyNot() throws {
    let root = "/private/tmp/host-relay-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let daemon = root + "/daemon"
    try FileManager.default.createDirectory(atPath: daemon, withIntermediateDirectories: true)

    let missing = try runOnHost(root: root)
    XCTAssertEqual(missing.status, 255, missing.output)
    XCTAssertTrue(missing.output.contains("no daemon is installed"), missing.output)

    let former = DaemonInstall.formerBinary(besideSocket: daemon + "/workroomd.sock")
    try FileManager.default.createDirectory(
      atPath: (former as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(toFile: former, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: former)
    let old = try runOnHost(root: root)
    XCTAssertEqual(old.status, 1, old.output)
    XCTAssertTrue(old.output.contains(DaemonInstall.formerLayoutMessage), old.output)

    let binary = DaemonInstall.binary(besideSocket: daemon + "/workroomd.sock")
    try "#!/bin/sh\necho \"$$ $*\"\nexit 7\n".write(
      toFile: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
    let installed = try runOnHost(root: root)
    XCTAssertEqual(installed.status, 7, installed.output)
    XCTAssertTrue(
      installed.output.hasSuffix(" relay --socket \(daemon)/workroomd.sock\n"), installed.output)
  }

  func testMissingAttachBinaryKeepsTheRetryableTransportStatus() throws {
    let root = "/nonexistent-workroom-\(UUID().uuidString)"
    let script = SSHTransport.remoteAttachCommand(
      binary: root + "/workroomd", session: UUID(), socket: root + "/workroomd.sock",
      resources: root + "/resources", workingDirectory: "/", restored: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", SSHTransport.loginShellCommand(script)]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 255)
    XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("no daemon is installed"))
  }

  func testLoginShellBoundaryPreservesScriptBytesAndStdin() throws {
    let value = "quote' double\" slashes\\\\ dollar$ backtick`\nsecond line"
    let script =
      "IFS= read -r line; printf '%s\\n%s' \"$line\" "
      + SSHTransport.shellQuoted(value)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", SSHTransport.loginShellCommand(script)]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data("stdin\\\\untouched\n".utf8))
    try input.fileHandleForWriting.close()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "stdin\\\\untouched\n" + value)
  }
}
