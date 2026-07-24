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
    XCTAssertEqual(FileListing.command(.git).executable, "git")
    XCTAssertEqual(
      FileListing.command(.git).args,
      ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    XCTAssertEqual(FileListing.command(.jj).executable, "jj")
    XCTAssertEqual(FileListing.command(.jj).args, ["file", "list"])
  }

  func testGitParseSplitsOnNulAndPreservesSpaces() {
    let stdout = "a.txt\u{0}b c.txt\u{0}\u{0}sub/d.txt\u{0}"
    XCTAssertEqual(FileListing.parse(stdout, vcs: .git), ["a.txt", "b c.txt", "sub/d.txt"])
  }

  func testJJParseSplitsOnNewlineTrimsCRAndStripsDotSlash() {
    XCTAssertEqual(
      FileListing.parse("a.txt\n./sub/d.txt\n\n", vcs: .jj), ["a.txt", "sub/d.txt"])
    XCTAssertEqual(FileListing.parse("x.txt\r\n", vcs: .jj), ["x.txt"])
  }

  // MARK: FileTreeModel.list (git → jj fallthrough)

  func testListPrefersGitWhenAvailable() async {
    let runner = StubRunner(byExecutable: [
      "git": CommandResult(stdout: "a.txt\u{0}b.txt\u{0}", stderr: "", exitCode: 0, timedOut: false)
    ])
    let paths = await FileTreeModel.list(path: "/repo", projectRoot: nil, runner: runner)
    XCTAssertEqual(paths, ["a.txt", "b.txt"])
  }

  func testListFallsThroughToJJWhenGitFails() async {
    let runner = StubRunner(byExecutable: [
      "git": CommandResult(stdout: "", stderr: "not a repo", exitCode: 128, timedOut: false),
      "jj": CommandResult(stdout: "x.txt\ny.txt\n", stderr: "", exitCode: 0, timedOut: false),
    ])
    let paths = await FileTreeModel.list(path: "/repo", projectRoot: nil, runner: runner)
    XCTAssertEqual(paths, ["x.txt", "y.txt"])
  }

  func testListReturnsNilWhenNeitherVCSResponds() async {
    let runner = StubRunner(byExecutable: [:])  // every command → not-found
    let paths = await FileTreeModel.list(path: "/repo", projectRoot: nil, runner: runner)
    XCTAssertNil(paths)
  }

  /// `jj file list` has no `--ignore-working-copy` — it snapshots `@`, so same-project calls must
  /// serialize through `JJSnapshotGate` (VCS-foundation eng-review follow-up: this call site was
  /// found ungated by adversarial review after the initial fix).
  func testListGatesJJBranchPerProjectRoot() async {
    let recorder = ListConcurrencyRecorder()
    let runner = DelayedJJRunner(recorder: recorder)
    let gate = JJSnapshotGate()
    async let first = FileTreeModel.list(
      path: "/proj/main", projectRoot: "/proj", runner: runner, gate: gate)
    async let second = FileTreeModel.list(
      path: "/proj/ws", projectRoot: "/proj", runner: runner, gate: gate)
    _ = await (first, second)
    let maxConcurrent = await recorder.maxConcurrent
    XCTAssertEqual(maxConcurrent, 1, "same-project jj file list calls must be gated")
  }

  // MARK: PlainFileViewer.classify (read gating)

  func testClassifyEmpty() {
    XCTAssertEqual(PlainFileViewer.classify(data: Data()), .empty)
  }

  func testClassifyTooLarge() {
    XCTAssertEqual(PlainFileViewer.classify(data: Data(count: 100), byteCap: 10), .tooLarge)
  }

  func testClassifyBinaryFromNulByte() {
    XCTAssertEqual(PlainFileViewer.classify(data: Data([0x41, 0x00, 0x42])), .binary)
  }

  func testClassifyBinaryFromInvalidUTF8() {
    // 0xFF/0xFE are not valid UTF-8 and contain no NUL → still binary (decode fails).
    XCTAssertEqual(PlainFileViewer.classify(data: Data([0xFF, 0xFE, 0x41])), .binary)
  }

  func testClassifyText() {
    let data = Data("let x = 1\n".utf8)
    XCTAssertEqual(PlainFileViewer.classify(data: data), .text("let x = 1\n"))
  }

  // MARK: PlainFileViewer.splitLines

  func testSplitLinesDropsTrailingNewlinePhantom() {
    XCTAssertEqual(PlainFileViewer.splitLines("a\nb\n"), ["a", "b"])
    XCTAssertEqual(PlainFileViewer.splitLines("a\nb"), ["a", "b"])
    XCTAssertEqual(PlainFileViewer.splitLines("a\n"), ["a"])
    XCTAssertEqual(PlainFileViewer.splitLines(""), [""])
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

  // MARK: PlainFileViewer.classify (boundary cases)

  func testClassifyAtExactByteCapIsText() {
    // Only strictly over the cap is `.tooLarge`; exactly at the cap still loads.
    let data = Data("abcdefghij".utf8)  // 10 bytes
    XCTAssertEqual(PlainFileViewer.classify(data: data, byteCap: 10), .text("abcdefghij"))
  }

  func testClassifyNulPastScanWindowIsText() {
    // The binary probe only scans the first 8 KB; a NUL past that window isn't detected, so an
    // otherwise-valid-UTF-8 file still classifies as text (documented, bounded-scan behaviour).
    var bytes = [UInt8](repeating: 0x41, count: 9000)  // 'A' × 9000, past the 8 KB scan
    bytes[8500] = 0x00
    guard case .text = PlainFileViewer.classify(data: Data(bytes)) else {
      return XCTFail("a NUL past the 8 KB scan window must not trip the binary probe")
    }
  }

  // MARK: PlainFileViewer.isContained (symlink-escape guard)

  func testIsContainedAcceptsRootAndDescendants() {
    XCTAssertTrue(PlainFileViewer.isContained(path: "/repo", within: "/repo"))
    XCTAssertTrue(PlainFileViewer.isContained(path: "/repo/src/a.swift", within: "/repo"))
  }

  func testIsContainedRejectsSiblingPrefixDirectory() {
    // Component-wise, not string-prefix: "/repo-evil" is NOT inside "/repo".
    XCTAssertFalse(PlainFileViewer.isContained(path: "/repo-evil/x", within: "/repo"))
    XCTAssertFalse(PlainFileViewer.isContained(path: "/elsewhere/x", within: "/repo"))
  }
}

/// A canned `StatusCommandRunning` for the git→jj fallthrough tests: returns a per-executable result,
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

/// Tracks peak concurrently-running sections, for `testListGatesJJBranchPerProjectRoot`.
private actor ListConcurrencyRecorder {
  private(set) var maxConcurrent = 0
  private var running = 0

  func enter() {
    running += 1
    maxConcurrent = max(maxConcurrent, running)
  }

  func exit() {
    running -= 1
  }
}

/// A `jj file list` stub that holds its slot briefly (to create a measurable overlap window if
/// ungated) and fails any other command — isolates the test to the `.jj` branch of `list`.
private struct DelayedJJRunner: StatusCommandRunning {
  let recorder: ListConcurrencyRecorder

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    guard executable == "jj" else {
      return CommandResult(stdout: "", stderr: "not a repo", exitCode: 128, timedOut: false)
    }
    await recorder.enter()
    try? await Task.sleep(nanoseconds: 50_000_000)
    await recorder.exit()
    return CommandResult(stdout: "a.txt\n", stderr: "", exitCode: 0, timedOut: false)
  }
}
