import Foundation
import XCTest

@testable import Workroom

/// Pure-rule tests for the New Project dialog (issue #103): path normalization,
/// the enable-until-valid gate, the per-mode footer, and the `add-project` JSON
/// decode. No SwiftUI rendering — the logic lives in `AddProjectSheetModel`.
final class AddProjectSheetModelTests: XCTestCase {

  func testNormalizeTrimsWhitespace() {
    XCTAssertEqual(AddProjectSheetModel.normalize("  /abs/path  "), "/abs/path")
    XCTAssertEqual(AddProjectSheetModel.normalize("\t/x\n"), "/x")
  }

  func testNormalizeExpandsLeadingTilde() {
    let home = NSHomeDirectory()
    XCTAssertEqual(AddProjectSheetModel.normalize("~"), home)
    XCTAssertEqual(AddProjectSheetModel.normalize("~/code/x"), "\(home)/code/x")
  }

  func testNormalizeLeavesOtherFormsUntouched() {
    // Only ~ and ~/ are expanded — matching the CLI's CanonicalPath.
    XCTAssertEqual(AddProjectSheetModel.normalize("relative/x"), "relative/x")
    XCTAssertTrue(AddProjectSheetModel.normalize("~someuser/x").hasPrefix("~someuser"))
  }

  func testIsValidRejectsEmptyAndRelative() {
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .createNew, path: ""))
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .createNew, path: "   "))
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .existing, path: "relative/path"))
  }

  func testIsValidAcceptsAbsoluteAndTilde() {
    XCTAssertTrue(AddProjectSheetModel.isValid(mode: .existing, path: "/abs/path"))
    XCTAssertTrue(AddProjectSheetModel.isValid(mode: .createNew, path: "/abs/new"))
    XCTAssertTrue(AddProjectSheetModel.isValid(mode: .createNew, path: "~/brand-new-project-xyz"))
  }

  func testIsValidCreateModeRejectsExistingFile() {
    let f = NSTemporaryDirectory() + "addproj-file-\(UUID().uuidString)"
    XCTAssertTrue(FileManager.default.createFile(atPath: f, contents: Data("x".utf8)))
    defer { try? FileManager.default.removeItem(atPath: f) }

    // Create mode fails fast on a path that exists as a regular file...
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .createNew, path: f))
    // ...but existing mode doesn't pre-check file-ness (the CLI's Detect handles it).
    XCTAssertTrue(AddProjectSheetModel.isValid(mode: .existing, path: f))
  }

  func testIsValidCreateModeAcceptsExistingDirectory() {
    let dir = NSTemporaryDirectory() + "addproj-dir-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    XCTAssertTrue(AddProjectSheetModel.isValid(mode: .createNew, path: dir))
  }

  func testRemotePathFooterSaysRemoteProjectsAreUnsupported() {
    for path in ["git@github.com:a/b.git", "ssh://host/repo", "host:repo"] {
      XCTAssertTrue(AddProjectSheetModel.isRemote(path), path)
      XCTAssertTrue(
        AddProjectSheetModel.footer(mode: .existing, path: path)
          .contains("Remote projects aren't supported"), path)
    }
    for path in ["/abs/with:colon", "~/code/repo", "", ":x"] {
      XCTAssertFalse(AddProjectSheetModel.isRemote(path), path)
    }
  }

  func testFooterDiffersByMode() {
    XCTAssertNotEqual(
      AddProjectSheetModel.footer(mode: .existing),
      AddProjectSheetModel.footer(mode: .createNew))
  }

  /// codex C10: the FakeWorkroomCLI seam can't prove the real decode, so assert
  /// AddProjectResponse parses the actual success-envelope shape, ignoring the
  /// envelope-header keys.
  func testAddProjectResponseDecodesFromEnvelope() throws {
    let json = Data(
      """
      {"ok":true,"schema_version":1,"cli_version":"dev","command":"add-project",\
      "path":"/abs/proj","vcs":"git"}
      """.utf8)
    let resp = try JSONDecoder().decode(AddProjectResponse.self, from: json)
    XCTAssertEqual(resp.path, "/abs/proj")
    XCTAssertEqual(resp.vcs, "git")
  }
}
