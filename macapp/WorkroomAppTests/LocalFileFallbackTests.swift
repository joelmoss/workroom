import XCTest

@testable import Workroom

/// What a LOCAL host does when its agent fails. Native listing and reading are the fallback for a
/// transport-level failure of an idempotent request; a real answer from a healthy agent is never
/// second-guessed; and a persistently absent agent must not cost every call a spawn-and-handshake wait.
final class LocalFileFallbackTests: XCTestCase {
  private let location = try! RepositoryLocation.remote(host: UUID(), path: "/private/tmp")

  private var context: FileContext { FileContext(location: location, sharedLocation: nil) }

  /// A provider that answers, or fails, exactly as scripted.
  private struct Scripted: FileProviding {
    let context: FileContext
    var listing: Result<CommandResult, Error> = .success(
      CommandResult(stdout: "agent", stderr: "", exitCode: 0, timedOut: false))
    var content: Result<Data, Error> = .success(Data("agent".utf8))

    func list(_ vcs: FileListVCS) async throws -> CommandResult { try listing.get() }
    func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
      try content.get()
    }
    func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
      -> FileWatchHandle?
    { nil }
  }

  private func native(_ text: String) -> Scripted {
    Scripted(
      context: context,
      listing: .success(CommandResult(stdout: text, stderr: "", exitCode: 0, timedOut: false)),
      content: .success(Data(text.utf8)))
  }

  func testEveryTransportFailureFallsBack() async throws {
    let failures: [HostConnectionError] = [
      .connectionLost, .notDispatched, .requestTimedOut, .staleGeneration, .mismatchedContext,
      .serviceUnavailable("Invalid file response"),
    ]
    for failure in failures {
      let files = LocalFallbackFileProvider(
        primary: Scripted(context: context, listing: .failure(failure), content: .failure(failure)),
        fallback: native("native"))
      let listing = try await files.list(.git)
      XCTAssertEqual(listing.stdout, "native", "\(failure)")
      let data = try await files.read(path: "a", symlinks: .refuse, maxBytes: 1)
      XCTAssertEqual(data, Data("native".utf8), "\(failure)")
    }
  }

  /// A healthy agent's answer is the answer. Re-running these natively would either repeat the same
  /// verdict or, worse, override a refusal the agent enforced on purpose.
  func testASemanticAnswerFromAHealthyAgentIsNeverRetriedNatively() async {
    let answers: [Error] = [
      FileServiceError.refused("outside the repository root"), FileServiceError.tooLarge,
      FileServiceError.notFound("gone"), FileServiceError.listingTruncated,
      FileServiceError.failed("busy"), VCSError.lockContention,
      RepositoryRoutingError.registrationRequired,
    ]
    for answer in answers {
      let files = LocalFallbackFileProvider(
        primary: Scripted(context: context, listing: .failure(answer), content: .failure(answer)),
        fallback: native("native"))
      do {
        _ = try await files.list(.git)
        XCTFail("\(answer) must propagate from list")
      } catch { XCTAssertEqual("\(error)", "\(answer)") }
      do {
        _ = try await files.read(path: "a", symlinks: .refuse, maxBytes: 1)
        XCTFail("\(answer) must propagate from read")
      } catch { XCTAssertEqual("\(error)", "\(answer)") }
    }
  }

  func testAHealthyAgentIsUsedAndCancellationPropagates() async throws {
    let healthy = LocalFallbackFileProvider(
      primary: Scripted(context: context), fallback: native("native"))
    let listing = try await healthy.list(.git)
    XCTAssertEqual(listing.stdout, "agent")

    let cancelled = LocalFallbackFileProvider(
      primary: Scripted(
        context: context, listing: .failure(CancellationError()),
        content: .failure(CancellationError())),
      fallback: native("native"))
    do {
      _ = try await cancelled.list(.git)
      XCTFail("a cancelled request must not be retried")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  /// A dead agent must not cost every file call a spawn-and-handshake wait: after a failed
  /// acquisition, the FILE service fails fast for the cooldown (VCS reads and writes are unaffected —
  /// they never consult it).
  func testAFailedAcquisitionMakesFilesFailFastForTheCooldown() async throws {
    let attempts = Attempts()
    let agent = LocalAgentVCS(
      manager: HostConnectionManager(),
      resolveSocketPath: {
        attempts.count += 1
        return "/private/tmp/definitely-not-a-socket-\(UUID().uuidString)"
      },
      binaryURL: { nil })
    let root = try await RepositoryLocation.local(NSTemporaryDirectory())
    let context = FileContext(location: root, sharedLocation: nil)

    do {
      _ = try await agent.files(context: context)
      XCTFail("no agent can be reached")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(.local)) }
    XCTAssertEqual(attempts.count, 1)

    let started = Date()
    do {
      _ = try await agent.files(context: context)
      XCTFail("still no agent")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(.local)) }
    XCTAssertEqual(attempts.count, 1, "inside the cooldown nothing is attempted")
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
  }

  private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
      get { lock.withLock { value } }
      set { lock.withLock { value = newValue } }
    }
  }
}
