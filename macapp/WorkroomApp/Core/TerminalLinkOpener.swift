import AppKit
import Defaults

/// ⌘-clicking a *file path* in a terminal opens it in the editor chosen in the "Open File Paths In"
/// menu — by default the file's default app (`open <path>`), or a specific editor
/// (`open -b <bundleID> <path>`). A trailing `:line[:col]` (compiler/Rails style) seeks to that
/// line in editors that support it (VS Code, Zed, Xcode); other editors open the file at the top.
/// Web URLs open via `NSWorkspace`. Driven by `GhosttySurfaceView`'s ⌘-click (for bare paths) and
/// libghostty's open-URL action; relative paths resolve against the surface's
/// `GHOSTTY_ACTION_PWD`-tracked cwd (see plan CMT-1).
enum TerminalLinkOpener {
  /// Web URL schemes we leave to the browser/mail handler (not treated as file paths).
  private static let passthroughSchemes = [
    "http://", "https://", "ftp://", "ssh://", "git://",
    "mailto:", "tel:", "magnet:", "ipfs://", "ipns://", "gemini://", "gopher://", "news:",
  ]

  /// The filesystem path a link refers to, or nil if it's a URL we don't open ourselves.
  ///
  /// Both ⌘-click entry points funnel through here (the bare word via `resolvesToFile`, the
  /// libghostty link via `resolveLocalFile`), so this is the one place a URL can be kept away from
  /// the filesystem — and it has to be, because a link that reaches `resolveExistingFile` is joined
  /// onto the cwd, and `NSString.appendingPathComponent` collapses `//`. A repo that ships
  /// `HTTPS:/example.com/x.command` would otherwise capture a click on `HTTPS://example.com/x.command`
  /// and hand a local executable to `/usr/bin/open`. Hence the scheme match is case-INSENSITIVE (the
  /// list is lowercase; `HTTPS://` is the same URL), and `looksLikeURL` catches every other scheme —
  /// the list can only ever name the ones we thought of.
  static func filePath(from link: String) -> String? {
    let lower = link.lowercased()
    if passthroughSchemes.contains(where: { lower.hasPrefix($0) }) { return nil }
    if lower.hasPrefix("file:") { return URL(string: link)?.path }
    if looksLikeURL(link) { return nil }
    return link
  }

  /// Does `link` lead with a URL scheme rather than a path? True when it starts `scheme:` and that
  /// colon is **not** followed by a digit.
  ///
  /// The digit is the whole test, because the only legitimate `word:` form in terminal output is a
  /// `:line[:col]` decoration — `user.rb:5`, `Gemfile:12`, `main.go:10:3`. Anything else after the
  /// colon is a URL body, whether it carries an authority (`https://…`, and every scheme the
  /// passthrough list above does not name) or is opaque (`javascript:payload.command`, `data:…`).
  /// Both shapes matter: neither is a path, and letting either through means the link gets joined
  /// onto the cwd, where a repo-controlled file of that exact name captures the click.
  ///
  /// One deliberate loss: a real relative path whose first segment holds a colon not followed by a
  /// digit (`a:b/file.rb`) now reads as a URL. That shape is rare, libghostty's own link regex does
  /// not match it either, and treating it as a path is what reopens the hole.
  static func looksLikeURL(_ link: String) -> Bool {
    link.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:(?![0-9])", options: .regularExpression) != nil
  }

  /// Resolve `path` (absolute, ~-relative, or cwd-relative) to an absolute path. Returns nil for a
  /// relative path when the working directory is unknown — or is itself relative, which is the same
  /// thing: `lastKnownCwd` is whatever OSC 7 reported and is never validated, and an empty or
  /// relative cwd would leave the result relative. That matters past mere correctness, because the
  /// result becomes an argv element: a file named `--locale=en` reached as `<abs cwd>/--locale=en` is
  /// a path, but reached bare it is a flag the editor CLI would parse.
  static func absolutePath(for path: String, cwd: String?) -> String? {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
    guard let cwd, cwd.hasPrefix("/") else { return nil }
    return (cwd as NSString).appendingPathComponent(path)
  }

  /// An existing file plus any 1-based line/column parsed from a `file:line[:col]` decoration.
  struct ResolvedFile: Equatable {
    let path: String
    let line: Int?
    let column: Int?
  }

  /// Bundle ids of the editors the ⌘-click picker offers (see `ExternalEditor.supported`). Only
  /// these can be driven to a specific line; any other choice opens the file at the top.
  private enum EditorBundleID {
    static let vscode = "com.microsoft.VSCode"
    static let zed = "dev.zed.Zed"
    static let xcode = "com.apple.dt.Xcode"
  }

  /// Open `file` — in the chosen editor (seeking to `file.line` when one was parsed and that editor
  /// can seek), or the file's default app (double-click-in-Finder behaviour) when none is set.
  /// Fire-and-forget.
  ///
  /// Security: the path is passed as a literal argv element / percent-encoded URL — never handed to
  /// a shell — so a maliciously-named file (e.g. `a$(touch x).txt`, which filenames may legally
  /// contain) can't be re-parsed into a command. We use the `open` CLI rather than
  /// `NSWorkspace.open(_:)` because the latter returns a bare `-50` for some files.
  private static func openFile(_ file: ResolvedFile, project: String? = nil) {
    let editorBundleID = Defaults[.filePathEditor]
    let installed =
      !editorBundleID.isEmpty
      && NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorBundleID) != nil
    let zedCLI = (installed && editorBundleID == EditorBundleID.zed) ? zedCLIPath() : nil
    let vscodeCLI = (installed && editorBundleID == EditorBundleID.vscode) ? vscodeCLIPath() : nil
    let invocations = launchInvocations(
      file: file, project: project, editorBundleID: editorBundleID, editorInstalled: installed,
      vscodeCLIPath: vscodeCLI, zedCLIPath: zedCLI)
    for invocation in invocations {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: invocation.executable)
      task.arguments = invocation.arguments
      do { try task.run() } catch { NSLog("Workroom: failed to open \(file.path): \(error)") }
    }
  }

  /// The launch plan for opening `file`, optionally **inside** `project` (the workroom directory).
  ///
  /// With a `project` and a folder-capable editor CLI, we open the **workroom folder + the file in
  /// one window** so the file lands in (or focuses) the workroom's window instead of whatever editor
  /// window was frontmost — and the editor reuses an already-open folder window rather than
  /// duplicating it. Support varies by editor:
  ///   • VS Code / Zed — one CLI call opens the folder and seeks to the file's line.
  ///   • Xcode — `xed --line` works only on a lone file, so it's two calls: open the folder *first*
  ///     (so the file attaches to that window), then the file.
  /// Falls back to the plain file-only `launchInvocation` when there's no project, no chosen editor,
  /// the editor's CLI is missing, or it's the file's default app (which has no folder concept).
  static func launchInvocations(
    file: ResolvedFile, project: String?, editorBundleID: String?, editorInstalled: Bool,
    vscodeCLIPath: String?, zedCLIPath: String?
  ) -> [(executable: String, arguments: [String])] {
    func fileOnly() -> [(executable: String, arguments: [String])] {
      [
        launchInvocation(
          file: file, editorBundleID: editorBundleID, editorInstalled: editorInstalled,
          vscodeCLIPath: vscodeCLIPath, zedCLIPath: zedCLIPath)
      ]
    }
    guard let project, let id = editorBundleID, !id.isEmpty, editorInstalled else {
      return fileOnly()
    }
    switch id {
    case EditorBundleID.vscode:
      if let cli = vscodeCLIPath { return [(cli, [project, "--goto", positionSuffixed(file)])] }
    case EditorBundleID.zed:
      if let cli = zedCLIPath { return [(cli, [project, positionSuffixed(file)])] }
    case EditorBundleID.xcode:
      let fileArgs = file.line.map { ["--line", String($0), file.path] } ?? [file.path]
      return [("/usr/bin/xed", [project]), ("/usr/bin/xed", fileArgs)]
    default:
      break
    }
    // Chosen editor can't be driven to a folder (CLI missing / unknown) → at least open the file.
    return fileOnly()
  }

  /// The command to launch for `file`: an editor-specific invocation that seeks to `file.line` when
  /// one was parsed and the chosen editor is installed and can seek; otherwise `/usr/bin/open` with
  /// `openArguments` (the file's default app, or `-b <bundleID>` opened at the top).
  ///
  /// `editorInstalled` / `vscodeCLIPath` / `zedCLIPath` are resolved by the caller (Launch Services /
  /// filesystem lookups) and injected, so this stays a pure, unit-testable mapping.
  static func launchInvocation(
    file: ResolvedFile, editorBundleID: String?, editorInstalled: Bool, vscodeCLIPath: String?,
    zedCLIPath: String?
  ) -> (executable: String, arguments: [String]) {
    let fallback = (
      executable: "/usr/bin/open",
      arguments: openArguments(path: file.path, editorBundleID: editorBundleID)
    )
    guard let line = file.line, let id = editorBundleID, !id.isEmpty, editorInstalled else {
      return fallback
    }
    switch id {
    case EditorBundleID.vscode:
      // `code --goto` first, the `vscode://` URL only when the bundled CLI is missing. The URL was
      // reported not to seek (the file opens at the top); `--goto` is the same flag the
      // project-aware branch above already ships and seeks with, so prefer the path we know works.
      if let vscodeCLIPath { return (vscodeCLIPath, ["--goto", positionSuffixed(file)]) }
      return ("/usr/bin/open", [vscodeFileURL(path: file.path, line: line, column: file.column)])
    case EditorBundleID.zed:
      guard let zedCLIPath else { return fallback }  // CLI helper missing → open at the top
      return (zedCLIPath, [zedPositionArgument(path: file.path, line: line, column: file.column)])
    case EditorBundleID.xcode:
      return ("/usr/bin/xed", ["--line", String(line), file.path])  // xed has no column option
    default:
      return fallback
    }
  }

  /// VS Code's documented open-at-position URL: `vscode://file/<path>:<line>:<col>`. The path is
  /// percent-encoded (keeping `/`); the `:line:col` suffix is literal. Only used when the bundled
  /// `code` CLI is missing — see `launchInvocation` for why the CLI is preferred. The column is always
  /// written, defaulting to 1, to match the documented form; whether a `:line`-only URL would seek is
  /// untested, since this branch stopped running on any machine that has VS Code installed.
  static func vscodeFileURL(path: String, line: Int, column: Int?) -> String {
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    return "vscode://file\(encoded):\(line):\(column ?? 1)"
  }

  /// Zed CLI positional argument: `<path>:<line>[:<col>]`.
  static func zedPositionArgument(path: String, line: Int, column: Int?) -> String {
    column.map { "\(path):\(line):\($0)" } ?? "\(path):\(line)"
  }

  /// `path`, `path:line`, or `path:line:col` — the position-suffix form that VS Code's `--goto` and
  /// Zed's CLI both accept. Just the path when no line was parsed.
  static func positionSuffixed(_ file: ResolvedFile) -> String {
    guard let line = file.line else { return file.path }
    return file.column.map { "\(file.path):\(line):\($0)" } ?? "\(file.path):\(line)"
  }

  /// Zed's bundled CLI helper (`Zed.app/Contents/MacOS/cli`) — the same binary the `zed` PATH
  /// command symlinks to. Invoked by absolute path so line-seeking works without the CLI on PATH.
  private static func zedCLIPath() -> String? {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorBundleID.zed)
    else { return nil }
    let cli = app.appendingPathComponent("Contents/MacOS/cli").path
    return FileManager.default.isExecutableFile(atPath: cli) ? cli : nil
  }

  /// VS Code's bundled CLI (`Visual Studio Code.app/Contents/Resources/app/bin/code`) — the same
  /// binary the `code` PATH command points at. Lets us open a folder + file (and seek) in one call;
  /// the `vscode://` URL scheme can't target a folder. Invoked by absolute path, no PATH needed.
  private static func vscodeCLIPath() -> String? {
    guard
      let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorBundleID.vscode)
    else { return nil }
    let cli = app.appendingPathComponent("Contents/Resources/app/bin/code").path
    return FileManager.default.isExecutableFile(atPath: cli) ? cli : nil
  }

  /// `open` argv: `-b <bundleID> <path>` when `editorBundleID` names an installed app, else just
  /// `<path>` (the file's default app). Falls back to the default app if the chosen editor was
  /// since uninstalled. The bundle id comes from our own picker and `path` is a literal argv
  /// element, so neither is shell-interpreted.
  static func openArguments(path: String, editorBundleID: String?) -> [String] {
    if let id = editorBundleID, !id.isEmpty,
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    {
      return ["-b", id, path]
    }
    return [path]
  }

  // MARK: libghostty entry points (cwd from GHOSTTY_ACTION_PWD — CMT-1)

  /// ⌘-clicked a bare word (from `ghostty_surface_quicklook_word`) that resolves to a real file →
  /// open it in the configured editor. No-op if it doesn't resolve (e.g. cwd unknown for a relative
  /// path under ssh/tmux — see plan CMT-1).
  static func handleCmdClickFile(_ word: String, cwd: String?) {
    openFilePath(word, cwd: cwd)
  }

  /// Open the file at `path` (absolute or `cwd`-relative) in the configured editor / default app.
  /// The plain-click entry point — used by the Changes panel (a single click), where there's no
  /// modifier involved; the terminal's ⌘-click handler delegates here too.
  ///
  /// Pass `project` (the workroom directory) to open the file *inside that folder's editor window*
  /// rather than whatever window is frontmost — see `launchInvocations`. The Changes panel sets it;
  /// terminal ⌘-click leaves it nil (its tracked cwd isn't necessarily the workroom root).
  static func openFilePath(_ path: String, cwd: String?, project: String? = nil) {
    guard let resolved = resolveExistingFile(path, cwd: cwd) else { return }
    openFile(resolved, project: project)
  }

  /// Does `word` resolve to an existing file? Drives the ⌘-hover pointing-hand cursor affordance.
  static func resolvesToFile(_ word: String, cwd: String?) -> Bool {
    resolveExistingFile(word, cwd: cwd) != nil
  }

  /// Handle libghostty's `GHOSTTY_ACTION_OPEN_URL`. Three outcomes: a URL whose scheme an installed
  /// app claims goes to that app; anything else that resolves to a file on disk opens in the
  /// configured editor; text that is neither is dropped **silently** (see `isSystemHandledURL`).
  /// Returns true (we are the apprt — always handle, since there's no engine-side fallback).
  ///
  /// The scheme test runs FIRST, and that order is load-bearing: a real URL must never be offered to
  /// filesystem resolution, or a repo-controlled file can shadow it (see `resolveLocalFile`).
  static func handleOpenURL(_ url: URL, cwd: String?) -> Bool {
    if isSystemHandledURL(url) {
      NSWorkspace.shared.open(url)
    } else if let resolved = resolveLocalFile(from: url, cwd: cwd) {
      openFile(resolved)
    } else {
      // Silent for the user (the text was never a link), but not silent in the log: a dropped click
      // is otherwise indistinguishable from a broken app, and there is no other diagnostic.
      NSLog("Workroom: ignoring unopenable terminal link %@", url.absoluteString)
    }
    return true
  }

  /// Does an installed app actually claim `url`'s scheme (`https:`, `mailto:`, `vscode:`, …)?
  ///
  /// Only then may it reach `NSWorkspace.open`; everything else is a silent no-op. libghostty's link
  /// regex reports plenty of text that isn't an openable link — a Rails backtrace frame
  /// (`hue/app/views/…/show.rb:1:in`), a bare URL *path* (`/rails/active_storage/disk/…`), a bare
  /// `file:line` whose "scheme" is really a filename (`user.rb:5`) — and once that text fails to
  /// resolve on disk, handing it to LaunchServices raises a modal Finder alert ("The application
  /// can't be opened. -50") instead of doing nothing. Asking LaunchServices whether anything claims
  /// the scheme is the same question the alert answers, minus the alert. `file:` is excluded outright
  /// — it is a local file, which `resolveLocalFile` owns.
  ///
  /// This is a dispatch test, not a trust decision: LaunchServices reports the *default handler*, it
  /// does not vet the URL. An action-bearing scheme (`shortcuts://run-shortcut?…`) still reaches its
  /// app with the link's own parameters, exactly as it did before this predicate existed.
  static func isSystemHandledURL(_ url: URL) -> Bool {
    guard url.scheme != nil, !url.isFileURL else { return false }
    return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
  }

  /// Resolve `word` (absolute, ~-relative, or cwd-relative) to an existing, non-passthrough file.
  /// Probes the literal first, then each decoration-stripped candidate (see `pathCandidates`),
  /// returning the first that exists on disk along with any line/column its candidate carried.
  private static func resolveExistingFile(_ word: String, cwd: String?) -> ResolvedFile? {
    guard let path = filePath(from: word) else { return nil }
    for candidate in pathCandidates(from: path) {
      // `abs.hasPrefix("/")` enforces the absolute-path invariant at the one place every resolution
      // leaves through, rather than trusting each producer: the result becomes an argv element, and a
      // relative one is a FLAG to an editor CLI, not a filename. `absolutePath` already refuses a
      // relative cwd; this also catches `~nobody/x`, which `expandingTildeInPath` leaves as-is.
      if let abs = absolutePath(for: candidate.path, cwd: cwd), abs.hasPrefix("/"),
        FileManager.default.fileExists(atPath: abs)
      {
        return ResolvedFile(path: abs, line: candidate.line, column: candidate.column)
      }
    }
    return nil
  }

  /// A file-path candidate to probe, carrying any line/column parsed from a stripped `:line[:col]`.
  struct PathCandidate: Equatable {
    let path: String
    let line: Int?
    let column: Int?
  }

  /// Candidate file paths to probe for `path`, in priority order: the literal first, then with the
  /// "decorations" terminals routinely render onto a path stripped — a trailing `.` (sentence
  /// punctuation that ran up against the path) and/or a `:line`/`:line:col` suffix (compiler- and
  /// Rails-style). The candidate whose suffix was stripped carries the parsed line/column so the
  /// editor can seek there. Probing the literal first means a file legitimately named with a `:` or
  /// a trailing `.` still resolves before those characters are treated as decoration.
  static func pathCandidates(from path: String) -> [PathCandidate] {
    let position = lineColumn(in: path)
    var seen = Set<String>()
    var result: [PathCandidate] = []
    func add(_ candidatePath: String, line: Int?, column: Int?) {
      guard !candidatePath.isEmpty, seen.insert(candidatePath).inserted else { return }
      result.append(PathCandidate(path: candidatePath, line: line, column: column))
    }
    add(path, line: nil, column: nil)  // literal, undecorated
    add(position.bare, line: position.line, column: position.column)  // :line[:col] stripped
    add(strippingTrailingDots(path), line: nil, column: nil)  // trailing "." stripped
    add(strippingTrailingDots(position.bare), line: position.line, column: position.column)
    return result
  }

  /// Parse a trailing `file:line[:col]` suffix into the bare path plus 1-based line/column: split at
  /// the first `:` followed by a digit, then read the line digits and an optional `:col`. Anything
  /// past the line number that isn't `:<digits>` is ignored (e.g. Rails' `file:line:in '...'`
  /// backtraces). Returns `(path, nil, nil)` when there's no such suffix.
  private static func lineColumn(in path: String) -> (bare: String, line: Int?, column: Int?) {
    guard let colon = path.range(of: ":[0-9]", options: .regularExpression) else {
      return (path, nil, nil)
    }
    let bare = String(path[..<colon.lowerBound])
    let after = path[path.index(after: colon.lowerBound)...]  // starts at the first digit
    let lineDigits = after.prefix { $0.isASCII && $0.isNumber }
    var column: Int?
    let remainder = after.dropFirst(lineDigits.count)
    if remainder.hasPrefix(":") {
      column = Int(remainder.dropFirst().prefix { $0.isASCII && $0.isNumber })
    }
    return (bare, Int(lineDigits), column)
  }

  /// Drop any trailing `.` characters (sentence punctuation that ran up against the path).
  private static func strippingTrailingDots(_ path: String) -> String {
    var result = path
    while result.hasSuffix(".") { result.removeLast() }
    return result
  }

  /// A resolved local file from a libghostty open-URL, or nil when the link is a URL rather than a
  /// path. `internal`, not `private`, so the tests can drive this path without launching an editor.
  ///
  /// Two filters stand between a link and the filesystem, and `URL.scheme` is deliberately not one of
  /// them: a bare `file:line` decoration parses *as* a scheme, because a filename is a legal scheme
  /// name (`URL(string: "user.rb:5")?.scheme == "user.rb"`, likewise `main.go:10:3`, `Gemfile:12`).
  /// Rejecting on `URL.scheme != nil` wrote every link of that shape off as a web URL and resolved
  /// nothing, so ⌘-clicking it opened nothing.
  ///
  /// What does filter, in order:
  ///   1. `handleOpenURL` runs `isSystemHandledURL` first, so a scheme an installed app claims never
  ///      arrives here at all.
  ///   2. `filePath(from:)`, inside `resolveExistingFile`, rejects the passthrough schemes and
  ///      anything else that leads with a scheme — see there for why that is the load-bearing one.
  ///
  /// The `file:` branch requires an ABSOLUTE path: `URL(string: "file:-b")?.path` is `"-b"`, which
  /// would otherwise be probed against the app's own process cwd (`/` under Finder, the repo under
  /// `make app-run` — so which file opens depends on how the app was launched) and then handed to
  /// `/usr/bin/open` as its `-b` flag rather than as a filename.
  static func resolveLocalFile(from url: URL, cwd: String?) -> ResolvedFile? {
    if url.isFileURL {
      let path = url.path
      guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
      return ResolvedFile(path: path, line: nil, column: nil)
    }
    let link = url.absoluteString
    return resolveExistingFile(link.removingPercentEncoding ?? link, cwd: cwd)
  }

}
