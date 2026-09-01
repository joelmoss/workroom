import CryptoKit
import XCTest

@testable import Workroom

/// The bundled libghostty runtime resources (`Resources/ghostty/terminfo` + `shell-integration`) are
/// a **coupled contract** with the engine's own Zig-side injection, and nothing at runtime validates
/// it: `GhosttyApp.resolveResources` only checks that the directory exists. When the pair drifts,
/// OSC 7 and OSC 133 degrade *silently* — no error, no log — taking ⌘-click path resolution, tab
/// titles and the busy indicator with them.
///
/// So `ghostty/CHECKSUMS` pins the bytes and this suite is the tripwire. It is the same shape as
/// `ThemeServiceTests.testBundledThemeChecksumsMatch`, for the same reason: a structural test cannot
/// see byte drift, because a drifted script still parses and still ships.
///
/// `themes/` is deliberately NOT covered here — it is ours, not upstream's, and carries its own
/// `themes/CHECKSUMS` with its own test.
final class GhosttyResourcesTests: XCTestCase {
  /// Read from `Bundle.main.resourceURL` rather than the source tree so this asserts on what
  /// actually ships — a resource dropped from the folder reference fails here, not silently at
  /// launch on a user's machine.
  private func resourceDir() throws -> String {
    try XCTUnwrap(
      Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
      "the app bundle must carry its ghostty resources — the terminal can't start without them")
  }

  /// Every shipped file under `terminfo/` and `shell-integration/`, as paths relative to the
  /// `ghostty/` directory. `.DS_Store` is excluded because Finder can mint one in a folder
  /// reference at any time and it is not a resource.
  ///
  /// **Symlinks are a hard failure, not a skip.** `FileManager.enumerator(atPath:)` does not descend
  /// into a symlinked directory, and `fileExists` resolves the link — so classifying one as "a
  /// directory, skip it" would hide every file underneath from BOTH directions of the membership
  /// assertion, and the manifest would silently stop pinning what it claims to pin. That is not
  /// hypothetical here: upstream ships `terminfo/67/ghostty` as a symlink, so a regeneration done by
  /// copying a Ghostty.app tree reintroduces one. Dereference on copy (`cp -RL`); don't relax this.
  private func trackedRelativePaths() throws -> Set<String> {
    let root = try resourceDir()
    var found: Set<String> = []
    for subtree in ["terminfo", "shell-integration"] {
      let base = root + "/" + subtree
      let walker = FileManager.default.enumerator(atPath: base)
      while let entry = walker?.nextObject() as? String {
        let full = base + "/" + entry
        guard (entry as NSString).lastPathComponent != ".DS_Store" else { continue }

        // lstat, so a link is seen as a link rather than as whatever it points at.
        let type =
          try FileManager.default.attributesOfItem(atPath: full)[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
          XCTFail(
            "\(subtree)/\(entry) is a symlink — checksums can't pin it and a symlinked directory "
              + "would hide its contents from the manifest. Re-vendor with `cp -RL`.")
          continue
        }
        guard type == .typeRegular else { continue }
        found.insert(subtree + "/" + entry)
      }
    }
    return found
  }

  /// The shipped bytes are the vetted bytes, for both the terminfo entries and every shell script.
  ///
  /// Membership is asserted in *both* directions on purpose. A checksum-only test passes when a file
  /// is deleted from the bundle, and a listing-only test passes when a file's contents change —
  /// which is precisely the drift this exists to catch.
  func testBundledResourceChecksumsMatch() throws {
    let dir = try resourceDir()
    let manifest = try XCTUnwrap(
      try? String(contentsOfFile: dir + "/CHECKSUMS", encoding: .utf8),
      "ghostty/CHECKSUMS must ship — it is what makes the vendored ref verifiable")

    // Every non-blank line must parse, and every path must appear once. Skipping malformed lines
    // and last-write-wins on duplicates would both let a bad manifest pass: a merge artifact
    // carrying an obsolete AND a current checksum for one path would satisfy this test while
    // `shasum -c` rejected the file.
    var expected: [String: String] = [:]
    for line in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
      let raw = String(line)
      guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      // `shasum -a 256` format: "<64 hex>  <path>" (two spaces; a path may itself contain spaces).
      let parts = raw.components(separatedBy: "  ")
      guard parts.count >= 2, parts[0].count == 64,
        parts[0].allSatisfy({ $0.isHexDigit })
      else {
        XCTFail("CHECKSUMS has a malformed line: \(raw)")
        continue
      }
      let path = parts.dropFirst().joined(separator: "  ")
      if expected[path] != nil {
        XCTFail("CHECKSUMS lists \(path) more than once — likely a merge artifact")
      }
      expected[path] = parts[0].lowercased()
    }
    XCTAssertFalse(expected.isEmpty, "CHECKSUMS parsed to nothing — wrong format?")

    XCTAssertEqual(
      Set(expected.keys), try trackedRelativePaths(),
      "CHECKSUMS and the shipped terminfo / shell-integration files disagree on membership")

    for (path, want) in expected {
      guard let data = FileManager.default.contents(atPath: dir + "/" + path) else {
        XCTFail("\(path): listed in CHECKSUMS but unreadable")
        continue
      }
      XCTAssertEqual(
        Self.sha256Hex(data), want,
        "\(path): contents differ from the vendored ghostty ref recorded in ghostty/SOURCE.md")
    }
  }

  /// Nothing unexpected rides along inside the folder reference.
  ///
  /// `Resources/ghostty` is a **folder reference** in `project.yml`, so the whole directory is copied
  /// into the bundle verbatim and code-signing seals whatever is in it. Xcode's copy skips
  /// `.DS_Store`/`.git`/`.svn`/`.hg` and nothing else. That is a real hole rather than a theoretical
  /// one: agent-harness `.claude/.cc-writes` directories were found shipping inside the built app,
  /// and because they match a *global* gitignore they never appeared in `git status` — so neither
  /// the manifest (scoped to two subtrees) nor code review could see them.
  func testNoUnexpectedTopLevelResources() throws {
    let dir = try resourceDir()
    let allowed: Set<String> = [
      "terminfo", "shell-integration", "themes", "SOURCE.md", "CHECKSUMS",
    ]
    let present = Set(
      try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0 != ".DS_Store" })
    XCTAssertEqual(
      present.subtracting(allowed), [],
      "unexpected entries in the ghostty folder reference — they ship inside the signed bundle")
  }

  /// `themes/` must stay out of this manifest. It is ours, it changes on its own schedule, and it
  /// already has `themes/CHECKSUMS`. Folding it in here would make a theme refresh look like engine
  /// drift and vice versa — the two signals have to stay separable.
  func testChecksumsExcludesThemes() throws {
    let manifest = try XCTUnwrap(
      try? String(contentsOfFile: try resourceDir() + "/CHECKSUMS", encoding: .utf8))
    XCTAssertFalse(
      manifest.contains("themes/"),
      "themes/ is tracked by themes/CHECKSUMS — keep the two manifests disjoint")
  }

  /// Both terminfo entries are the same compiled record under two names. Upstream ships the
  /// `ghostty` alias as a symlink; we ship a byte copy (see `ghostty/SOURCE.md`), so the two files
  /// can drift apart in our tree in a way they cannot in upstream's. Asserted so a regeneration that
  /// updates one and forgets the other is a test failure rather than a `TERM=ghostty` session
  /// quietly running on a stale entry.
  func testTerminfoAliasMatchesPrimaryEntry() throws {
    let dir = try resourceDir()
    let primary = FileManager.default.contents(atPath: dir + "/terminfo/78/xterm-ghostty")
    let alias = FileManager.default.contents(atPath: dir + "/terminfo/67/ghostty")
    XCTAssertNotNil(primary, "terminfo/78/xterm-ghostty must ship — line editing breaks without it")
    XCTAssertEqual(primary, alias, "the `ghostty` alias entry has drifted from `xterm-ghostty`")
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// `Package.resolved` pins `libghostty-spm` to an exact revision, but that pin protects only the
/// *bump that set it* — nothing re-checks it afterwards. This packager has re-cut an already
/// published tag before (arm64e slices shipped under `1.2.4` on 2026-07-21, reverted 3 days later
/// under the same tag), so a moved tag would silently vendor a different engine than whatever was
/// last reviewed, with no signal beyond "the version number still says the same thing."
///
/// So this is a permanent tripwire, not a one-time check: it is *expected* to fail on the next pin
/// bump, and that failure is the point — it forces whoever does that bump to notice and deliberately
/// update `expectedRevision`, rather than the pin silently drifting under an unchanged version string.
final class GhosttyPinIntegrityTests: XCTestCase {
  /// The exact commit `macapp/project.yml`'s `libghostty` pin (version 1.3.2) resolved to when this
  /// bump was researched and landed. Update this alongside `project.yml`'s `exactVersion` on every
  /// future bump — see "Bump the libghostty pin" in `TODOS.md`.
  private static let expectedRevision = "817666339c968dbe0bf90205cdc10806de2cdf31"

  /// `Package.resolved` lives next to the (gitignored) `.xcodeproj`, not under `Resources` — it isn't
  /// a bundled resource, so this walks up from the test file's own source location instead of going
  /// through `Bundle.main`.
  private func packageResolvedURL() throws -> URL {
    let testFile = URL(fileURLWithPath: String(describing: #filePath))
    let macappDir = testFile.deletingLastPathComponent().deletingLastPathComponent()
    return
      macappDir
      .appendingPathComponent("WorkroomApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm")
      .appendingPathComponent("Package.resolved")
  }

  func testLibghosttyPinMatchesReviewedRevision() throws {
    let url = try packageResolvedURL()
    let data = try XCTUnwrap(
      FileManager.default.contents(atPath: url.path),
      "Package.resolved must exist at \(url.path) — run `make app-generate` first")
    let root =
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let pins = try XCTUnwrap(root?["pins"] as? [[String: Any]], "Package.resolved has no `pins`")
    let libghostty = try XCTUnwrap(
      pins.first { $0["identity"] as? String == "libghostty-spm" },
      "Package.resolved has no `libghostty-spm` pin")
    let state = try XCTUnwrap(libghostty["state"] as? [String: Any])
    let revision = try XCTUnwrap(state["revision"] as? String)

    XCTAssertEqual(
      revision, Self.expectedRevision,
      "libghostty-spm resolved to a different commit than the one this bump was reviewed against — "
        + "either the packager moved the tag, or `project.yml`'s pin changed without updating "
        + "`expectedRevision` here. Verify what actually changed before updating this constant.")
  }
}
