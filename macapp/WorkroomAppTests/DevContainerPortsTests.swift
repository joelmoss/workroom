import WorkroomVCS
import XCTest

@testable import Workroom

/// The port fields of a `devcontainer.json` (`DevContainerPorts`), which a container workroom
/// forwards to this Mac.
final class DevContainerPortsTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// The spec's file is JSON with comments: comments and trailing commas read, a `"host:port"`
  /// entry (another host's port, which the agent can't reach) is skipped, a repeat is forwarded
  /// once, and `portsAttributes` gives a single port's label and `requireLocalPort`.
  func testItReadsTheSpecsPortFields() throws {
    let file = """
      // Format details: https://aka.ms/devcontainer.json
      {
        "name": "app",
        "image": "mcr.microsoft.com/devcontainers/base", /* ignored */
        "forwardPorts": [3000, "db:5432", 5173, 3000,],
        "portsAttributes": {
          "3000": { "label": "Web", "requireLocalPort": true, "onAutoForward": "openBrowser" },
          "9000-9010": { "label": "Range" },
        },
      }
      """
    XCTAssertEqual(
      try DevContainerPorts.parse(Data(file.utf8)),
      [.init(port: 3000, label: "Web", requireLocalPort: true), .init(port: 5173)])
  }

  /// Nothing to forward is an empty list, not an error: a dev container that declares no ports, and
  /// numbers no port can be.
  func testNoPortsOrInvalidOnesForwardNothing() throws {
    XCTAssertEqual(try DevContainerPorts.parse(Data(#"{"image": "x"}"#.utf8)), [])
    XCTAssertEqual(
      try DevContainerPorts.parse(Data(#"{"forwardPorts": [0, -1, 70000, 8080.5, true]}"#.utf8)),
      [])
  }

  func testAFileThatIsNotJSONIsAnError() {
    XCTAssertThrowsError(try DevContainerPorts.parse(Data("forwardPorts: [3000]".utf8)))
    XCTAssertThrowsError(try DevContainerPorts.parse(Data(#"{"forwardPorts": 3000}"#.utf8)))
  }

  /// `.devcontainer/devcontainer.json` first, then `.devcontainer.json`, as the spec looks; nil
  /// when the repository has neither.
  func testItReadsTheFileTheSpecFindsFirst() async throws {
    let files = try await provider()
    let none = try await DevContainerPorts.read(files)
    XCTAssertNil(none)

    try write(".devcontainer.json", #"{"forwardPorts": [1]}"#)
    let root = try await DevContainerPorts.read(files)
    XCTAssertEqual(root?.path, ".devcontainer.json")

    try write(".devcontainer/devcontainer.json", #"{"forwardPorts": [2]}"#)
    let folder = try await DevContainerPorts.read(files)
    XCTAssertEqual(folder?.path, ".devcontainer/devcontainer.json")
    XCTAssertEqual(try folder.map { try DevContainerPorts.parse($0.data) }, [.init(port: 2)])
  }

  /// A failure other than "no such file" is the read's failure, never "no dev container": the
  /// caller tries again later rather than settle on forwarding nothing.
  func testAFailedReadIsNotAMissingFile() async throws {
    try write(".devcontainer/devcontainer.json", String(repeating: " ", count: 300 * 1024))
    let files = try await provider()
    do {
      _ = try await DevContainerPorts.read(files)
      XCTFail("an oversized file read as none")
    } catch FileServiceError.tooLarge {}
  }

  private func provider() async throws -> FileProviding {
    let location = try await RepositoryLocation.local(root.path)
    return NativeFileProvider(context: FileContext(location: location, sharedLocation: nil))
  }

  private func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
}
