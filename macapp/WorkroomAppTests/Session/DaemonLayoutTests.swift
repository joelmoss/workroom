import DaemonConnection
import XCTest

@testable import Workroom

/// `DaemonLayoutService` against a real `workroomd serve` (#255): the request and reply shapes are
/// written in Rust (`layout.rs`) and decoded by hand here, so only the two together prove they agree.
final class DaemonLayoutTests: XCTestCase {
  private func connect(screens: Bool) async throws -> (DaemonLayoutService, DaemonHarness) {
    let daemon = try DaemonHarness.start(screens: screens)
    addTeardownBlock { daemon.stop() }
    let connection = try await DaemonVCSConnection.connect(
      host: .local, socketPath: daemon.socketPath)
    addTeardownBlock { await connection.close() }
    return (try connection.layouts(), daemon)
  }

  func testAWorkroomsLayoutIsKeptBehindARevision() async throws {
    let (layouts, _) = try await connect(screens: true)
    let key = UUID().uuidString
    let isAvailable = try await layouts.isAvailable()
    XCTAssertTrue(isAvailable)
    let empty = try await layouts.get(key)
    XCTAssertEqual(empty, DaemonLayout(revision: 0, blob: nil))

    let first = try await layouts.put(key, expected: 0, blob: #"{"tabs":[]}"#)
    XCTAssertEqual(first, 1)
    let read = try await layouts.get(key)
    XCTAssertEqual(read, DaemonLayout(revision: 1, blob: #"{"tabs":[]}"#))

    do {
      _ = try await layouts.put(key, expected: 0, blob: "stale")
      XCTFail("a put naming a moved revision was accepted")
    } catch DaemonLayoutError.stale(let revision) {
      XCTAssertEqual(revision, 1)
    }
  }

  /// A layout bigger than one envelope (1 MiB) still arrives whole: Layout requests are chunked.
  func testALayoutLargerThanOneEnvelopeArrivesWhole() async throws {
    let (layouts, _) = try await connect(screens: true)
    let key = UUID().uuidString
    let blob = String(repeating: "x", count: 2 * 1024 * 1024)
    let revision = try await layouts.put(key, expected: 0, blob: blob)
    XCTAssertEqual(revision, 1)
    let read = try await layouts.get(key)
    XCTAssertEqual(read.blob?.count, blob.count)
  }

  /// A daemon with no screens directory, as on this Mac, keeps no layouts and says so, and a get
  /// is refused as unsupported: the app then keeps the workroom's layout in its own session.
  func testADaemonWithoutScreensKeepsNoLayouts() async throws {
    let (layouts, _) = try await connect(screens: false)
    let isAvailable = try await layouts.isAvailable()
    XCTAssertFalse(isAvailable)
    do {
      _ = try await layouts.get("wr")
      XCTFail("a daemon with no layouts answered a get")
    } catch DaemonLayoutError.unsupported {}
  }
}
