import XCTest

@testable import Workroom

/// Where the generated libghostty config lives (`GhosttyApp.themeConfigURL`).
///
/// It used to be one `Application Support/Workroom/ghostty.conf` for every build identity and every
/// test process, while `writeThemeConfig` → `loadConfig` is two steps: a process that wrote between
/// another's two steps handed that one its theme. These pin both halves of the fix — the bundle-id
/// scoping that separates Workroom, Workroom Nightly and Workroom Dev, and the per-process file that
/// separates the test processes a bundle id cannot tell apart.
@MainActor
final class GhosttyConfigLocationTests: XCTestCase {
  /// Stands in for `~/Library/Application Support`, so the bundle-scoped paths are written for real
  /// without touching the developer's own.
  private var root: URL!
  private var fileManager: FileManager!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-config-location-\(UUID().uuidString)", isDirectory: true)
    fileManager = ApplicationSupportRedirect(root: root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// The bug itself, through the production writer: two identities write in turn, and each must read
  /// back its own theme. The Application Support root starts empty, so this is also a first run —
  /// neither `<bundle id>/` directory exists yet, and the write has to create it.
  func testTwoIdentitiesDoNotShareTheGeneratedConfig() throws {
    let dev = GhosttyApp.defaultThemeConfigURL(
      bundleID: "com.developwithstyle.workroom.dev", fileManager: fileManager)
    let release = GhosttyApp.defaultThemeConfigURL(
      bundleID: "com.developwithstyle.workroom", fileManager: fileManager)

    GhosttyApp.writeThemeConfig(theme: "Nord", to: dev)
    GhosttyApp.writeThemeConfig(theme: "Dayfox", to: release)

    XCTAssertEqual(
      try theme(in: dev), "Nord", "the release build's write reached Workroom Dev's config")
    XCTAssertEqual(try theme(in: release), "Dayfox")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: legacySharedPath),
      "a write still lands in the old file every identity shared")
  }

  /// `writeThemeConfig(theme:to:)` re-sanitises rather than trusting its caller, because as a static
  /// entry point it no longer only has `activeThemeName` (already sanitised) upstream of it. That
  /// defence is what stops a name closing the quote and appending directives of its own, so it is
  /// exercised with a name that tries to — not only with the clean literals the other cases use.
  func testWriteSanitisesAThemeNameEvenWhenTheCallerDidNot() throws {
    let url = GhosttyApp.defaultThemeConfigURL(
      bundleID: "com.example.dev", fileManager: fileManager)
    XCTAssertTrue(
      GhosttyApp.writeThemeConfig(theme: "Evil\"\nminimum-contrast = 0\n\"Name", to: url))

    // The sanitiser FLATTENS rather than escaping — it strips `"`, newlines and path separators —
    // so the payload survives as text inside the quoted value. That is not the injection: what
    // would be is a second LINE, which is the only way libghostty reads a second directive. So the
    // assertion is on line structure, not on the substring (which is still there, harmlessly).
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    // The TOTAL count, not the count of `theme = ` lines: unsanitised, this payload still leaves
    // exactly one line starting `theme = ` (the fragment `theme = "Evil"`), so that assertion would
    // pass against a reverted sanitiser. The file's length does not — the two stripped newlines are
    // two extra lines.
    XCTAssertEqual(
      lines.count, 6, "the name broke out of its own directive and started another line")
    XCTAssertEqual(
      lines.first { $0.hasPrefix("minimum-contrast") }, "minimum-contrast = 3.0",
      "the injected `minimum-contrast = 0` became a directive and displaced the real contrast floor"
    )
    XCTAssertEqual(try theme(in: url), "Evilminimum-contrast = 0Name")
  }

  /// The write reports failure rather than swallowing it. `loadConfig` cannot tell —
  /// `ghostty_config_load_file` returns `void` — so this return value is the engine's only signal
  /// that it is about to finalize on libghostty's defaults instead of Workroom's config.
  func testWriteReportsFailureWhenTheDirectoryCannotBeCreated() throws {
    let blocked = GhosttyApp.defaultThemeConfigURL(bundleID: "blocked", fileManager: fileManager)
    let directory = blocked.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A plain file where the `<bundle id>/` directory has to go, so `createDirectory` must fail.
    try Data().write(to: directory)

    XCTAssertFalse(GhosttyApp.writeThemeConfig(theme: "Nord", to: blocked))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: blocked.path),
      "the conf cannot exist if its directory could not be created")
  }

  func testDefaultURLIsScopedByBundleID() {
    let id = "com.developwithstyle.workroom.nightly"
    let nightly = GhosttyApp.defaultThemeConfigURL(bundleID: id, fileManager: fileManager)
    XCTAssertEqual(nightly.path, root.appendingPathComponent("Workroom/\(id)/ghostty.conf").path)
  }

  /// Same rule as `UnrecognizedToolUsage.defaultURL`: a process with no bundle id must not land on
  /// the shipped app's file, nor back on the shared one.
  func testMissingBundleIDFallsBackToNeitherTheReleaseNorTheSharedFile() {
    let fallback = GhosttyApp.defaultThemeConfigURL(bundleID: nil, fileManager: fileManager)
    let release = GhosttyApp.defaultThemeConfigURL(
      bundleID: "com.developwithstyle.workroom", fileManager: fileManager)
    XCTAssertNotEqual(fallback.path, release.path)
    XCTAssertNotEqual(fallback.path, legacySharedPath)
  }

  /// `make app-test` spreads classes across parallel workers, each its own `Workroom Dev` host — one
  /// bundle id between them, so bundle scoping alone would put every worker, and the developer's own
  /// running Dev app, back on one file. The engine in this host must use a file of its own, and the
  /// instance writer must write to that file.
  func testThisTestHostUsesAConfigOfItsOwn() throws {
    let live = GhosttyApp.shared.themeConfigURL
    // A guard, not an assertion, and one that doesn't ask the function under test: if the redirect
    // broke, this test stops here instead of adding a write of its own to the developer's Dev
    // config (the engine's launch-time write would already have landed there).
    guard live.lastPathComponent.hasSuffix("-\(ProcessInfo.processInfo.processIdentifier).conf")
    else {
      return XCTFail(
        "\(live.path) is not named for this process, so parallel workers would share it")
    }
    XCTAssertEqual(
      live, GhosttyApp.themeConfigURLForCurrentEnvironment(fixturePath: nil, underTest: true))
    XCTAssertNotEqual(live, GhosttyApp.defaultThemeConfigURL())

    GhosttyApp.shared.writeThemeConfig(dark: false)
    XCTAssertEqual(try theme(in: live), ThemeService.activeThemeName(isDark: false))
  }

  /// A file the XCUITest runner names wins, because the runner reads it back; a launch with neither
  /// that nor a test signal — any ordinary launch of Workroom Dev — gets the bundle-scoped file.
  /// (Release compiles both redirects out, which no Debug-built test can see.)
  func testARunnerNamedFileWinsAndAShippedLaunchIsBundleScoped() {
    XCTAssertEqual(
      GhosttyApp.themeConfigURLForCurrentEnvironment(
        fixturePath: "/tmp/runner-chosen.conf", underTest: true
      ).path,
      "/tmp/runner-chosen.conf")
    XCTAssertEqual(
      GhosttyApp.themeConfigURLForCurrentEnvironment(fixturePath: nil, underTest: false),
      GhosttyApp.defaultThemeConfigURL())
  }

  private var legacySharedPath: String {
    root.appendingPathComponent("Workroom/ghostty.conf").path
  }

  /// The `theme = "…"` value a generated config names.
  private func theme(in url: URL) throws -> String? {
    let text = try String(contentsOf: url, encoding: .utf8)
    for line in text.split(separator: "\n") where line.hasPrefix("theme = ") {
      return line.dropFirst("theme = ".count).trimmingCharacters(
        in: CharacterSet(charactersIn: "\""))
    }
    return nil
  }
}

/// A `FileManager` whose Application Support is a directory the test owns. `defaultThemeConfigURL`
/// takes a `fileManager` for exactly this, as `SessionStore.defaultURL` does.
private final class ApplicationSupportRedirect: FileManager, @unchecked Sendable {
  private let root: URL

  init(root: URL) {
    self.root = root
    super.init()
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
  }
}
