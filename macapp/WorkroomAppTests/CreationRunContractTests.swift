import Foundation
import WorkroomDomain
import XCTest

@testable import Workroom

/// Drives the app's `CreationRun` with the CLI's `--json` contract goldens (`testdata/contracts`).
/// It runs hosted because `CreationRun` is app state; the goldens' decoding is
/// `WorkroomDomainTests.CLIContractTests`, under `swift test`.
final class CreationRunContractTests: XCTestCase {
  private static let contracts = SharedFixture.repositoryRoot
    .appendingPathComponent("testdata/contracts")

  private func golden(_ name: String) throws -> Data {
    let url = Self.contracts.appendingPathComponent(name)
    return try XCTUnwrap(FileManager.default.contents(atPath: url.path), "missing \(url.path)")
  }

  private func events(_ name: String) throws -> [StreamEvent] {
    try String(decoding: golden(name), as: UTF8.self).split(separator: "\n").map {
      try JSONDecoder().decode(StreamEvent.self, from: Data($0.utf8))
    }
  }

  /// The app's own reading of a create's events (#483): the golden sequences drive a run to the
  /// states the CLI meant.
  /// Value: protects=WorkroomCLI step parsing as `CreationRun` applies it, against the CLI's real
  /// output; fails_when=a step state or a log's step is misread; no_claim=the hop to the main queue
  @MainActor
  func testAGoldenCreateDrivesARunToItsStates() throws {
    let run = CreationRun(
      project: Project(path: "/p", vcs: "git", workrooms: []), kind: nil, splitAnchor: nil,
      previousSelection: nil)
    for event in try events("create-fetch-warning-events.ndjson") { run.apply(event) }
    XCTAssertEqual(
      run.steps.map(\.state),
      [
        .warning(
          "Could not fetch origin. The workroom starts from HEAD, which may be out of date."),
        .done, .skipped(reason: "No setup script"),
      ])
    XCTAssertEqual(run.steps[0].log.first, "$ git fetch --prune origin")
    XCTAssertEqual(run.steps[1].log.count, 3)
  }
}
