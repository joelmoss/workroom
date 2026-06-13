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

  /// The filesystem path a link refers to, or nil if it's a web URL we don't open ourselves.
  static func filePath(from link: String) -> String? {
    if passthroughSchemes.contains(where: { link.hasPrefix($0) }) { return nil }
    if link.hasPrefix("file:") { return URL(string: link)?.path }
    return link
  }

  /// Resolve `path` (absolute, ~-relative, or cwd-relative) to an absolute path. Returns nil
  /// for a relative path when the working directory is unknown.
  static func absolutePath(for path: String, cwd: String?) -> String? {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
    guard let cwd else { return nil }
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
  private static func openFile(_ file: ResolvedFile) {
    let editorBundleID = Defaults[.filePathEditor]
    let installed =
      !editorBundleID.isEmpty
      && NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorBundleID) != nil
    let zedCLI = (installed && editorBundleID == EditorBundleID.zed) ? zedCLIPath() : nil
    let invocation = launchInvocation(
      file: file, editorBundleID: editorBundleID, editorInstalled: installed, zedCLIPath: zedCLI)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: invocation.executable)
    task.arguments = invocation.arguments
    do { try task.run() } catch { NSLog("Workroom: failed to open \(file.path): \(error)") }
  }

  /// The command to launch for `file`: an editor-specific invocation that seeks to `file.line` when
  /// one was parsed and the chosen editor is installed and can seek; otherwise `/usr/bin/open` with
  /// `openArguments` (the file's default app, or `-b <bundleID>` opened at the top).
  ///
  /// `editorInstalled` / `zedCLIPath` are resolved by the caller (Launch Services / filesystem
  /// lookups) and injected, so this stays a pure, unit-testable mapping.
  static func launchInvocation(
    file: ResolvedFile, editorBundleID: String?, editorInstalled: Bool, zedCLIPath: String?
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

  /// VS Code's documented open-at-position URL: `vscode://file/<path>:<line>[:<col>]`. The path is
  /// percent-encoded (keeping `/`); the `:line[:col]` suffix is literal.
  static func vscodeFileURL(path: String, line: Int, column: Int?) -> String {
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    let position = column.map { ":\(line):\($0)" } ?? ":\(line)"
    return "vscode://file\(encoded)\(position)"
  }

  /// Zed CLI positional argument: `<path>:<line>[:<col>]`.
  static func zedPositionArgument(path: String, line: Int, column: Int?) -> String {
    column.map { "\(path):\(line):\($0)" } ?? "\(path):\(line)"
  }

  /// Zed's bundled CLI helper (`Zed.app/Contents/MacOS/cli`) — the same binary the `zed` PATH
  /// command symlinks to. Invoked by absolute path so line-seeking works without the CLI on PATH.
  private static func zedCLIPath() -> String? {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorBundleID.zed)
    else { return nil }
    let cli = app.appendingPathComponent("Contents/MacOS/cli").path
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
  static func openFilePath(_ path: String, cwd: String?) {
    guard let resolved = resolveExistingFile(path, cwd: cwd) else { return }
    openFile(resolved)
  }

  /// Does `word` resolve to an existing file? Drives the ⌘-hover pointing-hand cursor affordance.
  static func resolvesToFile(_ word: String, cwd: String?) -> Bool {
    resolveExistingFile(word, cwd: cwd) != nil
  }

  /// Handle libghostty's `GHOSTTY_ACTION_OPEN_URL`: open local files/paths in the configured editor,
  /// web URLs via `NSWorkspace`. Returns true (we are the apprt — always handle, since there's no
  /// engine-side fallback).
  static func handleOpenURL(_ url: URL, cwd: String?) -> Bool {
    if let resolved = resolveLocalFile(from: url, cwd: cwd) {
      openFile(resolved)
    } else {
      NSWorkspace.shared.open(url)
    }
    return true
  }

  /// Resolve `word` (absolute, ~-relative, or cwd-relative) to an existing, non-passthrough file.
  /// Probes the literal first, then each decoration-stripped candidate (see `pathCandidates`),
  /// returning the first that exists on disk along with any line/column its candidate carried.
  private static func resolveExistingFile(_ word: String, cwd: String?) -> ResolvedFile? {
    guard let path = filePath(from: word) else { return nil }
    for candidate in pathCandidates(from: path) {
      if let abs = absolutePath(for: candidate.path, cwd: cwd),
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

  /// A resolved local file from a libghostty open-URL, or nil for a real (schemed) web URL.
  private static func resolveLocalFile(from url: URL, cwd: String?) -> ResolvedFile? {
    if url.isFileURL {
      let path = url.path
      return FileManager.default.fileExists(atPath: path)
        ? ResolvedFile(path: path, line: nil, column: nil) : nil
    }
    guard url.scheme == nil else { return nil }  // http/https/etc. → not a local file
    return resolveExistingFile(
      url.absoluteString.removingPercentEncoding ?? url.absoluteString, cwd: cwd)
  }

}
