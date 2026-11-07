import DaemonConnection
import DaemonConnectionTestSupport
import Synchronization
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// The File service end to end: the shipped Rust daemon, the real Swift client, real repositories and
/// real filesystem changes. Mirrors `DaemonVCSIntegrationTests`, and is where the two halves of the
/// wire contract (`file.rs`/`watch.rs` and `DaemonFileProvider`/`DaemonClient`) are proven to agree.
final class DaemonFileIntegrationTests: XCTestCase {
  private var roots: [URL] = []
  private var daemons: [DaemonHarness] = []
  private var fakes: [FakeDaemon] = []
  private var connections: [DaemonClient] = []

  override func tearDown() {
    for daemon in daemons { daemon.stop() }
    for fake in fakes { fake.stop() }
    for root in roots { try? FileManager.default.removeItem(at: root) }
    daemons = []
    fakes = []
    roots = []
    connections = []
    super.tearDown()
  }

  // MARK: Fixtures

  private var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in [
      "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
      "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ] {
      env.removeValue(forKey: key)
    }
    env["PATH"] = ShellEnvironment.path()
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    return env
  }

  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }

  @discardableResult
  private func run(_ tool: String, _ args: [String], at root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    process.environment = environment
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      XCTFail("\(tool) failed: \(text)")
      throw VCSError.io(text)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func gitRepo() throws -> URL {
    let root = try root()
    try run("git", ["init", "-b", "main"], at: root)
    try run("git", ["config", "user.name", "Test"], at: root)
    try run("git", ["config", "user.email", "test@example.com"], at: root)
    return root
  }

  private func connect() async throws -> (DaemonClient, DaemonHarness) {
    let daemon = try DaemonHarness.start(environment: environment)
    daemons.append(daemon)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: daemon.socketPath)
    connections.append(connection)
    return (connection, daemon)
  }

  private func context(_ root: URL, shared: Bool = false) async throws -> FileContext {
    let location = try await RepositoryLocation.local(root.path)
    return FileContext(location: location, sharedLocation: shared ? location : nil)
  }

  private func daemonFiles(_ root: URL, connection: DaemonClient) async throws
    -> FileProviding
  {
    try connection.files(context: try await context(root))
  }

  // MARK: Negotiation

  /// AC2: a protocol-2 daemon silently DROPS File envelopes, so the version is checked against the raw
  /// greeting before any is sent. Proven against a stand-in that records every service byte it gets.
  func testAProtocol2AgentIsNeverSentAFileEnvelopeAndReportsBackendVersion() async throws {
    let fake = try FakeDaemon(version: 2)
    fakes.append(fake)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let root = try gitRepo()
    let fileContext = try await context(root)
    XCTAssertThrowsError(try connection.files(context: fileContext)) { error in
      guard case VCSError.backendVersion = error else {
        return XCTFail("expected backendVersion, got \(error)")
      }
    }
    // Negotiation happened (VCS answered) and File was never spoken.
    XCTAssertEqual(Set(fake.receivedServices), [2], "only VCS envelopes may reach a v2 daemon")
    await connection.close()
  }

  /// A daemon that greets fine but answers `capabilities` with reads this client doesn't speak — a
  /// newer daemon left running across an app rollback — is a version fact, not an outage. It must be
  /// `backendVersion`, the one error the router serves natively on, not `serviceUnavailable`, which
  /// left every local repository unreadable until the daemon restarted.
  func testIncompatibleVCSCapabilitiesReportBackendVersion() async throws {
    let fake = try FakeDaemon(
      version: 3, capabilities: #"{"version":1,"result":{"version":2,"reads":12,"exec":2}}"#)
    fakes.append(fake)
    do {
      let connection = try await DaemonClient.connect(
        host: .local, socketPath: fake.socketPath)
      connections.append(connection)
      XCTFail("an incompatible daemon must not connect")
    } catch VCSError.backendVersion {
    } catch {
      XCTFail("expected backendVersion, got \(error)")
    }
  }

  /// A peer that stays connected but stops reading leaves `send` blocked on the serial write queue
  /// (the send timeout is off after the handshake). Timing out only the stuck request left the
  /// connection in use, so every later request queued behind that send and timed out in turn. The
  /// stuck request's deadline must retire the connection, so the next request fails at once and the
  /// next acquisition reconnects.
  /// A request that already completed must not retire the connection when its deadline fires: the
  /// send in progress then belongs to another request, which keeps its own deadline. `connect()`'s
  /// own `capabilities` request (2 s) is answered, then a request that cannot be read stalls.
  func testACompletedRequestsDeadlineDoesNotRetireTheConnection() async throws {
    let fake = try FakeDaemon(version: 2, stallAfterCapabilities: true)
    fakes.append(fake)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let stuck = DaemonVCSRequest(method: "status", path: String(repeating: "x", count: 900_000))
    let finished = Flag()
    let outcome = Task {
      _ = try? await connection.request(stuck, timeout: 20)
      finished.set()
    }
    try await Task.sleep(for: .seconds(3))
    XCTAssertFalse(
      finished.isSet, "the handshake's expired deadline retired the connection under a live send")
    await connection.close()
    await outcome.value
  }

  /// A request cancelled while its OWN send is stuck: cancellation takes it out of `pending`, but
  /// its bytes are still blocking the write queue, and nothing else would ever notice. Its send's
  /// own watchdog must still retire the connection, so the next request fails at once rather than
  /// queueing forever.
  func testACancelledRequestsStuckSendStillRetiresTheConnection() async throws {
    let fake = try FakeDaemon(version: 2, stallAfterCapabilities: true)
    fakes.append(fake)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let stuck = DaemonVCSRequest(method: "status", path: String(repeating: "x", count: 900_000))
    let request = Task { _ = try? await connection.request(stuck, timeout: 1) }
    try await Task.sleep(for: .milliseconds(200))
    request.cancel()
    await request.value
    try await Task.sleep(for: .seconds(1.5))
    let started = ContinuousClock.now
    do {
      _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
      XCTFail("the wedged connection must be retired")
    } catch {
      XCTAssertEqual(error as? HostConnectionError, .notDispatched)
    }
    XCTAssertLessThan(
      ContinuousClock.now - started, .seconds(1), "must fail at once, not queue behind the send")
  }

  private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
  }

  func testARequestStuckBehindAPeerThatStoppedReadingRetiresTheConnection() async throws {
    let fake = try FakeDaemon(version: 2, stallAfterCapabilities: true)
    fakes.append(fake)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    // Far larger than a Unix socket's send buffer, and under the one-envelope ceiling.
    let stuck = DaemonVCSRequest(method: "status", path: String(repeating: "x", count: 900_000))
    do {
      _ = try await connection.request(stuck, timeout: 0.5)
      XCTFail("a peer that never reads cannot answer")
    } catch {}
    let started = Date()
    do {
      _ = try await connection.request(DaemonVCSRequest(method: "capabilities"), timeout: 5)
      XCTFail("the wedged connection must be retired")
    } catch {
      // Refused, nothing sent: the connection is already closed.
      XCTAssertEqual(error as? HostConnectionError, .notDispatched)
    }
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 1, "must fail at once, not queue behind the stuck send")
  }

  /// A protocol-3 peer HAS the service, so a probe that goes unanswered is a transient failure, not
  /// proof of an old daemon. Reporting `backendVersion` here silently selected native access for the
  /// connection's whole life; it must be an explicit failure (and retire the connection so the next
  /// acquisition probes again).
  func testAV3AgentThatNeverAnswersTheFileProbeIsAFailureNotAnOldDaemon() async throws {
    let fake = try FakeDaemon(version: 3, files: false)
    fakes.append(fake)
    let connection = try await DaemonClient.connect(
      host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    XCTAssertTrue(fake.receivedServices.contains(3), "a protocol-3 peer is probed")
    let root = try gitRepo()
    let fileContext = try await context(root)
    XCTAssertThrowsError(try connection.files(context: fileContext)) { error in
      XCTAssertEqual(
        error as? HostConnectionError,
        .serviceUnavailable("File service negotiation failed; reconnecting."))
    }
  }

  /// The viewer's "too large" state and the daemon's read ceiling are two literals in two languages.
  /// If the viewer's cap rose alone, every open between them would fail as "File unavailable" instead
  /// of showing the too-large state. Read from the daemon's own capabilities reply.
  func testTheViewersReadCapIsTheDaemonsReadCeiling() async throws {
    let (connection, _) = try await connect()
    let reply = try await connection.fileRequest(DaemonFileRequest(method: "capabilities"))
    let capabilities = try DaemonFileReply<DaemonFileCapabilities>.decode(reply)
    XCTAssertEqual(capabilities.maxReadBytes, FileContentLoader.maxBytes)
    XCTAssertEqual(capabilities.version, 1)
  }

  /// A local host never loses its files to its daemon: whatever stops the daemon being obtained, the
  /// router hands back a provider that lists and reads natively, and `watch` THROWS (so the watcher
  /// keeps trying the daemon) instead of returning nil (which would read as "never").
  func testALocalHostNeverLosesItsFilesToItsDaemon() async throws {
    let root = try gitRepo()
    try "x\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let location = try await RepositoryLocation.local(root.path)

    let failures: [Error] = [
      VCSError.backendVersion("old daemon"), HostConnectionError.connectionLost,
      HostConnectionError.requestTimedOut, RepositoryRoutingError.unavailable(.local),
    ]
    for failure in failures {
      let router = RepositoryRouter(localFiles: { _ in throw failure })
      let files = try await router.files(for: location)
      let listing = try await files.list()
      XCTAssertEqual(FileListing.parse(listing.stdout), ["a.txt"], "\(failure)")
      let data = try await files.read(path: "a.txt", symlinks: .refuse, maxBytes: 100)
      XCTAssertEqual(data, Data("x\n".utf8), "\(failure)")
      do {
        _ = try await files.watch(root: root.path) { _ in }
        XCTFail("watch must throw while the daemon is unavailable, got nil or a handle")
      } catch { XCTAssertTrue(error is HostConnectionError, "\(error)") }
    }

    // No daemon configured at all (every test router): plain native, and `watch` is nil.
    let native = try await RepositoryRouter().files(for: location)
    XCTAssertTrue(native is NativeFileProvider)
    let handle = try await native.watch(root: root.path) { _ in }
    XCTAssertNil(handle)

    // Cancellation is the one thing that propagates: retrying work its caller abandoned helps nobody.
    let cancelled = RepositoryRouter(localFiles: { _ in throw CancellationError() })
    do {
      _ = try await cancelled.files(for: location)
      XCTFail("a cancelled acquisition must propagate")
    } catch { XCTAssertTrue(error is CancellationError) }

    // A REMOTE host has no native path: unavailability stays an explicit failure.
    let remote = try RepositoryLocation.remote(host: UUID(), path: "/private/tmp")
    do {
      _ = try await RepositoryRouter(localFiles: { _ in throw VCSError.backendVersion("old") })
        .files(for: remote)
      XCTFail("a remote host must never get a native provider")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(remote.host)) }
  }

  /// The daemon dying MID-SESSION: a provider that was working starts failing at the transport level,
  /// and the same idempotent request is re-run natively instead of failing the panel.
  func testADaemonThatDiesMidSessionFallsBackToNativeForListingAndReading() async throws {
    let (connection, daemon) = try await connect()
    let root = try gitRepo()
    try "x\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(localFiles: { try connection.files(context: $0) })
    let files = try await router.files(for: location)

    let before = try await files.list()
    XCTAssertEqual(FileListing.parse(before.stdout), ["a.txt"], "served by the daemon")

    daemon.stop()
    let after = try await files.list()
    XCTAssertEqual(FileListing.parse(after.stdout), ["a.txt"], "served natively")
    let data = try await files.read(path: "a.txt", symlinks: .refuse, maxBytes: 100)
    XCTAssertEqual(data, Data("x\n".utf8))
  }

  func testAFileServiceIsBoundToItsHostAndRefusedOnAClosedConnection() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let foreign = FileContext(
      location: try RepositoryLocation.remote(host: UUID(), path: "/private/tmp"),
      sharedLocation: nil)
    XCTAssertThrowsError(try connection.files(context: foreign)) {
      XCTAssertEqual($0 as? HostConnectionError, .mismatchedContext)
    }
    let files = try await daemonFiles(root, connection: connection)
    await connection.close()
    let fileContext = try await context(root)
    XCTAssertThrowsError(try connection.files(context: fileContext)) {
      XCTAssertEqual($0 as? HostConnectionError, .connectionLost)
    }
    // A provider that outlived its connection fails explicitly rather than returning empty data,
    // and says nothing was sent: for a write that is the difference between "may have completed"
    // and a safe retry.
    do {
      _ = try await files.list()
      XCTFail("a closed connection must fail")
    } catch { XCTAssertEqual(error as? HostConnectionError, .notDispatched) }
  }

  // MARK: Listing

  func testDaemonListingMatchesTheNativeListingForGitIncludingAwkwardNames() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    try ".build/\n".write(
      to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
    for name in ["tracked.txt", "untracked.txt", "with space.txt", "with\nnewline.txt", "café.txt"]
    {
      try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try "x".write(
      to: root.appendingPathComponent(".build/ignored.o"), atomically: true, encoding: .utf8)
    try run("git", ["add", ".gitignore", "tracked.txt"], at: root)

    let context = try await context(root)
    let daemon = try connection.files(context: context)
    let native = NativeFileProvider(context: context)
    let viaDaemon = try await daemon.list()
    let viaNative = try await native.list()
    XCTAssertEqual(viaDaemon.exitCode, 0)
    XCTAssertEqual(
      FileListing.parse(viaDaemon.stdout), FileListing.parse(viaNative.stdout))
    XCTAssertFalse(viaDaemon.stdout.contains("ignored.o"))
    XCTAssertTrue(viaDaemon.stdout.contains("with\nnewline.txt"))
  }

  func testListingOutsideARepositoryIsTheToolsOwnFailureOnBothPaths() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let context = try await context(root)
    let viaDaemon = try await connection.files(context: context).list()
    let viaNative = try await NativeFileProvider(context: context).list()
    XCTAssertNotEqual(viaDaemon.exitCode, 0)
    XCTAssertEqual(viaDaemon.exitCode, viaNative.exitCode)
  }

  /// D12: over the capture cap is a typed failure, never a short list. The native cap is injectable;
  /// the daemon's 4 MiB cap is proven in `file_service.rs` against a 22,000-file repository.
  func testANativeListingOverTheCaptureCapIsATypedFailure() async throws {
    let root = try gitRepo()
    for index in 0..<50 {
      try "x".write(
        to: root.appendingPathComponent("file-number-\(index).txt"), atomically: true,
        encoding: .utf8)
    }
    let context = try await context(root)
    let capped = NativeFileProvider(context: context, runner: StatusCommandRunner(maxBytes: 100))
    do {
      _ = try await capped.list()
      XCTFail("a truncated listing must throw")
    } catch { XCTAssertEqual(error as? FileServiceError, .listingTruncated) }

    let whole = try await NativeFileProvider(context: context).list()
    XCTAssertFalse(whole.stdoutTruncated)
    let result = await FileTreeModel.list(
      location: context.location, runner: StatusCommandRunner(maxBytes: 100),
      router: RepositoryRouter())
    XCTAssertEqual(result, .tooLarge)
  }

  // MARK: Reading

  func testAReadRoundTripsBytesIncludingAMultiEnvelopeReply() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let bytes = Data((0..<2_500_000).map { UInt8($0 % 251) })
    try bytes.write(to: root.appendingPathComponent("big.bin"))
    try Data().write(to: root.appendingPathComponent("empty"))
    let files = try await daemonFiles(root, connection: connection)
    let big = try await files.read(path: "big.bin", symlinks: .refuse, maxBytes: 8 * 1024 * 1024)
    XCTAssertEqual(big, bytes)
    let empty = try await files.read(path: "empty", symlinks: .refuse, maxBytes: 10)
    XCTAssertTrue(empty.isEmpty)
  }

  // Value: protects=the app's `resolve` request and the daemon's reply agree on the wire, and each
  // refusal lands as the error the remote cmd-click acts on (#327): a link is followed on the
  // host; a path out of the root is `.refused`; a missing one is `.notFound`; a path the daemon will
  // not look up is `.failed`, which isn't the unknown-method reply, so the app skips it;
  // fails_when=the method name, the `path` key, or the daemon's error tags drift from what
  // `DaemonFileProvider` decodes; why_new=the real-daemon round trip in RemoteHostIntegrationTests
  // skips without the ssh fixture, and no other test sends `resolve` to the shipped daemon;
  // seam=none
  func testAResolveFollowsALinkOnTheDaemonAndItsRefusalsKeepTheirKind() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let fm = FileManager.default
    try fm.createDirectory(
      at: root.appendingPathComponent("nested/dir"), withIntermediateDirectories: true)
    try "x\n".write(
      to: root.appendingPathComponent("nested/file.rb"), atomically: true, encoding: .utf8)
    try "decoy\n".write(
      to: root.appendingPathComponent("file.rb"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path, withDestinationPath: "nested/dir")
    let outside = root.deletingLastPathComponent().appendingPathComponent(
      "outside-\(UUID().uuidString)")
    try fm.createDirectory(
      at: outside.appendingPathComponent("dir"), withIntermediateDirectories: true)
    roots.append(outside)
    try "secret".write(
      to: outside.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("out").path,
      withDestinationPath: outside.appendingPathComponent("dir").path)
    let files = try await daemonFiles(root, connection: connection)

    let resolved = try await files.resolve(path: "link/../file.rb")
    XCTAssertEqual(resolved, "nested/file.rb", "the file beside the link's target, not the decoy")

    func failure(_ path: String) async -> FileServiceError? {
      do {
        _ = try await files.resolve(path: path)
        return nil
      } catch { return error as? FileServiceError }
    }
    guard case .refused = await failure("out/../secret") else {
      return XCTFail("a link out of the root must be refused")
    }
    guard case .notFound = await failure("nope/../file.rb") else {
      return XCTFail("a missing directory before the `..` must be not found")
    }
    guard case .failed = await failure("../file.rb") else {
      return XCTFail("a path climbing the root as written must not be looked up")
    }
  }

  // Value: protects=the app tells a daemon that predates `resolve` from one that failed, by the
  // daemon's own reply to a method it doesn't know; fails_when=the daemon's wording drifts from
  // `DaemonFileProvider.unknownMethod`, so an old daemon's clicks stop falling back; why_new=the
  // unit tests throw the constant itself, so only the real daemon can pin it; seam=none
  func testTheDaemonAnswersAnUnknownFileMethodWithTheTextTheAppMatches() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let request = DaemonFileRequest(method: "no-such-method", root: root.path)
    do {
      _ = try DaemonFileReply<DaemonFileSubscription>.decode(
        await connection.fileRequest(request))
      XCTFail("an unknown method was answered")
    } catch FileServiceError.failed(let message) {
      XCTAssertEqual(message, DaemonFileProvider.unknownMethod)
    }
  }

  /// One matrix, run against BOTH providers: a check that exists on one path and not the other is the
  /// bug (the native path used to check a path and then open it, and never guarded against a FIFO).
  func testTheContainmentMatrixHoldsOnTheDaemonPath() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    try await assertContainmentMatrix(
      try await daemonFiles(root, connection: connection), root: root)
  }

  func testTheContainmentMatrixHoldsOnTheNativePath() async throws {
    let root = try gitRepo()
    try await assertContainmentMatrix(
      NativeFileProvider(context: try await context(root)), root: root)
  }

  private func assertContainmentMatrix(
    _ files: FileProviding, root: URL, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let fm = FileManager.default
    let outside = try root.deletingLastPathComponent().appendingPathComponent(
      "outside-\(UUID().uuidString)")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    roots.append(outside)
    let evil = root.deletingLastPathComponent().appendingPathComponent(
      root.lastPathComponent + "-evil")
    try fm.createDirectory(at: evil, withIntermediateDirectories: true)
    roots.append(evil)
    try "secret".write(
      to: outside.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
    try "evil".write(to: evil.appendingPathComponent("x"), atomically: true, encoding: .utf8)
    try fm.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try fm.createDirectory(
      at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "hello".write(
      to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try "0123456789A".write(  // 11 bytes
      to: root.appendingPathComponent("big"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("alias").path, withDestinationPath: "src/a.txt")
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("escape").path,
      withDestinationPath: outside.appendingPathComponent("secret").path)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("linked").path, withDestinationPath: outside.path)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("prefix").path,
      withDestinationPath: evil.appendingPathComponent("x").path)
    XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)

    func read(_ path: String, _ policy: FileSymlinkPolicy, max: Int = 100) async -> Result<
      Data, Error
    > {
      do {
        return .success(try await files.read(path: path, symlinks: policy, maxBytes: max))
      } catch {
        return .failure(error)
      }
    }
    func refused(_ path: String, _ policy: FileSymlinkPolicy, _ label: String) async {
      let result = await read(path, policy)
      guard case .failure(let error) = result, case FileServiceError.refused = error else {
        return XCTFail(
          "\(label) [\(policy)] should be refused, got \(result)", file: file, line: line)
      }
    }

    for policy in [FileSymlinkPolicy.followWithinRoot, .refuse] {
      let plain = await read("src/a.txt", policy)
      XCTAssertEqual(try plain.get(), Data("hello".utf8), file: file, line: line)
      await refused("escape", policy, "a link out of the root")
      await refused("linked/secret", policy, "a directory link out of the root")
      await refused("pipe", policy, "a FIFO")
      await refused("sub", policy, "a directory")
    }
    // The two policies differ on exactly one thing: a link that stays inside the root.
    let followed = await read("alias", .followWithinRoot)
    XCTAssertEqual(try followed.get(), Data("hello".utf8), file: file, line: line)
    await refused("alias", .refuse, "a leaf link")
    await refused("prefix", .followWithinRoot, "a sibling sharing the root's name prefix")

    let missing = await read("nope", .refuse)
    guard case .failure(let missingError) = missing, case FileServiceError.notFound = missingError
    else { return XCTFail("a missing file is notFound, got \(missing)", file: file, line: line) }
    let traversal = await read("../x", .refuse)
    guard case .failure(let traversalError) = traversal,
      case FileServiceError.failed = traversalError
    else { return XCTFail("a climbing path is rejected, got \(traversal)", file: file, line: line) }

    let over = await read("big", .refuse, max: 10)
    guard case .failure(let overError) = over, case FileServiceError.tooLarge = overError
    else { return XCTFail("over max_bytes is tooLarge, got \(over)", file: file, line: line) }
    let atLimit = await read("big", .refuse, max: 11)
    XCTAssertEqual(try atLimit.get().count, 11, file: file, line: line)
  }

  // MARK: Watching

  private final class Deliveries: Sendable {
    private let items = Mutex<[(paths: [String], overflow: Bool)]>([])
    func add(_ paths: [String], _ overflow: Bool) {
      items.withLock { $0.append((paths, overflow)) }
    }
    var all: [(paths: [String], overflow: Bool)] { items.withLock { $0 } }
    func touched(_ name: String) -> Bool {
      all.contains { $0.paths.contains { $0.hasSuffix(name) } }
    }
    func wait(_ timeout: TimeInterval = 8, until condition: @Sendable () -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return condition()
    }
  }

  func testASubscriptionDeliversARealChangeAndStopsAfterUnwatch() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let files = try await daemonFiles(root, connection: connection)
    let seen = Deliveries()
    let watched = try await files.watch(root: root.path) { event in
      if case .changed(let paths, let overflow) = event { seen.add(paths, overflow) }
    }
    let handle = try XCTUnwrap(watched)
    // Settle: FSEvents may still be reporting the directory's own creation.
    _ = await seen.wait(1.5) { false }

    try "1".write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    let got = await seen.wait { seen.touched("first.txt") }
    XCTAssertTrue(got, "a leading event carrying the changed path")
    XCTAssertTrue(seen.all.allSatisfy { !$0.overflow })

    await handle.cancel()
    let before = seen.all.count
    try "2".write(to: root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    _ = await seen.wait(2.5) { false }
    XCTAssertEqual(seen.all.count, before, "nothing is delivered after unwatch")
  }

  /// The coalescing bound, end to end: a sustained burst is two-ish deliveries, not one per write.
  func testABurstOfWritesCoalescesToAFewDeliveries() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let files = try await daemonFiles(root, connection: connection)
    let seen = Deliveries()
    let watched = try await files.watch(root: root.path) { event in
      if case .changed(let paths, let overflow) = event { seen.add(paths, overflow) }
    }
    let handle = try XCTUnwrap(watched)
    _ = await seen.wait(1.5) { false }
    let baseline = seen.all.count
    for index in 0..<300 {
      try "x".write(
        to: root.appendingPathComponent("burst-\(index).txt"), atomically: true, encoding: .utf8)
    }
    let last = await seen.wait { seen.touched("burst-299.txt") }
    XCTAssertTrue(last, "the trailing delivery reports the final state")
    let deliveries = seen.all.count - baseline
    XCTAssertLessThanOrEqual(deliveries, 4, "300 writes must not be ~300 deliveries")
    await handle.cancel()
  }

  func testEverySubscriptionLearnsWhenItsConnectionIsLost() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let files = try await daemonFiles(root, connection: connection)
    let lost = expectation(description: "lost")
    let watched = try await files.watch(root: root.path) { event in
      if event == .lost { lost.fulfill() }
    }
    let handle = try XCTUnwrap(watched)
    await connection.close()
    await fulfillment(of: [lost], timeout: 5)
    await handle.cancel()  // idempotent, and harmless on a dead connection
  }

  /// The host watcher end to end: routed to the daemon, and re-subscribed after the connection dies
  /// with exactly one synthetic refresh for the gap.
  @MainActor
  func testTheHostWatcherReconnectsAfterALostConnectionWithOneSyntheticRefresh() async throws {
    let daemon = try DaemonHarness.start(environment: environment)
    daemons.append(daemon)
    let root = try root()
    let seen = Deliveries()
    let current = ConnectionBox()
    let router = RepositoryRouter(localFiles: { [socket = daemon.socketPath] context in
      let connection = try await DaemonClient.connect(host: .local, socketPath: socket)
      current.set(connection)
      return try connection.files(context: context)
    })
    let watcher = HostFileWatcher(router: router) { paths, overflow in seen.add(paths, overflow) }
    watcher.start(path: root.path)
    defer { watcher.stop() }
    _ = await seen.wait(2) { false }
    try "1".write(to: root.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
    let first = await seen.wait { seen.touched("before.txt") }
    XCTAssertTrue(first)

    let before = seen.all.filter { $0.paths.isEmpty && $0.overflow }.count
    await current.connection?.close()
    let refreshed = await seen.wait {
      seen.all.filter { $0.paths.isEmpty && $0.overflow }.count == before + 1
    }
    XCTAssertTrue(refreshed, "one synthetic refresh once the new subscription is live")
    _ = await seen.wait(1.5) { false }
    XCTAssertEqual(
      seen.all.filter { $0.paths.isEmpty && $0.overflow }.count, before + 1,
      "and no more than one for one gap")

    try "2".write(to: root.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
    let after = await seen.wait { seen.touched("after.txt") }
    XCTAssertTrue(after, "changes flow again on the new generation")
  }

  /// With no daemon (or one that predates the File service) the same watcher is FSEvents, unchanged.
  @MainActor
  func testTheHostWatcherFallsBackToLocalFSEventsWhenTheDaemonCannotWatch() async throws {
    let root = try root()
    let seen = Deliveries()
    let watcher = HostFileWatcher(
      router: RepositoryRouter(localFiles: { _ in throw VCSError.backendVersion("old") })
    ) { paths, overflow in seen.add(paths, overflow) }
    watcher.start(path: root.path)
    defer { watcher.stop() }
    _ = await seen.wait(1.5) { false }
    try "1".write(to: root.appendingPathComponent("native.txt"), atomically: true, encoding: .utf8)
    // `WorkroomFileWatcher` reports the CHANGED DIRECTORY, not the file (no per-file events), so this
    // asserts that a delivery arrives, not what it names. Never `overflow`: nothing was missed.
    let got = await seen.wait { !seen.all.isEmpty }
    XCTAssertTrue(got)
    XCTAssertTrue(seen.all.allSatisfy { !$0.overflow })
  }

  private final class ConnectionBox: Sendable {
    private let value = Mutex<DaemonClient?>(nil)
    func set(_ connection: DaemonClient) { value.withLock { $0 = connection } }
    var connection: DaemonClient? { value.withLock { $0 } }
  }
}
