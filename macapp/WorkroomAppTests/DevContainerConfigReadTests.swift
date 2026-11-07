import DevContainer
import WorkroomVCS
import XCTest

@testable import Workroom

/// Finding a repository's `devcontainer.json` (`DevContainerConfig.read`) through the app's native
/// file provider. Its parsing is tested with the DevContainer package (`DevContainerConfigTests`).
final class DevContainerConfigReadTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// `.devcontainer/devcontainer.json` first, then `.devcontainer.json`, as the spec looks; nil
  /// when the repository has neither.
  func testItReadsTheFileTheSpecFindsFirst() async throws {
    let files = try await provider()
    let none = try await DevContainerConfig.read(files)
    XCTAssertNil(none)

    try write(".devcontainer.json", #"{"forwardPorts": [1]}"#)
    let root = try await DevContainerConfig.read(files)
    XCTAssertEqual(root?.path, ".devcontainer.json")

    try write(".devcontainer/devcontainer.json", #"{"forwardPorts": [2]}"#)
    let folder = try await DevContainerConfig.read(files)
    XCTAssertEqual(folder?.path, ".devcontainer/devcontainer.json")
    XCTAssertEqual(
      try folder.map { try DevContainerConfig.parse($0.data).ports }, [.init(port: 2)])
  }

  /// A failure other than "no such file" is the read's failure, never "no dev container": the
  /// caller tries again later rather than settle on forwarding nothing.
  func testAFailedReadIsNotAMissingFile() async throws {
    try write(".devcontainer/devcontainer.json", String(repeating: " ", count: 300 * 1024))
    let files = try await provider()
    do {
      _ = try await DevContainerConfig.read(files)
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
