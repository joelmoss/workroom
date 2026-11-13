import Foundation
import WorkroomDomain
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

  // MARK: Clone a repository… (issue #620)

  func testCloneURLAcceptsWhatGitCallsRemote() {
    for url in [
      "https://github.com/acme/api", "ssh://git@host/acme/api.git", "git://host/acme/api",
      "git@github.com:acme/api.git", "  https://github.com/acme/api  ",
    ] {
      XCTAssertTrue(AddProjectSheetModel.isCloneURL(url), url)
    }
    for url in ["", "/abs/repo", "~/code/repo", "acme/api", "file:///tmp/repo.git", "relative"] {
      XCTAssertFalse(AddProjectSheetModel.isCloneURL(url), url)
    }
  }

  func testRepoNameComesFromTheURLsLastComponent() {
    XCTAssertEqual(AddProjectSheetModel.repoName(fromURL: "git@github.com:acme/api.git"), "api")
    XCTAssertEqual(AddProjectSheetModel.repoName(fromURL: "https://github.com/acme/api"), "api")
    XCTAssertEqual(AddProjectSheetModel.repoName(fromURL: "https://github.com/acme/api/"), "api")
    XCTAssertEqual(
      AddProjectSheetModel.repoName(fromURL: "https://github.com/acme/api.git/"), "api")
    XCTAssertEqual(AddProjectSheetModel.repoName(fromURL: "host:repo"), "repo")
    XCTAssertNil(AddProjectSheetModel.repoName(fromURL: ""))
    XCTAssertNil(AddProjectSheetModel.repoName(fromURL: "https://"))
    XCTAssertNil(AddProjectSheetModel.repoName(fromURL: "https://github.com/"), "a host alone")
  }

  func testCloneDestinationIsTheRepoNameUnderTheParent() {
    XCTAssertEqual(
      AddProjectSheetModel.cloneDestination(
        url: "git@github.com:acme/api.git", parent: "/Users/me/dev"),
      "/Users/me/dev/api")
    XCTAssertEqual(
      AddProjectSheetModel.cloneDestination(
        url: "https://github.com/acme/api", parent: "/Users/me/dev/"),
      "/Users/me/dev/api")
    XCTAssertNil(AddProjectSheetModel.cloneDestination(url: "", parent: "/Users/me/dev"))
  }

  /// "Clone into" follows the URL until the user types their own path, then stays theirs.
  func testCloneIntoFollowsTheURLUntilEdited() {
    let parent = "/Users/me/dev"
    func seed(_ current: String, _ last: String?, _ url: String) -> String? {
      AddProjectSheetModel.seededPath(
        mode: .clone, current: current, lastAutoFill: last, url: url, parent: parent)
    }
    XCTAssertEqual(
      seed("", nil, "git@github.com:acme/api.git"), "/Users/me/dev/api", "empty: filled")
    XCTAssertEqual(
      seed("/Users/me/dev/api", "/Users/me/dev/api", "git@github.com:acme/web.git"),
      "/Users/me/dev/web", "still ours: follows the URL")
    XCTAssertNil(
      seed("/Volumes/x/mine", "/Users/me/dev/api", "git@github.com:acme/web.git"),
      "typed by hand: left alone")
    XCTAssertEqual(
      seed("/Users/me/dev/api", "/Users/me/dev/api", ""), "", "URL cleared: our fill goes too")
    XCTAssertNil(seed("", nil, "https://"), "no repo name yet: nothing to fill")
  }

  /// The path field is shared by every mode: what one mode seeded is replaced by the next mode's
  /// seed, so Create's "parent/" never leaks into Clone or From existing path….
  func testModeSwitchReseedsOnlyWhatTheSheetWrote() {
    let parent = "/Users/me/dev"
    func seed(_ mode: AddProjectMode, _ current: String, _ last: String?, url: String = "")
      -> String?
    {
      AddProjectSheetModel.seededPath(
        mode: mode, current: current, lastAutoFill: last, url: url, parent: parent)
    }
    XCTAssertEqual(seed(.createNew, "", nil), "/Users/me/dev/")
    XCTAssertEqual(
      seed(.clone, "/Users/me/dev/", "/Users/me/dev/", url: "https://github.com/acme/api"),
      "/Users/me/dev/api", "Create's seed gives way to Clone's")
    XCTAssertEqual(seed(.existing, "/Users/me/dev/", "/Users/me/dev/"), "", "and to no seed at all")
    XCTAssertNil(seed(.existing, "", nil), "already empty")
    XCTAssertNil(seed(.clone, "/Users/me/repo", "/Users/me/dev/"), "a typed path survives")
    XCTAssertNil(seed(.createNew, "/Users/me/repo", nil), "a typed path survives")
  }

  func testDefaultProjectFolderIsHomeWhenUnset() {
    XCTAssertEqual(AddProjectSheetModel.projectFolder(setting: ""), NSHomeDirectory())
    XCTAssertEqual(AddProjectSheetModel.projectFolder(setting: "~/dev"), NSHomeDirectory() + "/dev")
    XCTAssertEqual(AddProjectSheetModel.projectFolder(setting: "/Volumes/code"), "/Volumes/code")
  }

  func testCloneIsValidOnlyForAURLAndANewOrEmptyFolder() throws {
    let url = "git@github.com:acme/api.git"
    let root = NSTemporaryDirectory() + "addproj-clone-\(UUID().uuidString)"
    let empty = root + "/empty"
    let junk = root + "/junk"
    let full = root + "/full"
    let file = root + "/file"
    for dir in [empty, junk, full] {
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(atPath: root) }
    XCTAssertTrue(FileManager.default.createFile(atPath: junk + "/.DS_Store", contents: nil))
    XCTAssertTrue(FileManager.default.createFile(atPath: full + "/README", contents: nil))
    XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: nil))

    XCTAssertTrue(AddProjectSheetModel.isValid(mode: .clone, path: root + "/new/api", url: url))
    XCTAssertTrue(AddProjectSheetModel.isValid(mode: .clone, path: empty, url: url))
    XCTAssertTrue(
      AddProjectSheetModel.isValid(mode: .clone, path: junk, url: url), ".DS_Store only")
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .clone, path: full, url: url))
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .clone, path: file, url: url))
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .clone, path: "relative/api", url: url))
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .clone, path: "", url: url))
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .clone, path: empty, url: ""))
    XCTAssertFalse(AddProjectSheetModel.isValid(mode: .clone, path: empty, url: "acme/api"))

    XCTAssertEqual(
      AddProjectSheetModel.footer(mode: .clone, path: full, url: url), "That folder isn't empty.")
    XCTAssertEqual(
      AddProjectSheetModel.footer(mode: .clone, path: file, url: url),
      "That's a file, not a folder.")
    XCTAssertEqual(
      AddProjectSheetModel.footer(mode: .clone, path: "relative/api", url: url),
      "Type the full path to clone into.")
    XCTAssertEqual(
      AddProjectSheetModel.footer(mode: .clone, path: "", url: url),
      "Type the full path to clone into.", "a URL but no folder says why Clone is off")
    XCTAssertTrue(
      AddProjectSheetModel.footer(mode: .clone, path: empty, url: "acme/api")
        .hasPrefix("Enter a repository URL"))
    XCTAssertEqual(
      AddProjectSheetModel.footer(mode: .clone, path: empty, url: url),
      AddProjectSheetModel.footer(mode: .clone))
  }

  /// The remote-projects message belongs to "From existing path…" only: in clone mode a URL is
  /// the point, and create mode names a new folder.
  func testRemoteFooterShowsOnlyForExistingPath() {
    let remote = "git@github.com:a/b.git"
    XCTAssertTrue(
      AddProjectSheetModel.footer(mode: .existing, path: remote).contains("Remote projects"))
    XCTAssertFalse(
      AddProjectSheetModel.footer(mode: .createNew, path: remote).contains("Remote projects"))
    XCTAssertFalse(
      AddProjectSheetModel.footer(mode: .clone, path: "/x/api", url: remote).contains(
        "Remote projects"))
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
