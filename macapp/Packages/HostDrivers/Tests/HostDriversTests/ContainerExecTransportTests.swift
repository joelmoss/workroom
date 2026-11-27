import WorkroomDomain
import XCTest

@testable import HostDrivers

/// The container driver's transport (#308): its own runtime's `exec`, not ssh. Each check runs a
/// stub runtime, a script that records what it was asked and answers as the test says, so the real
/// argument lists and the real attach wrapper are what run.
final class ContainerExecTransportTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// A runtime that writes its arguments, one per line, to `args`, then runs `body`.
  private func stubRuntime(_ body: String = "exit 0") throws -> URL {
    let script = directory.appendingPathComponent("runtime")
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > \(directory.appendingPathComponent("args").path)
    \(body)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private var asked: [String] {
    get throws {
      try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
  }

  private func target(_ runtime: URL, dialect: ContainerRuntime = .docker)
    -> ContainerExecTransport.Target
  {
    ContainerExecTransport.Target(
      runtime: runtime, dialect: dialect, context: dialect == .docker ? "orbstack" : nil,
      container: "workroom-abc", user: "vscode",
      daemonSocket: "/home/vscode/.workroom/run/workroomd.sock")
  }

  /// A one-off command is a shell line, run by the container's `sh` as the remote user, with stdin
  /// kept open for the input `communicate` sends and closes; `--context` goes before `exec`.
  func testExecRunsAShellLineAsTheRemoteUser() async throws {
    let runtime = try stubRuntime("cat; echo out")
    let (status, output) = try await ContainerExecTransport.exec(
      "echo hi", on: target(runtime), purpose: .exchange
    ).communicate(Data("in\n".utf8), timeout: 10)
    XCTAssertEqual(status, 0)
    XCTAssertEqual(output, "in\nout\n")
    XCTAssertEqual(
      try asked,
      [
        "--context", "orbstack", "exec", "-i", "-u", "vscode", "workroom-abc", "sh", "-c",
        ContainerExecTransport.ownHome + "echo hi",
      ])
  }

  /// The remote user's HOME, from the passwd file, ahead of the command: Apple's `exec -u` leaves
  /// a non-root user's at `/`.
  func testTheCommandRunsWithTheUsersOwnHome() throws {
    let passwd = "root:x:0:0:root:/root:/bin/sh\nvscode:x:\(getuid()):1000::/home/vscode:/bin/zsh\n"
    let file = directory.appendingPathComponent("passwd")
    try passwd.write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      ContainerExecTransport.ownHome.replacingOccurrences(of: "/etc/passwd", with: file.path)
        + "echo \"$HOME\"",
    ]
    process.environment = ["HOME": "/", "PATH": "/usr/bin:/bin"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      "/home/vscode\n")
  }

  /// Apple's CLI takes the same `exec` flags, and has no contexts.
  func testAppleSpellsExecTheSameWithoutAContext() async throws {
    let runtime = try stubRuntime()
    _ = try await ContainerExecTransport.exec(
      "true", on: target(runtime, dialect: .apple), purpose: .exchange
    ).communicate(nil, timeout: 10)
    XCTAssertEqual(
      try asked,
      [
        "exec", "-i", "-u", "vscode", "workroom-abc", "sh", "-c",
        ContainerExecTransport.ownHome + "true",
      ])
  }

  /// The service stream is the daemon's relay, run by path, with no shell in between.
  func testTheStreamIsTheDaemonsRelay() throws {
    XCTAssertEqual(
      ContainerExecTransport.relayArguments(target(URL(fileURLWithPath: "/usr/bin/false"))),
      [
        "--context", "orbstack", "exec", "-i", "-u", "vscode", "workroom-abc",
        "/home/vscode/.workroom/run/workroomd", "relay", "--socket",
        "/home/vscode/.workroom/run/workroomd.sock",
      ])
  }

  private func attach(_ runtime: URL, session: UUID) throws -> (status: Int32, screen: String) {
    let command = ContainerExecTransport.attachCommand(
      on: target(runtime), in: directory, session: session, workingDirectory: "/workspaces/app",
      restored: false, metadata: [], runCommand: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let screen = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, screen)
  }

  /// A pane attaches through `exec -it` as the remote user, starting where the session is, running
  /// the same in-container attach as an ssh host's.
  func testAPaneAttachesThroughExecWithATerminal() throws {
    let runtime = try stubRuntime()
    let session = UUID()
    _ = try attach(runtime, session: session)
    let args = try asked
    XCTAssertEqual(
      Array(args.prefix(8)),
      ["--context", "orbstack", "exec", "-i", "-t", "-u", "vscode", "workroom-abc"])
    XCTAssertEqual(Array(args.dropFirst(8).prefix(2)), ["sh", "-c"])
    XCTAssertTrue(args.last?.contains("WORKROOM_SESSION_ID=\(session.uuidString)") ?? false)
    XCTAssertTrue(args.last?.contains("WORKROOM_SESSION_CWD=/workspaces/app") ?? false)
    XCTAssertTrue(args.last?.contains("attach") ?? false)
    // First, in the container, it waits for a postStartCommand not yet run since the start (#308).
    XCTAssertTrue(
      args.last?.hasPrefix(
        ContainerExecTransport.ownHome + ContainerHostDriver.postStartWait + "; ") ?? false)
    XCTAssertEqual(ContainerExecTransport.lastAttach(of: session, in: directory), .finished)
  }

  /// A restored pane's resume record (#826) reaches its in-container client by a file copied in
  /// over a separate `exec`'s stdin, never a command line: `0600` in a `0700` folder beside the
  /// daemon's socket, which the copy made and so marked as its own, with this Mac's file removed;
  /// the client is handed its path. Without a record it is handed none. The stub runtime runs each
  /// `exec`'s command here, as the container would.
  func testAPanesResumeRecordIsCopiedInOverStdinAndHandedToItsClient() throws {
    let runtime = try stubRuntime(
      "while [ \"$1\" != workroom-abc ]; do shift; done; shift; exec \"$@\"")
    let run = directory.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    let client = run.appendingPathComponent("workroomd")
    try """
    #!/bin/sh
    echo "RESUME=${WORKROOM_SESSION_RESUME-}"
    [ -n "${WORKROOM_SESSION_RESUME-}" ] && cat "$WORKROOM_SESSION_RESUME" && echo
    exit 0
    """.write(to: client, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
    let target = ContainerExecTransport.Target(
      runtime: runtime, dialect: .docker, context: nil, container: "workroom-abc", user: "vscode",
      daemonSocket: run.appendingPathComponent("workroomd.sock").path)
    let session = UUID()
    let id = session.uuidString.lowercased()
    let folder = run.appendingPathComponent("resume-launch")
    let mac = directory.appendingPathComponent("mac")
    try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
    let name = "resume-\(id)-\(String(repeating: "a", count: 32)).json"
    let record = mac.appendingPathComponent(name)
    try Data(#"{"argv":["claude","--resume","s3cr3t"],"cwd":"/w","reportedAt":1}"#.utf8)
      .write(to: record)

    func attach(_ resume: URL?) throws -> String {
      let command = ContainerExecTransport.attachCommand(
        on: target, in: directory, session: session, workingDirectory: "/workspaces/app",
        restored: true, metadata: [], runCommand: nil)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = ["PATH": "/usr/bin:/bin"].merging(
        resume.map { ["WORKROOM_SESSION_RESUME": $0.path] } ?? [:]
      ) { $1 }
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      try process.run()
      process.waitUntilExit()
      return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    let staged = folder.appendingPathComponent(name)
    let seen = try attach(record)
    XCTAssertTrue(seen.contains("RESUME=\(staged.path)"), seen)
    XCTAssertTrue(seen.contains("s3cr3t"), seen)
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.path), "the Mac's file goes")
    XCTAssertEqual(mode(staged.path), 0o600)
    XCTAssertEqual(mode(folder.path), 0o700)
    let marker = folder.appendingPathComponent(ContainerExecTransport.resumeMarker)
    XCTAssertEqual(mode(marker.path), 0o600, "the copy that made the folder marked it")
    XCTAssertEqual(
      try String(contentsOf: marker, encoding: .utf8),
      "Workroom made this folder for its resume launch files (ADR 0082), and removes only those.\n",
      "the app's and the daemon's marker, word for word")
    // Only the copy's own exec read the record, on stdin: no command line named its words.
    XCTAssertFalse(try asked.joined(separator: " ").contains("s3cr3t"))

    try FileManager.default.removeItem(at: staged)
    XCTAssertTrue(try attach(nil).contains("RESUME=\n"), "no record, none handed over")
  }

  private func mode(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? 0
  }

  /// A launch file's name, as `ResumeLaunchFile.name` makes one, for `session`.
  private func launchName(_ session: UUID, _ digit: Character) -> String {
    "resume-\(session.uuidString.lowercased())-\(String(repeating: digit, count: 32)).json"
  }

  /// Runs `stageResume` for `session` as the container's `sh` does, its record on stdin and its
  /// file's name as `$1`: the script alone, without an attach around it. Its exit status.
  @discardableResult
  private func stage(
    _ session: UUID, named name: String, socket: URL, path: String = "/usr/bin:/bin"
  ) throws -> Int32 {
    let input = directory.appendingPathComponent("record-\(UUID().uuidString)")
    try Data(#"{"argv":["claude"],"cwd":"/w","reportedAt":1}"#.utf8).write(to: input)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", ContainerExecTransport.stageResume(session: session, socket: socket.path), "stage",
      name,
    ]
    process.environment = ["PATH": path]
    process.standardInput = try FileHandle(forReadingFrom: input)
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// Sets `url`'s modification time `minutes` ago, without following a link.
  private func age(_ url: URL, minutes: Double) {
    var times = [timeval](repeating: timeval(), count: 2)
    let then = Date().timeIntervalSince1970 - minutes * 60
    times[0] = timeval(tv_sec: Int(then), tv_usec: 0)
    times[1] = times[0]
    XCTAssertEqual(lutimes(url.path, times), 0, url.path)
  }

  /// A copy into a folder it made itself (#826) removes the launch files an attach that never
  /// started left there, any session's, once they are an hour old, and nothing else: not another
  /// attach's fresh record, not a name the app never makes, and not a link or a FIFO with a launch
  /// file's name, which stay unread and unfollowed. fails_when=the sweep stops checking the age,
  /// the name or the file's type; why_new=#832's second review (a fresh record of another attach
  /// was deleted).
  func testACopyRemovesOnlyHourOldLaunchFilesInAFolderItMade() throws {
    let run = directory.appendingPathComponent("run")
    let socket = run.appendingPathComponent("workroomd.sock")
    let folder = run.appendingPathComponent("resume-launch")
    let session = UUID()
    let other = UUID()
    XCTAssertEqual(try stage(session, named: launchName(session, "1"), socket: socket), 0)
    let file = { (name: String) in folder.appendingPathComponent(name) }
    let old = [file(launchName(session, "2")), file(launchName(other, "3"))]
    let fresh = file(launchName(other, "4"))
    let notOurs = file("resume-\(session.uuidString.lowercased())-notes.json")
    let upper = file("resume-\(session.uuidString)-\(String(repeating: "5", count: 32)).json")
    for url in old + [fresh, notOurs, upper] { try Data("{}".utf8).write(to: url) }
    let outside = directory.appendingPathComponent("outside.json")
    try Data("keep".utf8).write(to: outside)
    let link = file(launchName(other, "6"))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let fifo = file(launchName(other, "7"))
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    for url in old + [notOurs, upper, link, fifo, outside] { age(url, minutes: 62) }
    age(fresh, minutes: 59)

    XCTAssertEqual(try stage(session, named: launchName(session, "8"), socket: socket), 0)

    let exists = { (url: URL) in (try? url.checkResourceIsReachable()) == true || Self.isLink(url) }
    for url in old { XCTAssertFalse(exists(url), "an hour-old launch file goes: \(url.path)") }
    for url in [fresh, notOurs, upper, link, fifo, outside, file(launchName(session, "1"))] {
      XCTAssertTrue(exists(url), "stays: \(url.lastPathComponent)")
    }
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    XCTAssertTrue(exists(file(launchName(session, "8"))), "the new record is written")
  }

  /// An image with no `find` still takes the record (#826), in a folder made and marked as ever,
  /// and sweeps nothing. fails_when=making or checking the folder needs `find`; why_new=#832's
  /// second review round.
  func testAnImageWithoutFindStillTakesTheRecordAndSweepsNothing() throws {
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    for tool in ["id", "mkdir", "chmod", "cat", "rm"] {
      let found = try XCTUnwrap(
        ["/bin", "/usr/bin"].map { "\($0)/\(tool)" }
          .first { FileManager.default.isExecutableFile(atPath: $0) }, tool)
      try FileManager.default.createSymbolicLink(
        at: tools.appendingPathComponent(tool), withDestinationURL: URL(fileURLWithPath: found))
    }
    let run = directory.appendingPathComponent("run")
    let socket = run.appendingPathComponent("workroomd.sock")
    let folder = run.appendingPathComponent("resume-launch")
    let session = UUID()
    let first = try stage(
      session, named: launchName(session, "1"), socket: socket, path: tools.path)
    XCTAssertEqual(first, 0)
    let left = folder.appendingPathComponent(launchName(session, "2"))
    try Data("{}".utf8).write(to: left)
    age(left, minutes: 62)

    XCTAssertEqual(
      try stage(session, named: launchName(session, "3"), socket: socket, path: tools.path), 0)

    XCTAssertTrue(FileManager.default.fileExists(atPath: left.path), "no find, no sweep")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent(launchName(session, "3")).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent(ContainerExecTransport.resumeMarker).path))
    XCTAssertEqual(mode(folder.path), 0o700)
  }

  private static func isLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  /// A folder the copy did not make (#826), whether found there unmarked or with a marker that is
  /// a link, holds other contents or another type, is never swept, though it still takes the
  /// record and is made `0700`; one that is itself a link is refused, and nothing is written.
  /// fails_when=a folder found already there is swept, or a forged marker counts;
  /// why_new=#832's second review (a folder `mkdir -p` accepted was swept).
  func testAFolderTheCopyDidNotMakeIsNeverSwept() throws {
    let session = UUID()
    let markerText =
      "Workroom made this folder for its resume launch files (ADR 0082), and removes only those.\n"
    let real = directory.appendingPathComponent("real-marker")
    try Data(markerText.utf8).write(to: real)
    let forgeries: [(String, (URL) throws -> Void)] = [
      ("unmarked", { _ in }),
      ("a link", { try FileManager.default.createSymbolicLink(at: $0, withDestinationURL: real) }),
      ("other contents", { try Data("Workroom made this folder\n".utf8).write(to: $0) }),
      ("its text without the newline", { try Data(markerText.dropLast().utf8).write(to: $0) }),
      (
        "a folder",
        { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) }
      ),
    ]
    for (index, (label, forge)) in forgeries.enumerated() {
      let run = directory.appendingPathComponent("run\(index)")
      let folder = run.appendingPathComponent("resume-launch")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try forge(folder.appendingPathComponent(ContainerExecTransport.resumeMarker))
      let left = folder.appendingPathComponent(launchName(session, "0"))
      try Data("{}".utf8).write(to: left)
      age(left, minutes: 62)

      let socket = run.appendingPathComponent("workroomd.sock")
      XCTAssertEqual(try stage(session, named: launchName(session, "a"), socket: socket), 0, label)

      XCTAssertTrue(FileManager.default.fileExists(atPath: left.path), "\(label): nothing swept")
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: folder.appendingPathComponent(launchName(session, "a")).path), label)
      XCTAssertEqual(mode(folder.path), 0o700, label)
      if index == 0 {
        XCTAssertFalse(
          FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(ContainerExecTransport.resumeMarker).path),
          "a folder found already there is never marked")
      }
    }

    let run = directory.appendingPathComponent("linked")
    let elsewhere = directory.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: run.appendingPathComponent("resume-launch"), withDestinationURL: elsewhere)
    XCTAssertNotEqual(
      try stage(
        session, named: launchName(session, "b"),
        socket: run.appendingPathComponent("workroomd.sock")), 0)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
  }

  /// The wait itself, in a shell: none without a hook or once it is done; with a hook not done, it
  /// waits and says so.
  func testAPaneWaitsForAPostStartNotYetRun() throws {
    let root = directory.appendingPathComponent("poststart")
    let hook = root.appendingPathComponent("hook").path
    let done = root.appendingPathComponent("done").path
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let wait = ContainerHostDriver.postStartWait
      .replacingOccurrences(of: ContainerHostDriver.postStartHook, with: hook)
      .replacingOccurrences(of: ContainerHostDriver.postStartDone, with: done)
    func run() throws -> (seconds: TimeInterval, said: String) {
      let started = Date()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", wait + "; echo attached"]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      process.waitUntilExit()
      return (
        Date().timeIntervalSince(started),
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      )
    }
    XCTAssertEqual(try run().said, "attached\n", "no hook waits")
    FileManager.default.createFile(atPath: hook, contents: nil)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
      FileManager.default.createFile(atPath: done, contents: nil)
    }
    let (seconds, said) = try run()
    XCTAssertGreaterThan(seconds, 1)
    XCTAssertTrue(said.hasPrefix("Waiting for the dev container's postStartCommand"), said)
    XCTAssertTrue(said.hasSuffix("attached\n"), said)
    XCTAssertEqual(try run().said, "attached\n", "a done one waits")
  }

  /// A stopped container is a link that comes back (the workroom starts it when opened): recorded
  /// as one, said in plain words, and not a refusal. The session's own failure is its own.
  func testAStoppedContainerIsALostLinkNotTheSessionsExit() throws {
    let stopped = try stubRuntime(
      "echo 'Error response from daemon: container workroom-abc is not running' >&2; exit 1")
    let session = UUID()
    let (status, screen) = try attach(stopped, session: session)
    XCTAssertEqual(status, 255)
    XCTAssertEqual(ContainerExecTransport.lastAttach(of: session, in: directory), .lostLink)
    XCTAssertTrue(screen.contains(SSHTransport.retryNotice), screen)
    XCTAssertFalse(ContainerExecTransport.refusedLastAttach(of: session, in: directory))

    let exitedOne = try stubRuntime("exit 1")
    let other = UUID()
    XCTAssertEqual(try attach(exitedOne, session: other).status, 1)
    XCTAssertEqual(ContainerExecTransport.lastAttach(of: other, in: directory), .finished)
  }

  /// A container that's gone won't come back: the pane says so and stops trying.
  func testAMissingContainerIsARefusal() throws {
    let gone = try stubRuntime(
      "echo 'Error response from daemon: No such container: workroom-abc' >&2; exit 1")
    let session = UUID()
    let (_, screen) = try attach(gone, session: session)
    XCTAssertTrue(ContainerExecTransport.refusedLastAttach(of: session, in: directory))
    XCTAssertTrue(screen.contains("No such container"), screen)
  }
}
