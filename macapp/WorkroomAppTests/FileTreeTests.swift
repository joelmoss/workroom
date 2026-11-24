import Synchronization
import SyntaxHighlighting
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// Unit tests for the pure, engine-free core of the Files inspector section (`FileTree.swift`,
/// `FileHighlightMapper`, and the `PlainFileViewer` read gating). Everything past these needs a live
/// repo / view and is covered by manual QA.
final class FileTreeTests: XCTestCase {

  // MARK: FileTreeBuilder.build

  func testBuildNestsAndSortsDirsBeforeFiles() {
    let roots = FileTreeBuilder.build(from: [
      "b/y.txt", "b/x.txt", "a.txt", "b/sub/z.txt",
    ])
    // Top level: directory "b" before file "a.txt".
    XCTAssertEqual(roots.map(\.name), ["b", "a.txt"])
    XCTAssertTrue(roots[0].isDirectory)
    XCTAssertNotNil(roots[0].children)  // directory has children
    XCTAssertFalse(roots[1].isDirectory)
    XCTAssertNil(roots[1].children)  // file leaf

    // Inside "b": directory "sub" first, then files alphabetically.
    XCTAssertEqual(roots[0].children?.map(\.name), ["sub", "x.txt", "y.txt"])
    let sub = roots[0].children?.first
    XCTAssertEqual(sub?.name, "sub")
    XCTAssertTrue(sub?.isDirectory == true)
    XCTAssertEqual(sub?.children?.map(\.path), ["b/sub/z.txt"])
    XCTAssertEqual(sub?.children?.first?.name, "z.txt")
  }

  func testBuildDedupesIntermediateDirectories() {
    let roots = FileTreeBuilder.build(from: ["src/a.swift", "src/b.swift"])
    XCTAssertEqual(roots.count, 1)
    XCTAssertEqual(roots.first?.name, "src")
    XCTAssertEqual(roots.first?.children?.map(\.name), ["a.swift", "b.swift"])
  }

  func testBuildSkipsEmptyAndDotComponentsAndLeadingDotSlash() {
    let roots = FileTreeBuilder.build(from: ["./a.txt", "", "b//c.txt"])
    XCTAssertEqual(roots.map(\.name), ["b", "a.txt"])
    XCTAssertEqual(roots.first { $0.name == "b" }?.children?.map(\.path), ["b/c.txt"])
  }

  func testBuildEmptyInput() {
    XCTAssertTrue(FileTreeBuilder.build(from: []).isEmpty)
  }

  // MARK: FileTreeBuilder.flatten

  func testFlattenRespectsExpansionAndDepth() {
    let roots = FileTreeBuilder.build(from: ["b/sub/z.txt", "b/x.txt", "a.txt"])

    let collapsed = FileTreeBuilder.flatten(roots, expanded: [])
    XCTAssertEqual(collapsed.map { "\($0.node.name)@\($0.depth)" }, ["b@0", "a.txt@0"])

    let bOpen = FileTreeBuilder.flatten(roots, expanded: ["b"])
    XCTAssertEqual(
      bOpen.map { "\($0.node.name)@\($0.depth)" }, ["b@0", "sub@1", "x.txt@1", "a.txt@0"])

    let allOpen = FileTreeBuilder.flatten(roots, expanded: ["b", "b/sub"])
    XCTAssertEqual(
      allOpen.map { "\($0.node.name)@\($0.depth)" },
      ["b@0", "sub@1", "z.txt@2", "x.txt@1", "a.txt@0"])
  }

  // MARK: FileListing

  func testListCommands() {
    XCTAssertEqual(FileListing.command.executable, "git")
    XCTAssertEqual(
      FileListing.command.args,
      ["-c", "core.fsmonitor=", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
  }

  func testGitParseSplitsOnNulAndPreservesSpaces() {
    let stdout = "a.txt\u{0}b c.txt\u{0}\u{0}sub/d.txt\u{0}"
    XCTAssertEqual(FileListing.parse(stdout), ["a.txt", "b c.txt", "sub/d.txt"])
  }

  private func registeredList(path: String, runner: StatusCommandRunning) async
    -> FileTreeModel.ListResult
  {
    do {
      // A real folder holding `.git`: listing refuses to run git anywhere else (#266).
      let base = NSTemporaryDirectory() + "list-\(UUID().uuidString)"
      addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }
      let real = base + path
      try makeGitCheckout(atPath: real)
      let location = try await RepositoryLocation.local(real)
      let shared = try await RepositoryLocation.local(real)
      let router = RepositoryRouter()
      try router.register(.init(location: location, sharedLocation: shared))
      return await FileTreeModel.list(location: location, runner: runner, router: router)
    } catch {
      XCTFail("\(error)")
      return .unavailable
    }
  }

  // MARK: FileTreeModel.list

  func testListPrefersGitWhenAvailable() async {
    let runner = StubRunner(byExecutable: [
      "git": CommandResult(stdout: "a.txt\u{0}b.txt\u{0}", stderr: "", exitCode: 0, timedOut: false)
    ])
    let result = await registeredList(path: "/repo", runner: runner)
    XCTAssertEqual(result, .listing(["a.txt", "b.txt"]))
  }

  func testListReturnsUnavailableWhenGitDoesNotRespond() async {
    let runner = StubRunner(byExecutable: [:])  // every command → not-found
    let result = await registeredList(path: "/repo", runner: runner)
    XCTAssertEqual(result, .unavailable)
  }

  /// A signalled probe is not evidence `path` stopped being a repo — it must read `.interrupted`,
  /// never silently fold into `.unavailable` (which the UI treats as "not a repo").
  func testListReturnsInterruptedWhenAToolIsSignalled() async {
    let runner = StubRunner(byExecutable: [
      "git": CommandResult(stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true)
    ])
    let result = await registeredList(path: "/repo", runner: runner)
    XCTAssertEqual(result, .interrupted)
  }

  // MARK: FileContentLoader.classify (read gating)

  func testClassifyEmpty() {
    XCTAssertEqual(FileContentLoader.classify(data: Data()), .empty)
  }

  func testClassifyTooLarge() {
    XCTAssertEqual(FileContentLoader.classify(data: Data(count: 100), byteCap: 10), .tooLarge)
  }

  func testClassifyBinaryFromNulByte() {
    XCTAssertEqual(FileContentLoader.classify(data: Data([0x41, 0x00, 0x42])), .binary)
  }

  func testClassifyBinaryFromInvalidUTF8() {
    // 0xFF/0xFE are not valid UTF-8 and contain no NUL → still binary (decode fails).
    XCTAssertEqual(FileContentLoader.classify(data: Data([0xFF, 0xFE, 0x41])), .binary)
  }

  func testClassifyText() {
    let data = Data("let x = 1\n".utf8)
    XCTAssertEqual(FileContentLoader.classify(data: data), .text("let x = 1\n"))
  }

  // MARK: FileContentLoader.splitLines

  func testSplitLinesDropsTrailingNewlinePhantom() {
    XCTAssertEqual(FileContentLoader.splitLines("a\nb\n"), ["a", "b"])
    XCTAssertEqual(FileContentLoader.splitLines("a\nb"), ["a", "b"])
    XCTAssertEqual(FileContentLoader.splitLines("a\n"), ["a"])
    XCTAssertEqual(FileContentLoader.splitLines(""), [""])
  }

  // MARK: FileHighlightMapper.nsAttributedString (the string CodeTextView actually renders)

  @MainActor func testNsAttributedStringPlainKeepsContentAndFont() {
    let tokens = ThemeService.shared.tokens
    let content = "let x = 1\nfoo"
    let s = FileHighlightMapper.nsAttributedString(
      content: content, spans: [], tokens: tokens, font: PlainFileViewer.font)
    XCTAssertEqual(s.string, content)
    XCTAssertEqual(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, PlainFileViewer.font)
    XCTAssertEqual(
      s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, tokens.nsFg)
  }

  @MainActor func testNsAttributedStringKeepsContentVerbatimIncludingTrailingNewline() {
    // Unlike the line-bucketed form, the whole-file string is kept verbatim — the trailing newline
    // is preserved (the NSTextView renders the raw file), and empty content yields an empty string.
    let tokens = ThemeService.shared.tokens
    let s = FileHighlightMapper.nsAttributedString(
      content: "a\n", spans: [], tokens: tokens, font: PlainFileViewer.font)
    XCTAssertEqual(s.string, "a\n")
    let empty = FileHighlightMapper.nsAttributedString(
      content: "", spans: [], tokens: tokens, font: PlainFileViewer.font)
    XCTAssertEqual(empty.string, "")
    XCTAssertEqual(empty.length, 0)
  }

  /// Spans are UTF-8 byte ranges; the string is UTF-16. Text before a span that is wider in
  /// bytes than in UTF-16 units (`é` is 2 bytes, 1 unit; the emoji 4 bytes, 2 units) must not
  /// shift where the colour lands.
  @MainActor func testNsAttributedStringMapsBytesToUTF16AcrossMultibyteText() {
    let tokens = ThemeService.shared.tokens
    let content = "é🙂 let x"  // `let` is bytes 7..<10 and UTF-16 units 4..<7
    let s = FileHighlightMapper.nsAttributedString(
      content: content, spans: [HighlightSpan(byteRange: 7..<10, capture: "keyword")],
      tokens: tokens, font: PlainFileViewer.font)
    let keyword = s.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
    XCTAssertNotEqual(keyword, tokens.nsFg, "`l` of `let` is recoloured")
    XCTAssertEqual(
      s.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor, keyword,
      "`t` of `let` too")
    XCTAssertEqual(
      s.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor, tokens.nsFg,
      "the space before it is not")
    XCTAssertEqual(
      s.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor, tokens.nsFg,
      "nor the space after")
  }

  /// `highlighted` parses and builds the string away from the main actor, and hands back nothing
  /// for content the grammar leaves plain, so the viewer keeps the string it already shows.
  @MainActor func testHighlightedRecolorsOrKeepsPlain() async {
    let tokens = ThemeService.shared.tokens
    let s = await FileHighlightMapper.highlighted(
      content: "let x = 1", grammar: .swift, tokens: tokens, font: PlainFileViewer.font)
    XCTAssertEqual(s?.string, "let x = 1")
    XCTAssertNotEqual(
      s?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, tokens.nsFg,
      "`let` is a keyword, recoloured away from the default")
    let plain = await FileHighlightMapper.highlighted(
      content: "   \n", grammar: .swift, tokens: tokens, font: PlainFileViewer.font)
    XCTAssertNil(plain, "no captures ⇒ nil, the caller keeps its plain string")
  }

  @MainActor func testNsAttributedStringRecolorsCapturedSpan() {
    let tokens = ThemeService.shared.tokens
    let content = "let x = 1"  // recolor bytes 0..<3 ("let") as a keyword
    let s = FileHighlightMapper.nsAttributedString(
      content: content, spans: [HighlightSpan(byteRange: 0..<3, capture: "keyword")],
      tokens: tokens, font: PlainFileViewer.font)
    XCTAssertEqual(s.string, content)
    let captured = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let plain = s.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
    XCTAssertEqual(plain, tokens.nsFg, "text outside a span stays the default foreground")
    XCTAssertNotEqual(captured, plain, "a keyword span should recolor away from the default")
  }

  // MARK: FileTree sort (case-insensitive, exact-name tie-break)

  func testBuildSortsCaseInsensitivelyWithExactTieBreak() {
    // Case-insensitive alphabetical (apple < File/file < Zebra), and a case-only tie
    // ("File.txt" vs "file.txt") breaks by raw `<` — uppercase 'F' sorts before lowercase 'f'.
    let roots = FileTreeBuilder.build(from: ["Zebra.txt", "apple.txt", "file.txt", "File.txt"])
    XCTAssertEqual(roots.map(\.name), ["apple.txt", "File.txt", "file.txt", "Zebra.txt"])
  }

  // MARK: FileContentLoader.classify (boundary cases)

  func testClassifyAtExactByteCapIsText() {
    // Only strictly over the cap is `.tooLarge`; exactly at the cap still loads.
    let data = Data("abcdefghij".utf8)  // 10 bytes
    XCTAssertEqual(FileContentLoader.classify(data: data, byteCap: 10), .text("abcdefghij"))
  }

  func testClassifyNulPastScanWindowIsText() {
    // The binary probe only scans the first 8 KB; a NUL past that window isn't detected, so an
    // otherwise-valid-UTF-8 file still classifies as text (documented, bounded-scan behaviour).
    var bytes = [UInt8](repeating: 0x41, count: 9000)  // 'A' × 9000, past the 8 KB scan
    bytes[8500] = 0x00
    guard case .text = FileContentLoader.classify(data: Data(bytes)) else {
      return XCTFail("a NUL past the 8 KB scan window must not trip the binary probe")
    }
  }

  /// Daemon lock contention or an I/O failure during a reload used to read as "unavailable", which
  /// blanked a valid tree. Neither says anything about the tree.
  func testAgentRefusalsAreTransientNotUnavailable() async throws {
    let dir = NSTemporaryDirectory() + "transient-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let busy = await FileTreeModel.listFailure(VCSError.lockContention, path: dir)
    XCTAssertEqual(busy, .transient("The repository is busy. Reload to try again."))
    let io = await FileTreeModel.listFailure(FileServiceError.failed("spawn failed"), path: dir)
    XCTAssertEqual(io, .transient("spawn failed"))
  }

  /// The daemon reports a vanished working directory as the same `Io` failure as a hiccup, so a
  /// folder that is gone must still blank the tree rather than keep showing its files.
  func testAnAgentIOFailureOnAVanishedFolderIsUnavailable() async {
    let gone = NSTemporaryDirectory() + "gone-\(UUID().uuidString)"
    let result = await FileTreeModel.listFailure(
      FileServiceError.failed("No such file"), path: gone)
    XCTAssertEqual(result, .unavailable)
    let busy = await FileTreeModel.listFailure(VCSError.lockContention, path: gone)
    XCTAssertEqual(busy, .unavailable, "a busy daemon does not make a deleted folder come back")
  }

  /// A remote workroom's path is on its host (#253): that this Mac has nothing there must not blank
  /// its tree on an error.
  func testAFailureOnARemotePathIsNotJudgedByThisMacsDisk() async {
    let nowhere = NSTemporaryDirectory() + "remote-\(UUID().uuidString)"
    let result = await FileTreeModel.listFailure(
      FileServiceError.failed("No such file"), path: nowhere, onThisMac: false)
    XCTAssertEqual(result, .transient("No such file"))
  }

  /// An unreadable parent makes existence unknowable, which is not the same as gone.
  func testAnUnreadableParentKeepsTheTree() async throws {
    let parent = NSTemporaryDirectory() + "locked-\(UUID().uuidString)"
    let dir = parent + "/repo"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
      try? FileManager.default.removeItem(atPath: parent)
    }
    let result = await FileTreeModel.listFailure(FileServiceError.failed("EACCES"), path: dir)
    XCTAssertEqual(result, .transient("EACCES"))
  }

  // MARK: timeouts vs external kills (#211)

  /// `timedOut` implies `signaled` (the timeout SIGTERMs the child), so a timeout used to read as an
  /// EXTERNAL kill: `.interrupted` leaves the tree alone, and on a first load that is a spinner that
  /// never ends. A timeout is an ordinary failure; only a signal without one is an interruption.
  func testATimedOutListingIsUnavailableNotInterrupted() async {
    let timedOut = CommandResult(
      stdout: "", stderr: "", exitCode: 143, timedOut: true, signaled: true)
    let result = await registeredList(
      path: "/timeout",
      runner: StubRunner(byExecutable: ["git": timedOut]))
    XCTAssertEqual(result, .unavailable)

    let killed = CommandResult(stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true)
    let interrupted = await registeredList(
      path: "/timeout",
      runner: StubRunner(byExecutable: ["git": killed]))
    XCTAssertEqual(
      interrupted, .interrupted, "an external kill is still not evidence of a non-repo")
  }

  // MARK: reload coalescing (#211)

  /// Through the daemon a cancelled listing keeps running on the host, so a burst of watch events must
  /// not each start one: one in flight, one follow-up, and the tree still ends on the last state.
  @MainActor
  func testABurstOfReloadsRunsOneListingAndOneFollowUp() async throws {
    let dir = NSTemporaryDirectory() + "reload-\(UUID().uuidString)"
    try makeGitCheckout(atPath: dir)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let runner = GatedRunner()
    let model = FileTreeModel(runner: runner)
    model.activate(location: try await RepositoryLocation.local(dir))
    defer { model.activate(location: nil) }

    try await waitUntil { runner.calls == 1 }
    for _ in 0..<10 { model.reload() }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(runner.calls, 1, "reloads during a listing must not start more listings")

    runner.release()  // the first listing finishes and the ONE follow-up starts
    try await waitUntil { runner.calls == 2 }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(runner.calls, 2, "ten reloads coalesce to a single follow-up")
    runner.release()
    try await waitUntil { model.state == .loaded }
    XCTAssertEqual(model.roots.map(\.name), ["a.txt"])
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition not reached")
  }
}

/// Holds every listing open until `release()`, and counts how many were started.
private final class GatedRunner: StatusCommandRunning, Sendable {
  private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
  private let started = Mutex(0)
  var calls: Int { started.withLock { $0 } }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    started.withLock { $0 += 1 }
    await withCheckedContinuation { continuation in
      waiters.withLock { $0.append(continuation) }
    }
    return CommandResult(stdout: "a.txt\0", stderr: "", exitCode: 0, timedOut: false)
  }

  func release() {
    let next = waiters.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    next?.resume()
  }
}

/// A canned `StatusCommandRunning` for the listing tests: returns a per-executable result,
/// or a command-not-found (127) for anything unlisted.
private struct StubRunner: StatusCommandRunning {
  let byExecutable: [String: CommandResult]

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    byExecutable[executable]
      ?? CommandResult(stdout: "", stderr: "", exitCode: 127, timedOut: false)
  }
}

/// The Files tree's cost on the main actor and on revisits (#812 perf lane P1: F1, F2, F4, F6).
@MainActor
final class FileTreeModelPerfTests: XCTestCase {
  private var scratch: String!

  override func setUp() async throws {
    scratch = NSTemporaryDirectory() + "files-perf-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(atPath: scratch)
  }

  private func checkout(_ name: String) throws -> String {
    let dir = scratch + "/" + name
    try makeGitCheckout(atPath: dir)
    return dir
  }

  private func waitUntil(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("condition not reached", file: file, line: line)
  }

  /// Value: protects=a re-list whose output is byte-identical costing nothing on the main actor
  /// (F1); fails_when=an identical listing rebuilds or republishes the tree; why_new=#812 perf;
  /// seam=FileTreeModel with a canned runner; no_claim=the daemon's listing
  func testAnIdenticalReListPublishesNothing() async throws {
    let dir = try checkout("same")
    let runner = ListingRunner(["same": "a.txt\0b/c.txt\0"])
    let model = FileTreeModel(runner: runner)
    model.activate(location: try await RepositoryLocation.local(dir))
    defer { model.activate(location: nil) }
    await waitUntil { model.state == .loaded && model.roots.count == 2 }

    var publishes = 0
    let sink = model.objectWillChange.sink { publishes += 1 }
    defer { sink.cancel() }
    model.reload()
    await waitUntil { runner.calls >= 2 }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(publishes, 0, "an identical listing must neither rebuild nor republish")

    runner.set("same", "a.txt\0b/c.txt\0d.txt\0")
    model.reload()
    await waitUntil { model.roots.count == 3 }
  }

  /// Value: measures how long a 50k-file listing holds the main actor (F1); fails_when=parse and
  /// build run on the main actor again; why_new=#812 perf; seam=FileTreeModel with a canned
  /// runner; no_claim=git's own time
  func testABigListingBarelyHoldsTheMainActor() async throws {
    let dir = try checkout("big")
    var paths: [String] = []
    for package in 0..<50 {
      for module in 0..<40 {
        for file in 0..<25 { paths.append("pkg\(package)/mod\(module)/src/file\(file).swift") }
      }
    }
    let runner = ListingRunner(["big": paths.joined(separator: "\0") + "\0"])
    let model = FileTreeModel(runner: runner)
    let location = try await RepositoryLocation.local(dir)

    var longest: Duration = .zero
    var done = false
    let clock = ContinuousClock()
    let ticker = Task { @MainActor in
      var last = clock.now
      while !done {
        try? await Task.sleep(for: .milliseconds(1))
        let now = clock.now
        longest = max(longest, now - last)
        last = now
      }
    }
    model.activate(location: location)
    defer { model.activate(location: nil) }
    await waitUntil({ model.state == .loaded && model.roots.count == 50 })
    done = true
    await ticker.value
    print("PERF F1 longest main-actor gap during a 50k-file listing: \(longest)")
    XCTAssertLessThan(longest, .milliseconds(100), "the build ran on the main actor")
  }

  /// Value: protects=a revisited repository showing its last tree at once (F2); fails_when=going
  /// back to a repository flashes the loader and waits for git; why_new=#812 perf;
  /// seam=FileTreeModel; no_claim=the panel's rendering
  func testARevisitedRepositoryShowsItsTreeAtOnceAndRefreshes() async throws {
    let a = try checkout("a")
    let b = try checkout("b")
    let runner = ListingRunner(["a": "a.txt\0", "b": "b.txt\0"])
    let model = FileTreeModel(runner: runner)
    defer { model.activate(path: nil) }

    model.activate(path: a)
    await waitUntil { model.roots.map(\.name) == ["a.txt"] }
    model.activate(path: b)
    await waitUntil { model.roots.map(\.name) == ["b.txt"] }

    runner.set("a", "a.txt\0new.txt\0")
    model.activate(path: a)
    XCTAssertEqual(model.state, .loaded, "no loader on a revisit")
    XCTAssertEqual(model.roots.map(\.name), ["a.txt"], "the cached tree, at once")
    await waitUntil { model.roots.map(\.name) == ["a.txt", "new.txt"] }
    XCTAssertEqual(runner.calls, 3)
  }

  /// Value: protects=a workroom's tree at the repository a followed subfolder was listed from
  /// re-rooting instead of re-listing (F2); fails_when=selecting the workroom re-lists the same
  /// repository; why_new=#812 perf; seam=FileTreeModel; no_claim=the store's subject
  func testTheSameRepositoryAtItsRootReRootsWithoutListing() async throws {
    let a = try checkout("a")
    let runner = ListingRunner(["a": "src/x.swift\0top.txt\0"])
    let model = FileTreeModel(runner: runner)
    defer { model.activate(path: nil) }

    model.activate(root: .repository(root: a, subfolder: "src"))
    await waitUntil { model.roots.map(\.name) == ["x.swift"] }
    // Settle the fixture's own writes: a re-list clears any staleness they left.
    try await Task.sleep(for: .milliseconds(200))
    let settled = runner.calls
    model.reload()
    await waitUntil { runner.calls > settled }
    try await Task.sleep(for: .milliseconds(100))
    let listed = runner.calls
    model.activate(path: a)
    XCTAssertEqual(model.state, .loaded)
    XCTAssertEqual(model.roots.map(\.name), ["src", "top.txt"])
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(runner.calls, listed, "the same repository is not listed again")
  }

  /// Value: protects=Files doing no watch work while it isn't shown, and catching up once (F4);
  /// fails_when=a hidden tree keeps watching, or a re-show lists twice or not at all;
  /// why_new=#812 perf; seam=FileTreeModel's pause/resume; no_claim=FSEvents delivery
  func testAPausedTreeStopsWatchingAndReListsOnceWhenShown() async throws {
    let a = try checkout("a")
    let b = try checkout("b")
    let runner = ListingRunner(["a": "a.txt\0", "b": "b.txt\0"])
    let model = FileTreeModel(runner: runner)
    defer { model.activate(location: nil) }
    model.activate(location: try await RepositoryLocation.local(a))
    await waitUntil { model.state == .loaded && model.isWatching }
    try await Task.sleep(for: .milliseconds(200))

    model.pause()
    XCTAssertFalse(model.isWatching)
    let paused = runner.calls
    model.resume()
    await waitUntil { runner.calls == paused + 1 }
    XCTAssertTrue(model.isWatching)
    model.resume()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(runner.calls, paused + 1, "a resume with no pause lists nothing")

    // As `FilesPanel` does on its return: activate, then resume.
    model.pause()
    let switched = runner.calls
    model.activate(location: try await RepositoryLocation.local(b))
    model.resume()
    await waitUntil { model.roots.map(\.name) == ["b.txt"] && model.isWatching }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(
      runner.calls, switched + 1, "a fresh activation already listed, so the re-show doesn't")
  }

  /// Value: protects=a re-list leaving git's output alone still refreshing a followed folder read
  /// from disk (an ignored `build`); fails_when=the identical-output skip leaves it stale or
  /// blank; why_new=#812 perf; seam=FileTreeModel with a canned runner; no_claim=FSEvents
  func testAnUnchangedListingStillReReadsAnIgnoredFolder() async throws {
    let a = try checkout("a")
    try FileManager.default.createDirectory(
      atPath: a + "/build", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: a + "/build/out.o", contents: Data())
    let runner = ListingRunner(["a": "src/x.swift\0"])
    let model = FileTreeModel(runner: runner)
    defer { model.activate(path: nil) }

    model.activate(root: .repository(root: a, subfolder: "build"))
    await waitUntil { model.roots.map(\.name) == ["out.o"] }
    FileManager.default.createFile(atPath: a + "/build/new.o", contents: Data())
    model.reload()
    await waitUntil { model.roots.map(\.name) == ["new.o", "out.o"] }
    XCTAssertEqual(model.state, .loaded)
  }

  /// Value: protects=the Files watch deciding off the main actor what a change means (F3);
  /// fails_when=a change outside what the tree shows re-lists the repository, or a change that
  /// alters what it shows is missed; why_new=#812 perf; seam=FileTreeModel.watchVerdict;
  /// no_claim=FSEvents
  func testTheWatchReListsOnlyForWhatTheTreeShows() {
    typealias Scope = FileTreeModel.WatchScope
    func verdict(_ path: String, _ scope: Scope, exists: Bool = true)
      -> FileTreeModel.WatchVerdict
    {
      FileTreeModel.watchVerdict([path], overflow: false, scope: scope, exists: { _ in exists })
    }
    let repo = Scope(
      root: "/w/r", plain: false, base: "", visible: [""], known: ["src", "src/deep"],
      home: "/Users/me")
    XCTAssertEqual(verdict("/w/r/README.md", repo), .reload, "an entry of a shown folder")
    XCTAssertEqual(verdict("/w/r/src/deep/a.swift", repo), .stale, "inside a collapsed folder")
    XCTAssertEqual(verdict("/w/r/src/deep/a.swift", repo, exists: false), .reload, "a removal")
    XCTAssertEqual(verdict("/w/r/new/b/f.swift", repo), .reload, "a folder git didn't list")
    XCTAssertEqual(verdict("/w/r/.git/index", repo), .ignore)
    XCTAssertEqual(verdict("/private/w/r/README.md", repo), .reload)
    XCTAssertEqual(
      FileTreeModel.watchVerdict([], overflow: true, scope: repo, exists: { _ in true }), .reload)

    let expanded = Scope(
      root: "/w/r", plain: false, base: "", visible: ["", "src", "src/deep"],
      known: ["src", "src/deep"], home: "/Users/me")
    XCTAssertEqual(verdict("/w/r/src/deep/a.swift", expanded), .reload)

    let followed = Scope(
      root: "/w/r", plain: false, base: "src", visible: ["src"], known: ["src", "src/deep"],
      home: "/Users/me")
    XCTAssertEqual(verdict("/w/r/top.txt", followed), .stale, "outside the followed folder")
    XCTAssertEqual(verdict("/w/r/src/a.swift", followed), .reload)

    let plain = Scope(
      root: "/Users/me", plain: true, base: "", visible: [""], known: [], home: "/Users/me")
    XCTAssertEqual(verdict("/Users/me/Library/Caches/x", plain), .ignore)
    XCTAssertEqual(verdict("/Users/me/.zsh_history", plain), .ignore)
    XCTAssertEqual(verdict("/Users/me/new.txt", plain), .reload)

    let dotfiles = Scope(
      root: "/Users/me", plain: false, base: "", visible: ["", "src"], known: ["src"],
      home: "/Users/me")
    XCTAssertEqual(verdict("/Users/me/Library/Caches/x", dotfiles), .ignore)
    XCTAssertEqual(verdict("/Users/me/src/a.swift", dotfiles), .reload)
  }

  /// Value: protects=a plain folder's reload reading only what is shown (F6); fails_when=a
  /// collapsed folder is still re-read on every change; why_new=#812 perf; seam=FileTreeModel's
  /// disk read; no_claim=FSEvents
  func testAPlainReloadReadsOnlyShownFolders() async throws {
    let plain = scratch + "/plain"
    for file in ["a/x.txt", "b/y.txt", "c.txt"] {
      try FileManager.default.createDirectory(
        atPath: ((plain + "/" + file) as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: plain + "/" + file, contents: Data())
    }
    let reads = Mutex<[[String]]>([])
    let model = FileTreeModel(readDirectories: { directories, root in
      reads.withLock { $0.append(directories) }
      return FileTreeModel.readPlain(directories, under: root)
    })
    defer { model.activate(path: nil) }
    model.activate(root: .folder(plain))
    await waitUntil { model.roots.count == 3 }
    for name in ["a", "b"] {
      model.toggle(try XCTUnwrap(model.roots.first { $0.name == name }))
      await waitUntil { model.roots.first { $0.name == name }?.children?.isEmpty == false }
    }
    model.toggle(try XCTUnwrap(model.roots.first { $0.name == "a" }))
    try await Task.sleep(for: .milliseconds(100))

    reads.withLock { $0 = [] }
    model.reload()
    await waitUntil { reads.withLock { $0.count } == 1 }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(reads.withLock { $0 }, [["", "b"]], "the collapsed folder is not re-read")
  }

  /// Value: protects=a burst of plain-folder reloads coalescing into one more read (F6);
  /// fails_when=each reload queues its own full re-read; why_new=#812 perf; seam=FileTreeModel's
  /// disk read; no_claim=FSEvents
  func testABurstOfPlainReloadsRunsOneMoreRead() async throws {
    let plain = scratch + "/burst"
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: plain + "/notes.txt", contents: Data())
    let reads = Mutex(0)
    let gate = DispatchSemaphore(value: 0)
    let model = FileTreeModel(readDirectories: { directories, root in
      let count = reads.withLock {
        $0 += 1
        return $0
      }
      if count == 2 { _ = gate.wait(timeout: .now() + 2) }
      return FileTreeModel.readPlain(directories, under: root)
    })
    defer { model.activate(path: nil) }
    model.activate(root: .folder(plain))
    await waitUntil { model.state == .loaded }

    model.reload()
    await waitUntil { reads.withLock { $0 } == 2 }
    for _ in 0..<5 { model.reload() }
    gate.signal()
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(reads.withLock { $0 }, 3, "five reloads during a read coalesce into one")
  }
}

/// Canned listings by the listed folder's name, counting runs.
private final class ListingRunner: StatusCommandRunning, Sendable {
  private let outputs: Mutex<[String: String]>
  private let started = Mutex(0)
  var calls: Int { started.withLock { $0 } }

  init(_ outputs: [String: String]) { self.outputs = Mutex(outputs) }

  func set(_ name: String, _ output: String) { outputs.withLock { $0[name] = output } }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    started.withLock { $0 += 1 }
    let output = outputs.withLock { $0[(directory as NSString).lastPathComponent] } ?? ""
    return CommandResult(stdout: output, stderr: "", exitCode: 0, timedOut: false)
  }
}
