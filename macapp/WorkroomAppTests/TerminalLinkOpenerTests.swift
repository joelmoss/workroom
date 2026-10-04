import XCTest

@testable import Workroom

/// Covers the pure path classification/resolution behind ⌘-click-to-open. The actual launch
/// (`open`) and the kernel cwd lookup are side-effecting and out of scope here.
final class TerminalLinkOpenerTests: XCTestCase {

  // filePath(from:) — web URLs return nil (the caller opens them via NSWorkspace); else a path.

  func testWebURLsAreNotFilePaths() {
    for url in [
      "https://example.com/x", "http://a.b", "mailto:me@x.com", "ssh://host", "git://h/r",
    ] {
      XCTAssertNil(
        TerminalLinkOpener.filePath(from: url), "\(url) should pass through to the browser handler")
    }
  }

  func testFileURLBecomesPath() {
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "file:///tmp/a.txt"), "/tmp/a.txt")
  }

  func testBarePathsAreFilePaths() {
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "src/main.go"), "src/main.go")
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "/etc/hosts"), "/etc/hosts")
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "./rel.txt"), "./rel.txt")
  }

  // absolutePath(for:cwd:) — absolute stays put; ~ expands; relative joins the cwd.

  func testAbsolutePathUnchanged() {
    XCTAssertEqual(
      TerminalLinkOpener.absolutePath(for: "/etc/hosts", cwd: "/somewhere"), "/etc/hosts")
  }

  func testTildeExpands() {
    let home = NSHomeDirectory()
    XCTAssertEqual(TerminalLinkOpener.absolutePath(for: "~/x.txt", cwd: nil), "\(home)/x.txt")
  }

  func testRelativeJoinsCwd() {
    XCTAssertEqual(
      TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: "/proj"), "/proj/src/main.go")
  }

  func testRelativeWithoutCwdIsNil() {
    // No working directory known → can't resolve a relative path.
    XCTAssertNil(TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: nil))
  }

  // openArguments(path:editorBundleID:) — default app vs a chosen, installed editor.

  func testNoEditorUsesDefaultApp() {
    XCTAssertEqual(
      TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: nil), ["/x.txt"])
    XCTAssertEqual(TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: ""), ["/x.txt"])
  }

  func testInstalledEditorOpensWithBundleID() {
    // Finder is always installed, so it stands in for a chosen editor here.
    XCTAssertEqual(
      TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: "com.apple.finder"),
      ["-b", "com.apple.finder", "/x.txt"]
    )
  }

  func testUninstalledEditorFallsBackToDefaultApp() {
    XCTAssertEqual(
      TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: "com.example.nope"),
      ["/x.txt"]
    )
  }

  // pathCandidates(from:) — the literal is always probed first; then trailing-`.` and
  // `:line[:col]` decorations are stripped, with the parsed line/column carried (issue #34).

  private typealias Candidate = TerminalLinkOpener.PathCandidate

  func testPlainPathHasNoExtraCandidates() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.rb"),
      [Candidate(path: "./dev/file.rb", line: nil, column: nil)])
    // A double extension is just part of the name — not a decoration.
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html.erb"),
      [Candidate(path: "./dev/file.html.erb", line: nil, column: nil)])
  }

  func testTrailingDotIsStrippedAfterTheLiteral() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "/Users/me/file.rb."),
      [
        Candidate(path: "/Users/me/file.rb.", line: nil, column: nil),
        Candidate(path: "/Users/me/file.rb", line: nil, column: nil),
      ])
  }

  func testLineSuffixIsStrippedAndCarried() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html:12"),
      [
        Candidate(path: "./dev/file.html:12", line: nil, column: nil),
        Candidate(path: "./dev/file.html", line: 12, column: nil),
      ])
  }

  func testLineAndColumnAreCarried() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html:12:5"),
      [
        Candidate(path: "./dev/file.html:12:5", line: nil, column: nil),
        Candidate(path: "./dev/file.html", line: 12, column: 5),
      ])
  }

  func testNonNumericColumnIsDroppedButLineKept() {
    // Rails-style file:line:in — the line number is kept; the non-numeric tail is decoration.
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html:12:foo"),
      [
        Candidate(path: "./dev/file.html:12:foo", line: nil, column: nil),
        Candidate(path: "./dev/file.html", line: 12, column: nil),
      ])
  }

  func testColonNotFollowedByDigitIsKept() {
    // Only a ":<digit>" boundary is a line suffix; a bare colon stays part of the literal.
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "a:b/file.rb"),
      [Candidate(path: "a:b/file.rb", line: nil, column: nil)])
  }

  // launchInvocation(...) — line-aware editor dispatch. editorInstalled and the editor CLI paths are
  // injected so the mapping is pure; the with-line branches do not touch Launch Services.

  func testVSCodeSeeksToLineViaBundledCLI() {
    let cli = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    let withColumn = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true, vscodeCLIPath: cli,
      zedCLIPath: nil)
    XCTAssertEqual(withColumn.executable, cli)
    XCTAssertEqual(withColumn.arguments, ["--goto", "/proj/app.rb:12:5"])

    let lineOnly = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: nil),
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true, vscodeCLIPath: cli,
      zedCLIPath: nil)
    XCTAssertEqual(lineOnly.arguments, ["--goto", "/proj/app.rb:12"])
  }

  func testVSCodeFallsBackToURLSchemeWhenCLIMissing() {
    // The URL handler is the last resort, reached only when the bundled `code` binary is missing.
    // It always carries a column, matching VS Code's documented `:line:column` form.
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: nil),
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true, vscodeCLIPath: nil,
      zedCLIPath: nil)
    XCTAssertEqual(inv.executable, "/usr/bin/open")
    XCTAssertEqual(inv.arguments, ["vscode://file/proj/app.rb:12:1"])
  }

  func testZedSeeksToLineViaBundledCLI() {
    let cli = "/Applications/Zed.app/Contents/MacOS/cli"
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "dev.zed.Zed", editorInstalled: true, vscodeCLIPath: nil, zedCLIPath: cli)
    XCTAssertEqual(inv.executable, cli)
    XCTAssertEqual(inv.arguments, ["/proj/app.rb:12:5"])
  }

  func testZedFallsBackToOpenWhenCLIMissing() {
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "dev.zed.Zed", editorInstalled: true, vscodeCLIPath: nil, zedCLIPath: nil)
    // Opens at the top; the exact `-b` argv depends on whether Zed is installed in this environment.
    XCTAssertEqual(inv.executable, "/usr/bin/open")
    XCTAssertEqual(inv.arguments.last, "/proj/app.rb")
  }

  func testXcodeSeeksToLineViaXed() {
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "com.apple.dt.Xcode", editorInstalled: true, vscodeCLIPath: nil,
      zedCLIPath: nil)
    XCTAssertEqual(inv.executable, "/usr/bin/xed")
    XCTAssertEqual(inv.arguments, ["--line", "12", "/proj/app.rb"])  // no column option in xed
  }

  func testNoLineOpensViaOpenRegardlessOfEditor() {
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: nil, column: nil),
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true, vscodeCLIPath: nil,
      zedCLIPath: nil)
    XCTAssertEqual(inv.executable, "/usr/bin/open")
    XCTAssertEqual(inv.arguments.last, "/proj/app.rb")
  }

  func testUninstalledOrUnknownEditorWithLineOpensInDefaultApp() {
    // Uninstalled chosen editor → default app (no -b), no line.
    let uninstalled = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/x.rb", line: 12, column: nil),
      editorBundleID: "com.example.nope", editorInstalled: false, vscodeCLIPath: nil,
      zedCLIPath: nil)
    XCTAssertEqual(uninstalled.executable, "/usr/bin/open")
    XCTAssertEqual(uninstalled.arguments, ["/x.rb"])

    // An editor we don't know how to seek in → open it (here "nope" isn't installed → default app).
    let unknown = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/x.rb", line: 12, column: nil),
      editorBundleID: "com.example.nope", editorInstalled: true, vscodeCLIPath: nil, zedCLIPath: nil
    )
    XCTAssertEqual(unknown.arguments, ["/x.rb"])
  }

  // launchInvocations(...) — project-aware: open the workroom folder + file in one editor window so
  // the file lands in the workroom's window, not whatever editor window was frontmost.

  func testProjectAwareVSCodeOpensFolderAndSeeksViaCLI() {
    let cli = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    let inv = TerminalLinkOpener.launchInvocations(
      file: .init(path: "/proj/app.rb", line: 12, column: 5), project: "/proj",
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true,
      vscodeCLIPath: cli, zedCLIPath: nil)
    XCTAssertEqual(inv.count, 1)
    XCTAssertEqual(inv[0].executable, cli)
    XCTAssertEqual(inv[0].arguments, ["/proj", "--goto", "/proj/app.rb:12:5"])
  }

  func testProjectAwareVSCodeNoLineStillOpensFolderAndFile() {
    let inv = TerminalLinkOpener.launchInvocations(
      file: .init(path: "/proj/app.rb", line: nil, column: nil), project: "/proj",
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true,
      vscodeCLIPath: "/x/code", zedCLIPath: nil)
    XCTAssertEqual(inv[0].arguments, ["/proj", "--goto", "/proj/app.rb"])
  }

  func testProjectAwareVSCodeFallsBackToFileOnlyWhenCLIMissing() {
    // No `code` CLI → can't target the folder; degrade to the file-only URL open (column defaulted).
    let inv = TerminalLinkOpener.launchInvocations(
      file: .init(path: "/proj/app.rb", line: 12, column: nil), project: "/proj",
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true,
      vscodeCLIPath: nil, zedCLIPath: nil)
    XCTAssertEqual(inv.count, 1)
    XCTAssertEqual(inv[0].executable, "/usr/bin/open")
    XCTAssertEqual(inv[0].arguments, ["vscode://file/proj/app.rb:12:1"])
  }

  func testProjectAwareZedOpensFolderAndFileViaCLI() {
    let cli = "/Applications/Zed.app/Contents/MacOS/cli"
    let inv = TerminalLinkOpener.launchInvocations(
      file: .init(path: "/proj/app.rb", line: 12, column: 5), project: "/proj",
      editorBundleID: "dev.zed.Zed", editorInstalled: true,
      vscodeCLIPath: nil, zedCLIPath: cli)
    XCTAssertEqual(inv.count, 1)
    XCTAssertEqual(inv[0].executable, cli)
    XCTAssertEqual(inv[0].arguments, ["/proj", "/proj/app.rb:12:5"])
  }

  func testProjectAwareXcodeOpensFolderThenFile() {
    // xed's --line works only on a lone file, so two calls: folder first, then the file at its line.
    let inv = TerminalLinkOpener.launchInvocations(
      file: .init(path: "/proj/app.rb", line: 12, column: 5), project: "/proj",
      editorBundleID: "com.apple.dt.Xcode", editorInstalled: true,
      vscodeCLIPath: nil, zedCLIPath: nil)
    XCTAssertEqual(inv.count, 2)
    XCTAssertEqual(inv[0].executable, "/usr/bin/xed")
    XCTAssertEqual(inv[0].arguments, ["/proj"])
    XCTAssertEqual(inv[1].arguments, ["--line", "12", "/proj/app.rb"])  // no column option in xed
  }

  func testNoProjectUsesPlainFileOnlyInvocation() {
    // Terminal ⌘-click (no project) opens the file alone — but still through `code --goto`, so it
    // seeks to the line the same way the project-aware branch does.
    let inv = TerminalLinkOpener.launchInvocations(
      file: .init(path: "/proj/app.rb", line: 12, column: nil), project: nil,
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true,
      vscodeCLIPath: "/x/code", zedCLIPath: nil)
    XCTAssertEqual(inv.count, 1)
    XCTAssertEqual(inv[0].executable, "/x/code")
    XCTAssertEqual(inv[0].arguments, ["--goto", "/proj/app.rb:12"])
  }

  func testProjectWithDefaultAppOpensFileOnly() {
    // "Default App" (empty bundle id) has no folder concept → file-only.
    let inv = TerminalLinkOpener.launchInvocations(
      file: .init(path: "/proj/app.rb", line: nil, column: nil), project: "/proj",
      editorBundleID: "", editorInstalled: false, vscodeCLIPath: nil, zedCLIPath: nil)
    XCTAssertEqual(inv.count, 1)
    XCTAssertEqual(inv[0].arguments, ["/proj/app.rb"])
  }

  // The pure URL/arg builders.

  func testPositionSuffixed() {
    XCTAssertEqual(
      TerminalLinkOpener.positionSuffixed(.init(path: "/a/b.rb", line: nil, column: nil)), "/a/b.rb"
    )
    XCTAssertEqual(
      TerminalLinkOpener.positionSuffixed(.init(path: "/a/b.rb", line: 7, column: nil)), "/a/b.rb:7"
    )
    XCTAssertEqual(
      TerminalLinkOpener.positionSuffixed(.init(path: "/a/b.rb", line: 7, column: 3)), "/a/b.rb:7:3"
    )
  }

  func testVSCodeURLPercentEncodesPathKeepingSlashes() {
    XCTAssertEqual(
      TerminalLinkOpener.vscodeFileURL(path: "/proj/my app.rb", line: 7, column: nil),
      "vscode://file/proj/my%20app.rb:7:1")
    XCTAssertEqual(
      TerminalLinkOpener.vscodeFileURL(path: "/a/b.rb", line: 7, column: 3),
      "vscode://file/a/b.rb:7:3")
  }

  func testZedPositionArgument() {
    XCTAssertEqual(
      TerminalLinkOpener.zedPositionArgument(path: "/a/b.rb", line: 7, column: 3), "/a/b.rb:7:3")
    XCTAssertEqual(
      TerminalLinkOpener.zedPositionArgument(path: "/a/b.rb", line: 7, column: nil), "/a/b.rb:7")
  }

  // resolvesToFile(_:cwd:) — end-to-end against real files: every shape in issue #34 resolves.

  func testIssue34PathShapesAllResolve() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = dir.appendingPathComponent("dev")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    for name in ["file.rb", "file.html", "file.html.erb"] {
      fm.createFile(atPath: nested.appendingPathComponent(name).path, contents: Data())
    }
    defer { try? fm.removeItem(at: dir) }
    let cwd = dir.path
    let absoluteRb = nested.appendingPathComponent("file.rb").path

    XCTAssertTrue(TerminalLinkOpener.resolvesToFile(absoluteRb, cwd: nil))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("\(absoluteRb).", cwd: nil))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.rb", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("dev/file.rb", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.html.erb", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.html:12", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.html:12:foo", cwd: cwd))

    XCTAssertFalse(TerminalLinkOpener.resolvesToFile("./dev/missing.rb", cwd: cwd))
  }

  // isSystemHandledURL(_:) — only a scheme an installed app actually claims may reach NSWorkspace.
  // libghostty's link regex reports path-shaped text as a link; when it doesn't resolve on disk,
  // handing it to LaunchServices raised a modal Finder "-50" alert instead of doing nothing.

  func testClaimedSchemesAreSystemHandled() throws {
    // http/https/mailto always have a handler on macOS (Safari / Mail).
    for url in ["https://example.com/x", "http://a.b", "mailto:me@x.com"] {
      XCTAssertTrue(
        TerminalLinkOpener.isSystemHandledURL(try XCTUnwrap(URL(string: url), url)),
        "\(url) should go to the system handler")
    }
  }

  func testSchemelessPathsAreNotSystemHandled() throws {
    // The shapes LaunchServices raised "-50" on: gem-root-relative Rails backtrace frames (which
    // exist nowhere on disk, being relative to the gem rather than the repo) and a bare URL *path*.
    for url in [
      "acme/app/views/acme/cms/pages/show.rb:1:in",
      "acme/lib/acme/controller_concerns/cms/pages.rb:96",
      "./acme/lib/acme/controller_concerns/cms/pages.rb",
      "/acme/lib/acme/controller_concerns/cms/pages.rb",
      "/rails/active_storage/disk/abc123/banner.webp",
    ] {
      XCTAssertFalse(
        TerminalLinkOpener.isSystemHandledURL(try XCTUnwrap(URL(string: url), url)),
        "\(url) has no scheme — opening it raises the Finder -50 alert")
    }
  }

  func testFilenameSchemesAreNotSystemHandled() throws {
    // A filename is a legal URL scheme, so a bare `file:line` link parses with a bogus scheme. No app
    // claims it — it must not reach NSWorkspace either.
    for url in ["user.rb:5", "main.go:10:3", "Gemfile:12", "a.rb:32-40"] {
      let parsed = try XCTUnwrap(URL(string: url), url)
      XCTAssertNotNil(parsed.scheme, "\(url) parses with a filename as its scheme")
      XCTAssertFalse(TerminalLinkOpener.isSystemHandledURL(parsed), "\(url) has no handler")
    }
  }

  func testFileURLsAreNotSystemHandled() throws {
    // A file: URL only reaches the fallback when it didn't resolve on disk, so it's a no-op too.
    XCTAssertFalse(
      TerminalLinkOpener.isSystemHandledURL(try XCTUnwrap(URL(string: "file:///tmp/missing.txt"))))
    XCTAssertFalse(
      TerminalLinkOpener.isSystemHandledURL(try XCTUnwrap(URL(string: "FILE:///tmp/missing.txt"))))
  }

  // resolveLocalFile(from:cwd:) — a URL must never be offered to filesystem resolution. Dropping the
  // old `url.scheme == nil` guard (a filename is a legal scheme name) opened a shadowing hole: the
  // passthrough list is case-sensitive, so `HTTPS://…` survived it, and appendingPathComponent
  // collapses the `//` — a repo shipping `HTTPS:/example.com/x.command` captured the click.

  func testURLsWithAnAuthorityNeverResolveToAFile() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // The shadow files a malicious repo would ship, at the exact paths the join produces.
    for shadow in ["HTTPS:/example.com", "vscode:/file/tmp", "anything:/evil"] {
      try fm.createDirectory(
        at: dir.appendingPathComponent(shadow), withIntermediateDirectories: true)
    }
    for shadow in [
      "HTTPS:/example.com/payload.command", "vscode:/file/tmp/payload.command",
      "anything:/evil/payload.command",
    ] {
      fm.createFile(atPath: dir.appendingPathComponent(shadow).path, contents: Data())
    }
    defer { try? fm.removeItem(at: dir) }

    for link in [
      "HTTPS://example.com/payload.command",  // case-sensitive passthrough list misses this
      "vscode://file/tmp/payload.command",  // a scheme an app claims, but not via the list
      "anything://evil/payload.command",  // a scheme no app claims at all
      "https://example.com/x",
    ] {
      let url = try XCTUnwrap(URL(string: link), link)
      XCTAssertNil(
        TerminalLinkOpener.resolveLocalFile(from: url, cwd: dir.path),
        "\(link) is a URL — it must never resolve to a file, even when one sits at the joined path")
    }
  }

  func testBareWordClickAlsoRejectsURLs() throws {
    // The ⌘-click word path (resolvesToFile) does NOT go through resolveLocalFile, so the guard has
    // to live in filePath(from:) — their shared chokepoint — or this entry point stays open.
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(
      at: dir.appendingPathComponent("HTTP:/evil.com"), withIntermediateDirectories: true)
    fm.createFile(
      atPath: dir.appendingPathComponent("HTTP:/evil.com/a.command").path, contents: Data())
    defer { try? fm.removeItem(at: dir) }

    XCTAssertFalse(
      TerminalLinkOpener.resolvesToFile("HTTP://evil.com/a.command", cwd: dir.path),
      "a case-variant web URL must not resolve to the repo file that shadows it")
  }

  func testPassthroughSchemeMatchIsCaseInsensitive() {
    for link in ["HTTPS://a.b", "Http://a.b", "MAILTO:me@x.com", "SSH://host"] {
      XCTAssertNil(TerminalLinkOpener.filePath(from: link), "\(link) is a web URL, not a path")
    }
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "FILE:///tmp/a.txt"), "/tmp/a.txt")
  }

  func testLooksLikeURLSplitsSchemesFromLineDecorations() {
    // With an authority, and opaque (no `//`) — both are URL bodies, neither is a path.
    for link in [
      "https://a.b", "HTTPS://a.b", "x-y+z.1://a", "anything://evil/x", "smb://attacker/share",
      "javascript:payload.command", "data:text/html,x", "mailto:x@y.com", "a:b/file.rb", "C:/x",
    ] {
      XCTAssertTrue(TerminalLinkOpener.looksLikeURL(link), "\(link) leads with a scheme")
    }
    // A `word:` followed by a DIGIT is the `:line[:col]` decoration, the one legitimate form.
    for link in [
      "user.rb:5", "Gemfile:12", "main.go:10:3", "a.rb:32-40", "a/b:12:in", "/abs/path.rb",
      "./rel.rb", "../up.rb", "~/x.rb", "src/main.go",
    ] {
      XCTAssertFalse(TerminalLinkOpener.looksLikeURL(link), "\(link) is a path")
    }
  }

  func testOpaqueSchemesNeverResolveToAFile() throws {
    // No `://` to catch, so only the digit test separates `javascript:payload.command` from
    // `user.rb:5`. A repo can ship a file under either name.
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for shadow in ["javascript:payload.command", "data:payload.command"] {
      fm.createFile(atPath: dir.appendingPathComponent(shadow).path, contents: Data())
    }
    defer { try? fm.removeItem(at: dir) }

    for link in ["javascript:payload.command", "data:payload.command"] {
      XCTAssertFalse(
        TerminalLinkOpener.resolvesToFile(link, cwd: dir.path),
        "\(link) is an opaque URL — the cwd file shadowing it must not be opened")
      let url = try XCTUnwrap(URL(string: link), link)
      XCTAssertNil(TerminalLinkOpener.resolveLocalFile(from: url, cwd: dir.path), link)
    }
  }

  // A relative cwd would leave the resolved path relative, and a relative path becomes a FLAG once
  // it is an argv element (`--locale=en` rather than `<cwd>/--locale=en`).
  func testRelativeCwdResolvesNothing() {
    for cwd in ["", "relative/dir", "./dir"] {
      XCTAssertNil(TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: cwd), "cwd \(cwd)")
    }
    XCTAssertEqual(
      TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: "/proj"), "/proj/src/main.go")
  }

  // resolveLocalFile(from:cwd:) — the libghostty link path resolves the same decorations ⌘-click
  // does: a `:line`, a `:line:col`, a `:line-line` range, and a Rails `:line:in '…'` frame all reduce
  // to the bare path. Called directly (it is internal, not private) so no editor is launched.

  func testLinkDecorationsReduceToPathAndLine() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = dir.appendingPathComponent("config/initializers")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let rb = nested.appendingPathComponent("scrub_client_ip_header.rb")
    let user = dir.appendingPathComponent("user.rb")
    for file in [rb, user] { fm.createFile(atPath: file.path, contents: Data()) }
    defer { try? fm.removeItem(at: dir) }
    let cwd = dir.path
    let base = "config/initializers/scrub_client_ip_header.rb"

    let cases: [(link: String, path: String, line: Int?)] = [
      (base, rb.path, nil),
      ("\(base):32", rb.path, 32),
      ("\(base):32:7", rb.path, 32),
      ("\(base):32-40", rb.path, 32),  // a line range seeks to its first line
      ("\(base):32:in", rb.path, 32),  // Rails backtrace frame — `:in` is not part of the path
      // A bare filename + line: `URL(string:)` reads "user.rb" as the *scheme*, which used to make
      // this look like a web URL and resolve to nothing.
      ("user.rb:5", user.path, 5),
    ]
    for (link, path, line) in cases {
      let url = try XCTUnwrap(URL(string: link), link)
      let resolved = TerminalLinkOpener.resolveLocalFile(from: url, cwd: cwd)
      XCTAssertEqual(resolved?.path, path, "\(link) should resolve to the file")
      XCTAssertEqual(resolved?.line, line, "\(link) should carry its line")
    }
  }

  // MARK: Remote panes (#254, C7)

  /// A remote pane's link resolves against the HOST's paths, to a workroom-relative file, in the
  /// local order: the literal first, then the decoration-stripped forms carrying their line.
  func testARemoteLinkResolvesAgainstTheHostsDirectory() {
    let root = "/home/workroom/repo"
    let candidates = TerminalLinkOpener.remoteCandidates(
      for: "app/user.rb:5:2", cwd: "\(root)/lib", root: root)
    XCTAssertEqual(
      candidates,
      [
        .init(path: "lib/app/user.rb:5:2", line: nil, column: nil),
        .init(path: "lib/app/user.rb", line: 5, column: 2),
      ])
    // No cwd yet: the workroom's root.
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "README.md", cwd: nil, root: root).map(\.path),
      ["README.md"])
    // An absolute path inside the workroom, and `..` back into it.
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "\(root)/a/b.txt", cwd: "/", root: root).map(
        \.path), ["a/b.txt"])
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "../x.txt", cwd: "\(root)/lib", root: root).map(
        \.path), ["x.txt"])
  }

  /// A remote path reaches the host with the bytes it was written in. Foundation's URL
  /// normalisation decomposes `é` (C3 A9) into `e` + U+0301 (65 CC 81), which a Linux host reads as
  /// another filename; Swift's `==` calls the two equal, so the bytes are compared.
  func testARemoteLinkKeepsItsFilenameBytes() throws {
    let name = "caf\u{e9}.txt"
    let found = try XCTUnwrap(
      TerminalLinkOpener.remoteCandidates(for: name, cwd: nil, root: "/home/workroom/repo").first)
    XCTAssertEqual(Array(found.path.utf8), Array(name.utf8))
  }

  /// What a read is sent never has a `.` or `..` component: the agent refuses such a path before
  /// it opens anything (`vcs::relative`), so a parent traversal is also resolved here. Sent to a
  /// read as written, every `../file.rb` click opened nothing (found in review). The `..` goes to
  /// the host's `resolve` instead (#327), as `onHost`, and only when it stays in the workroom.
  func testARemoteLinkNeverSendsTheHostAParentComponent() {
    let root = "/home/workroom/repo"
    for (link, cwd) in [
      ("../x.txt", "\(root)/lib"), ("link/../file.rb", root), ("./a/./b.rb", root),
      ("../lib/../y.rb:3", "\(root)/lib/deep"),
    ] {
      let candidates = TerminalLinkOpener.remoteCandidates(for: link, cwd: cwd, root: root)
      XCTAssertFalse(candidates.isEmpty, link)
      for candidate in candidates {
        let parts = candidate.path.split(separator: "/", omittingEmptySubsequences: false)
        XCTAssertFalse(parts.contains { $0 == ".." || $0 == "." || $0.isEmpty }, candidate.path)
      }
    }
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "link/../../../out.rb", cwd: root, root: root), [])
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "link/../file.rb:3", cwd: root, root: root).last,
      .init(path: "file.rb", line: 3, column: nil, onHost: "link/../file.rb"))
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "../x.txt", cwd: "\(root)/lib", root: root).first?
        .onHost, "lib/../x.txt")
    // No `..`, nothing to resolve; and one that climbs out of the root as written and back in is
    // only resolved here, since the agent refuses it before any lookup.
    XCTAssertNil(
      TerminalLinkOpener.remoteCandidates(for: "a/b.rb", cwd: root, root: root).first?.onHost)
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "../repo/x.rb", cwd: root, root: root),
      [.init(path: "x.rb", line: nil, column: nil)])
    // Value: protects=the host is only asked to resolve a path that starts at the workroom root as
    // written, so a click from a cwd outside it never sends the host a path cut from the middle
    // (`workroom/repo/link/../x.rb`), which it would join to the root and read as another file;
    // fails_when=`onHost` is computed without checking that the written path starts at the root;
    // why_new=the cases above all start at the root, so the check is never false there; seam=none
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(
        for: "../home/workroom/repo/link/../x.rb", cwd: "/srv", root: root),
      [.init(path: "x.rb", line: nil, column: nil)])
  }

  /// #327: `link/../file.rb` is the file beside the link's TARGET, which the host resolves. An
  /// agent from before `resolve` answers it as unsupported, and the click falls back to the
  /// lexical path, as before. A host that says the path is not there is believed.
  @MainActor
  func testARemoteParentTraversalIsResolvedOnTheHost() async throws {
    let target = TerminalTarget(
      id: "remote", title: "remote", path: "/home/workroom/repo", unavailability: .remote,
      remoteHost: UUID())
    let sessions = TerminalSessions()
    func provider(resolved: [String: String] = [:], failing: [String: Error] = [:])
      -> (RepositoryLocation) async throws -> FileProviding
    {
      { location in
        HostFiles(
          context: FileContext(location: location, sharedLocation: nil),
          files: ["nested/file.rb": Data("x\n".utf8), "file.rb": Data("decoy\n".utf8)],
          failing: failing, resolved: resolved)
      }
    }

    sessions.remoteFiles = provider(resolved: ["link/../file.rb": "nested/file.rb"])
    let resolved = await sessions.remoteFile("link/../file.rb:4", cwd: nil, target: target)
    XCTAssertEqual(resolved, .init(path: "nested/file.rb", line: 4, column: nil))

    sessions.remoteFiles = provider(failing: [
      "link/../file.rb": FileServiceError.failed(AgentFileProvider.unknownMethod)
    ])
    let older = await sessions.remoteFile("link/../file.rb", cwd: nil, target: target)
    XCTAssertEqual(older, .init(path: "file.rb", line: nil, column: nil))

    sessions.remoteFiles = provider()
    let missing = await sessions.remoteFile("link/../file.rb", cwd: nil, target: target)
    XCTAssertNil(missing, "the decoy beside the link opened after the host found nothing")

    // Busy, or an error resolving (a link into an unreadable directory, a loop), is not an agent
    // that can't resolve: the decoy stays shut.
    for failure in ["too many reads in flight", "Permission denied (os error 13)"] {
      sessions.remoteFiles = provider(failing: [
        "link/../file.rb": FileServiceError.failed(failure)
      ])
      let failed = await sessions.remoteFile("link/../file.rb", cwd: nil, target: target)
      XCTAssertNil(failed, "the decoy opened after the host failed with \(failure)")
    }

    // Value: protects=a resolve that hit its deadline (a link onto a hung mount, #334) ends the
    // click, so its other candidates don't each wait out another deadline and leave another walk
    // behind; fails_when=`remoteFile` treats the timeout like any other failure and goes on to the
    // next candidate; why_new=every other failure here skips one candidate only; seam=none
    sessions.remoteFiles = provider(
      resolved: ["link/../file.rb": "nested/file.rb"],
      failing: ["link/../file.rb:4": FileServiceError.failed("resolving timed out after 10s")])
    let timedOut = await sessions.remoteFile("link/../file.rb:4", cwd: nil, target: target)
    XCTAssertNil(timedOut, "a click went on to the next candidate after its resolve timed out")

    // So does the agent's refusal while too many earlier walks are stuck: the next candidate of
    // `link/file.rb:12/../t.rb` is plain `link/file.rb`, a read through the same hung link with no
    // deadline (#343). It exists here, so reading it would return it.
    sessions.remoteFiles = { location in
      HostFiles(
        context: FileContext(location: location, sharedLocation: nil),
        files: ["link/file.rb": Data("x\n".utf8)],
        failing: [
          "link/file.rb:12/../t.rb": FileServiceError.failed(
            AgentFileProvider.resolveWalksBusy)
        ])
    }
    let busy = await sessions.remoteFile("link/file.rb:12/../t.rb", cwd: nil, target: target)
    XCTAssertNil(busy, "a click read through the hung link after the agent refused its resolve")
  }

  /// Only what the host's file service can read: nothing outside the workroom's root, no `~` (this
  /// Mac's home), and no URL.
  func testARemoteLinkOutsideTheWorkroomOrNotAPathGivesNothing() {
    let root = "/home/workroom/repo"
    for link in [
      "/etc/passwd", "../../other/file.txt", "~/notes.txt", "https://example.com/a.rb",
      "javascript:payload.command", "/home/workroom/repository/file",
    ] {
      XCTAssertEqual(
        TerminalLinkOpener.remoteCandidates(for: link, cwd: root, root: root), [], link)
    }
    // Value: protects=a remote link never resolves against this Mac's cwd;
    //   fails_when=the absolute-cwd or absolute-root guard is dropped;
    //   why_new=rows above only use absolute roots and cwds; seam=none
    // A cwd that is not absolute is ignored for the root, and a root that is not absolute gives
    // nothing: `URL` would otherwise resolve either one against THIS Mac's working directory.
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "a.rb", cwd: "lib", root: root).map(\.path), ["a.rb"]
    )
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "a.rb", cwd: nil, root: "relative/repo"), [])
  }

  /// The acceptance test for C7: the workroom's path exists on THIS Mac too, holding a different
  /// file. ⌘-click resolves only what the host has, and a file only this Mac has resolves to
  /// nothing.
  @MainActor
  func testARemotePaneOpensTheHostsFileNotTheMacs() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    fm.createFile(atPath: root.appendingPathComponent("only-on-mac.txt").path, contents: Data())

    let host = UUID()
    let target = TerminalTarget(
      id: "remote", title: "remote", path: root.path, unavailability: .remote, remoteHost: host)
    let location = try XCTUnwrap(target.remoteLocation)
    let sessions = TerminalSessions()
    sessions.remoteFiles = { location in
      HostFiles(
        context: FileContext(location: location, sharedLocation: nil),
        files: ["only-on-host.rb": Data("puts 1\n".utf8)])
    }

    let found = await sessions.remoteFile("only-on-host.rb:3", cwd: nil, target: target)
    XCTAssertEqual(found, .init(path: "only-on-host.rb", line: 3, column: nil))
    let onMac = await sessions.remoteFile("only-on-mac.txt", cwd: nil, target: target)
    XCTAssertNil(onMac, "a file that is only on this Mac was taken for the host's")
    XCTAssertEqual(location.host, .remote(host))
  }

  /// The wiring: a remote target's pane routes ⌘-click to the host and opens the file it finds as
  /// the workroom's preview tab, in the in-app viewer.
  @MainActor
  func testCmdClickInARemotePaneOpensTheHostsFileInTheViewer() async throws {
    let target = TerminalTarget(
      id: "remote", title: "remote", path: "/home/workroom/repo", unavailability: .remote,
      remoteHost: UUID())
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.remoteFiles = { location in
      HostFiles(
        context: FileContext(location: location, sharedLocation: nil),
        files: ["lib/user.rb": Data("class User; end\n".utf8)])
    }
    let tab = sessions.addTab(for: target)
    let view = try XCTUnwrap(sessions.view(forTab: tab.id, inTarget: target.id))
    view.onCmdClickFile?("lib/user.rb:1")
    func opened() -> FileDescriptor? {
      for tab in sessions.tabs(for: target) {
        if case .file(let file) = tab.content { return file }
      }
      return nil
    }
    for _ in 0..<200 where opened() == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(opened()?.path, "lib/user.rb")
  }

  /// What the probe makes of the host's answers, one candidate at a time. A refused candidate (a
  /// link out of the root, a directory) is skipped for the next, as a missing one is. Any other
  /// failure is the HOST's (it dropped, the agent errored), so the next candidate would fail the
  /// same way and the probe gives up with nothing, rather than reporting a file it never read.
  // Value: protects=the host probe skips refused candidates but stops on a host failure;
  //   fails_when=refused stops the probe, or a host failure continues to a later candidate;
  //   why_new=existing tests only reach found, tooLarge and notFound; seam=none
  @MainActor
  func testTheRemoteProbeSkipsRefusedCandidatesAndStopsOnAHostFailure() async throws {
    let target = TerminalTarget(
      id: "remote", title: "remote", path: "/home/workroom/repo", unavailability: .remote,
      remoteHost: UUID())
    let sessions = TerminalSessions()
    let files: [String: Data] = ["a.rb": Data("x\n".utf8)]
    func provider(failing: [String: Error]) -> (RepositoryLocation) async throws
      -> FileProviding
    {
      { location in
        HostFiles(
          context: FileContext(location: location, sharedLocation: nil), files: files,
          failing: failing)
      }
    }

    // `a.rb:3` probes the literal first, then `a.rb` carrying line 3.
    sessions.remoteFiles = provider(failing: [
      "a.rb:3": FileServiceError.refused("not a regular file")
    ])
    let skipped = await sessions.remoteFile("a.rb:3", cwd: nil, target: target)
    XCTAssertEqual(skipped, .init(path: "a.rb", line: 3, column: nil))

    // An error reading one path (too long, unreadable) moves on to the next candidate.
    sessions.remoteFiles = provider(failing: [
      "a.rb:3": FileServiceError.failed("File name too long (os error 63)")
    ])
    let pathError = await sessions.remoteFile("a.rb:3", cwd: nil, target: target)
    XCTAssertEqual(pathError, .init(path: "a.rb", line: 3, column: nil))

    sessions.remoteFiles = provider(failing: ["a.rb:3": HostConnectionError.connectionLost])
    let stopped = await sessions.remoteFile("a.rb:3", cwd: nil, target: target)
    XCTAssertNil(stopped, "a host failure went on to probe a later candidate")

    // The host's service itself unreachable: nothing to probe, nothing found.
    sessions.remoteFiles = { _ in throw RepositoryRoutingError.unavailable(.remote(UUID())) }
    let unreachable = await sessions.remoteFile("a.rb", cwd: nil, target: target)
    XCTAssertNil(unreachable)
  }

  /// A link libghostty hands over as a URL (OSC 8, or a printed `file:` URL) reaches the host's
  /// file in a remote pane, whether it is a `file:` URL or a bare path: through `remoteLink`, which
  /// decodes percent-escapes and takes a `file:` URL's path.
  // Value: protects=a remote pane's URL links open the host's file, decoded;
  //   fails_when=onOpenURL stops routing to the host or remoteLink stops decoding;
  //   why_new=only the word-based click path is tested; seam=none
  @MainActor
  func testAnOpenURLLinkInARemotePaneOpensTheHostsFile() async throws {
    let target = TerminalTarget(
      id: "remote", title: "remote", path: "/home/workroom/repo", unavailability: .remote,
      remoteHost: UUID())
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.remoteFiles = { location in
      HostFiles(
        context: FileContext(location: location, sharedLocation: nil),
        files: ["lib/user.rb": Data("class User; end\n".utf8), "my file.rb": Data("x\n".utf8)])
    }
    let tab = sessions.addTab(for: target)
    let view = try XCTUnwrap(sessions.view(forTab: tab.id, inTarget: target.id))
    func opened() -> String? {
      for tab in sessions.tabs(for: target) {
        if case .file(let file) = tab.content { return file.path }
      }
      return nil
    }
    func click(_ link: String, opens path: String) async throws {
      let url = try XCTUnwrap(URL(string: link), link)
      XCTAssertEqual(view.onOpenURL?(url), true, "the click was not consumed: \(link)")
      for _ in 0..<200 where opened() != path { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertEqual(opened(), path, link)
    }
    try await click("file:///home/workroom/repo/lib/user.rb", opens: "lib/user.rb")
    try await click("my%20file.rb", opens: "my file.rb")
  }

  /// The remote ⌘-click gate decides from the word alone (#254): a path-shaped candidate passes
  /// (a `/`, a `name.ext` or a `:line`), and anything else falls through to the terminal: a plain
  /// word, a dotless bare name, a URL, a path outside the workroom.
  func testTheRemoteClickGateTakesPathShapedWordsOnly() {
    let root = "/home/workroom/repo"
    for word in [
      "lib/user.rb", "user.rb", "user.rb:5", "Makefile:12", "./bin/dev", "a.b.c", ".gitignore",
      ".env",
    ] {
      XCTAssertTrue(TerminalLinkOpener.looksLikeRemotePath(word, cwd: root, root: root), word)
    }
    for word in [
      "hello", "Gemfile", "done.", "https://example.com/a.rb", "/etc/passwd", "~/notes.txt",
      "../../elsewhere/a.rb",
    ] {
      XCTAssertFalse(TerminalLinkOpener.looksLikeRemotePath(word, cwd: root, root: root), word)
    }
  }

  /// The gate never asks the host: a hover in a remote pane, ⌘ held, makes no request at all,
  /// so a host that is slow, down or hung can't lose, take or pile up clicks. Only the click asks.
  @MainActor
  func testARemotePanesGateNeverAsksTheHost() async throws {
    let target = TerminalTarget(
      id: "remote", title: "remote", path: "/home/workroom/repo", unavailability: .remote,
      remoteHost: UUID())
    let asked = Counter()
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.remoteFiles = { location in
      asked.bump()
      return HostFiles(
        context: FileContext(location: location, sharedLocation: nil),
        files: ["a.rb": Data("x\n".utf8)])
    }
    let tab = sessions.addTab(for: target)
    let view = try XCTUnwrap(sessions.view(forTab: tab.id, inTarget: target.id))
    XCTAssertEqual(view.resolveCmdHoverFile?("a.rb"), true)
    XCTAssertEqual(view.resolveCmdHoverFile?("hello"), false)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(asked.count, 0, "a hover asked the host")
    view.onCmdClickFile?("a.rb")
    for _ in 0..<200 where asked.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(asked.count, 1, "the click did not ask the host")
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  /// A newer remote ⌘-click replaces the one before it (#254): the host can take seconds, and a
  /// slow answer must not retarget the preview after a faster one. Nor may an answer open anything
  /// once the pane that asked has closed, even with other panes still open in the workroom.
  @MainActor
  func testARemoteClickIsReplacedByTheNextAndDroppedForAClosedPane() async throws {
    let target = TerminalTarget(
      id: "remote", title: "remote", path: "/home/workroom/repo", unavailability: .remote,
      remoteHost: UUID())
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.remoteFiles = { location in
      SlowHostFiles(
        inner: HostFiles(
          context: FileContext(location: location, sharedLocation: nil),
          files: ["slow.rb": Data("x\n".utf8), "fast.rb": Data("x\n".utf8)]))
    }
    let tab = sessions.addTab(for: target)
    let view = try XCTUnwrap(sessions.view(forTab: tab.id, inTarget: target.id))
    func opened() -> String? {
      for tab in sessions.tabs(for: target) {
        if case .file(let file) = tab.content { return file.path }
      }
      return nil
    }
    view.onCmdClickFile?("slow.rb")
    view.onCmdClickFile?("fast.rb")
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertEqual(opened(), "fast.rb", "a slower, older click retargeted the preview")

    // The pane that asked closes while the host is still answering, with another pane still
    // open in the workroom: nothing opens there.
    let other = sessions.addTab(for: target)
    view.onCmdClickFile?("slow.rb")
    sessions.closeTab(tab.id, for: target)
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertNotEqual(opened(), "slow.rb", "a closed pane's click opened a preview")
    XCTAssertNotNil(sessions.tab(other.id, for: target))
  }

  /// `HostFiles` whose `slow.rb` takes half a second to answer.
  private struct SlowHostFiles: FileProviding {
    let inner: HostFiles
    var context: FileContext { inner.context }
    func list() async throws -> CommandResult { try await inner.list() }
    func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
      if path == "slow.rb" { try await Task.sleep(for: .milliseconds(500)) }
      return try await inner.read(path: path, symlinks: symlinks, maxBytes: maxBytes)
    }
    func resolve(path: String) async throws -> String { try await inner.resolve(path: path) }
    func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
      -> FileWatchHandle?
    { nil }
  }

  /// A root recorded with a trailing slash, or a link with a doubled one, still resolves inside
  /// the workroom: `standardized` keeps `//`, and the host reads `/src/a.rb` as an absolute path.
  func testARemoteLinkSurvivesDoubledAndTrailingSlashes() {
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "src/a.rb", cwd: nil, root: "/repo/").map(\.path),
      ["src/a.rb"])
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "/repo//src/a.rb", cwd: nil, root: "/repo").map(
        \.path), ["src/a.rb"])
    XCTAssertEqual(
      TerminalLinkOpener.remoteCandidates(for: "a.rb", cwd: "/repo//lib/", root: "/repo").map(
        \.path), ["lib/a.rb"])
  }

}

/// A remote host's file service for the remote-pane tests (#254): `files` by workroom-relative
/// path, reads capped as the agent caps them. Shared with `RemotePaneFooterTests`.
struct HostFiles: FileProviding {
  let context: FileContext
  let files: [String: Data]
  /// Paths whose read or resolve fails with this error, before `files` is consulted.
  var failing: [String: Error] = [:]
  /// What `resolve` answers, by the path it is sent. Anything else is not found.
  var resolved: [String: String] = [:]

  func list() async throws -> CommandResult {
    CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
  }
  func read(path: String, symlinks: FileSymlinkPolicy, maxBytes: Int) async throws -> Data {
    // The real agent refuses these before it opens anything (`vcs::relative`).
    if path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
      $0 == ".." || $0 == "." || $0.isEmpty
    }) {
      XCTFail("a read was sent \(path)")
      throw FileServiceError.failed("invalid relative file path")
    }
    if let error = failing[path] { throw error }
    guard let data = files[path] else { throw FileServiceError.notFound(path) }
    guard data.count <= maxBytes else { throw FileServiceError.tooLarge }
    return data
  }
  func resolve(path: String) async throws -> String {
    if let error = failing[path] { throw error }
    guard let resolved = resolved[path] else { throw FileServiceError.notFound(path) }
    return resolved
  }
  func watch(root: String, onEvent: @escaping @Sendable (FileWatchEvent) -> Void) async throws
    -> FileWatchHandle?
  { nil }
}
