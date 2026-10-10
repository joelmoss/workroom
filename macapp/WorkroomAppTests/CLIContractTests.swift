import Foundation
import XCTest

@testable import Workroom

/// Decodes the CLI's `--json` contract goldens (`testdata/contracts`) with the app's own types.
/// `cmd/contract_test.go` checks the CLI still prints each file byte for byte, so a change on
/// either side that the other cannot read fails one of the two tests.
final class CLIContractTests: XCTestCase {
  /// The repository's `testdata/contracts`, found from this file's own source location.
  private static let contracts = URL(fileURLWithPath: String(describing: #filePath))
    .deletingLastPathComponent()  // WorkroomAppTests
    .deletingLastPathComponent()  // macapp
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("testdata/contracts")

  private func golden(_ name: String) throws -> Data {
    let url = Self.contracts.appendingPathComponent(name)
    return try XCTUnwrap(FileManager.default.contents(atPath: url.path), "missing \(url.path)")
  }

  private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: golden(name))
  }

  private func assertSuccess(_ name: String, file: StaticString = #filePath, line: UInt = #line)
    throws
  {
    let envelope = try decode(Envelope.self, name)
    XCTAssertTrue(envelope.ok, name, file: file, line: line)
    XCTAssertEqual(envelope.schemaVersion, 1, name, file: file, line: line)
    XCTAssertNil(envelope.error, name, file: file, line: line)
  }

  private func assertError(
    _ name: String, kind: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let envelope = try decode(Envelope.self, name)
    XCTAssertFalse(envelope.ok, name, file: file, line: line)
    XCTAssertEqual(envelope.schemaVersion, 1, name, file: file, line: line)
    XCTAssertEqual(envelope.error?.kind, kind, name, file: file, line: line)
    XCTAssertFalse(envelope.error?.message.isEmpty ?? true, name, file: file, line: line)
  }

  func testList() throws {
    try assertSuccess("list.json")
    let list = try decode(ListResponse.self, "list.json")
    XCTAssertEqual(list.workroomsDir, "/Users/dev/workrooms")
    XCTAssertEqual(list.configPath, "/Users/dev/.config/workroom/config.json")
    XCTAssertEqual(list.baseBranch, "main")
    XCTAssertEqual(list.projects.map(\.path), ["/Users/dev/src/app", "/Users/dev/src/empty"])

    let app = list.projects[0]
    XCTAssertEqual(app.vcs, "git")
    XCTAssertEqual(app.baseBranch, "develop")
    XCTAssertNil(app.host)
    XCTAssertEqual(app.workrooms.map(\.name), ["gone", "missing", "ok", "remote", "stray"])
    let byName = Dictionary(uniqueKeysWithValues: app.workrooms.map { ($0.name, $0) })

    XCTAssertEqual(byName["gone"]?.host?.state, "destroyed")
    XCTAssertEqual(byName["gone"]?.warnings.map(\.kind), ["HostDestroyed"])

    let missing = try XCTUnwrap(byName["missing"])
    XCTAssertEqual(missing.vcsName, "workroom/missing")
    XCTAssertEqual(missing.warnings.map(\.kind), ["DirectoryMissing", "VCSWorkroomMissing"])
    XCTAssertEqual(missing.warnings[0].path, "/Users/dev/workrooms/missing")
    XCTAssertEqual(missing.warnings[1].vcs, "git")
    XCTAssertTrue(missing.hasBlockingWarning)
    XCTAssertFalse(missing.isRemote)

    XCTAssertEqual(byName["ok"]?.warnings, [])

    let remote = try XCTUnwrap(byName["remote"]?.host)
    XCTAssertTrue(try XCTUnwrap(byName["remote"]).isRemote)
    XCTAssertEqual(remote.state, "running")
    XCTAssertEqual(remote.driver, "boxd")
    XCTAssertEqual(remote.id, UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    XCTAssertEqual(remote.workroomID, UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))
    XCTAssertEqual(remote.grantID, "grant-1")
    XCTAssertEqual(remote.repository, "acme/app")
    XCTAssertEqual(remote.cloneURL, "https://github.com/acme/app.git")

    XCTAssertEqual(byName["stray"]?.warnings.map(\.kind), ["VCSWorkroomMissing"])

    XCTAssertEqual(list.projects[1].workrooms, [])
    XCTAssertNil(list.projects[1].baseBranch)
  }

  func testCreate() throws {
    try assertSuccess("create.json")
    let created = try decode(CreateResponse.self, "create.json")
    XCTAssertEqual(created.name, "calm-river")
    XCTAssertEqual(created.path, "/Users/dev/workrooms/calm-river")
    XCTAssertEqual(created.vcs, "git")
    XCTAssertEqual(created.project, "/Users/dev/src/app")
    XCTAssertNil(created.warning)
  }

  func testCreateEvents() throws {
    let lines = String(decoding: try golden("create-events.ndjson"), as: UTF8.self)
      .split(separator: "\n")
    let events = try lines.map { try JSONDecoder().decode(StreamEvent.self, from: Data($0.utf8)) }
    XCTAssertEqual(events.map(\.type), ["created", "log", "log"])

    XCTAssertEqual(events[0].name, "calm-river")
    XCTAssertEqual(events[0].path, "/Users/dev/workrooms/calm-river")
    XCTAssertEqual(events[0].setup, true)
    XCTAssertEqual(events[0].warning, "")

    XCTAssertEqual(events[1].phase, "setup")
    XCTAssertEqual(events.dropFirst().map(\.text), ["installing", "done"])
  }

  func testCreateSetupFailed() throws {
    try assertError("create-setup-failed.json", kind: "SetupScriptFailed")
  }

  func testAddProject() throws {
    try assertSuccess("add-project.json")
    let added = try decode(AddProjectResponse.self, "add-project.json")
    XCTAssertEqual(added.path, "/Users/dev/src/app")
    XCTAssertEqual(added.vcs, "git")
    try assertError("add-project-unsupported-vcs.json", kind: "UnsupportedVCS")
  }

  func testDelete() throws {
    try assertSuccess("delete.json")
  }

  func testDeleteProject() throws {
    for name in ["delete-project.json", "delete-project-with-workrooms.json"] {
      try assertSuccess(name)
      XCTAssertNil(try decode(DeleteProjectResponse.self, name).trashPaths, name)
    }
    try assertSuccess("delete-project-from-disk.json")
    XCTAssertEqual(
      try decode(DeleteProjectResponse.self, "delete-project-from-disk.json").trashPaths,
      ["/Users/dev/src/app", "/Users/dev/workrooms/calm-river"])
  }
}
