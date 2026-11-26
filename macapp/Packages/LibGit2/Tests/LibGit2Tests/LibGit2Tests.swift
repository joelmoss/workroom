import Foundation
import XCTest
import libgit2

/// The vendored build: the release VENDOR.md names, the configuration vendor-libgit2.sh renders,
/// and the repository format the forked 1.9.0 snapshot could not open.
final class LibGit2Tests: XCTestCase {
  override class func setUp() {
    super.setUp()
    git_libgit2_init()
  }

  override class func tearDown() {
    git_libgit2_shutdown()
    super.tearDown()
  }

  /// The version libgit2 reports is the one VENDOR.md records, so a label that disagrees with the
  /// code (the fork's "1.9.2" was a 1.9.0 snapshot) fails here.
  func testReportsTheVersionVendorMDRecords() throws {
    let manifest = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("VENDOR.md")
    let text = try String(contentsOf: manifest, encoding: .utf8)
    let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("- Version:") })
    let recorded = line.split(separator: "`")[1]

    var major: Int32 = 0
    var minor: Int32 = 0
    var revision: Int32 = 0
    XCTAssertEqual(git_libgit2_version(&major, &minor, &revision), 0)
    XCTAssertEqual("v\(major).\(minor).\(revision)", String(recorded))
  }

  /// Threads and nanosecond mtimes on, and no network transport: fetch and push run the git CLI.
  func testBuildsWithThreadsAndNanosecondsAndNoNetworkTransport() {
    let features = git_libgit2_features()
    XCTAssertNotEqual(features & Int32(GIT_FEATURE_THREADS.rawValue), 0)
    XCTAssertNotEqual(features & Int32(GIT_FEATURE_NSEC.rawValue), 0)
    XCTAssertEqual(features & Int32(GIT_FEATURE_HTTPS.rawValue), 0)
    XCTAssertEqual(features & Int32(GIT_FEATURE_SSH.rawValue), 0)
  }

  /// git 2.48's `worktree.useRelativePaths` (or `worktree add --relative-paths`) sets
  /// `extensions.relativeWorktrees`. libgit2 before 1.9.4 refused to open such a repository at all,
  /// its main checkout and every worktree alike.
  func testOpensARepositoryWithRelativeWorktrees() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LibGit2Tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try git(["init", "-q", root.path])
    try git(["-C", root.path, "config", "core.repositoryformatversion", "1"])
    try git(["-C", root.path, "config", "extensions.relativeWorktrees", "true"])

    var repository: OpaquePointer?
    let result = git_repository_open(&repository, root.path)
    defer { git_repository_free(repository) }
    XCTAssertEqual(result, 0, String(cString: git_error_last().pointee.message))
  }

  /// Config keys are matched by regex through the system's regcomp_l (GIT_REGEX_REGCOMP_L), the
  /// one backend choice that differs from the fork's bundled PCRE: POSIX extended syntax works,
  /// and a pattern regcomp rejects is an error rather than a match-nothing.
  func testMatchesConfigKeysWithPOSIXExtendedRegexes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LibGit2Tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try git(["init", "-q", root.path])
    for (key, value) in [("alpha", "1"), ("beta2", "2"), ("gamma", "3")] {
      try git(["-C", root.path, "config", "regex.\(key)", value])
    }

    var repository: OpaquePointer?
    XCTAssertEqual(git_repository_open(&repository, root.path), 0)
    defer { git_repository_free(repository) }
    var config: OpaquePointer?
    XCTAssertEqual(git_repository_config(&config, repository), 0)
    defer { git_config_free(config) }

    XCTAssertEqual(
      try configNames(config, matching: "^regex\\.(alpha|gamma)$"), ["regex.alpha", "regex.gamma"])
    XCTAssertEqual(
      try configNames(config, matching: "^regex\\.[[:alpha:]]+[[:digit:]]$"), ["regex.beta2"])

    var iterator: UnsafeMutablePointer<git_config_iterator>?
    XCTAssertLessThan(git_config_iterator_glob_new(&iterator, config, "regex.(alpha"), 0)
    git_config_iterator_free(iterator)
  }

  private func configNames(_ config: OpaquePointer?, matching pattern: String) throws -> [String] {
    var iterator: UnsafeMutablePointer<git_config_iterator>?
    let created = git_config_iterator_glob_new(&iterator, config, pattern)
    XCTAssertEqual(created, 0, String(cString: git_error_last().pointee.message))
    defer { git_config_iterator_free(iterator) }
    var names: [String] = []
    var entry: UnsafeMutablePointer<git_config_entry>?
    while git_config_next(&entry, iterator) == 0, let entry {
      names.append(String(cString: entry.pointee.name))
    }
    return names.sorted()
  }

  /// git with the user's global and system config shut out, so the repository it makes is the
  /// same on every machine.
  private func git(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
  }
}
