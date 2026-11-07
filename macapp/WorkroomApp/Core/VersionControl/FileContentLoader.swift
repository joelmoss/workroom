import AppKit
import DesignSystem
import SyntaxHighlighting
import WorkroomVCS

/// Reads one working-tree file for `PlainFileViewer`: keyed by path, a stale read discarded,
/// classified into a `LoadState`, then upgraded with syntax highlighting off-main.
///
/// The viewer holds it as `@State`, so it lives exactly as long as the view's identity does: a pane
/// retargeted to another file keeps the same loader (and so the generation token below), and a tab
/// reopened gets a fresh one.
@MainActor
@Observable
final class FileContentLoader {
  /// A loaded file: its display lines (capped — see `lineCap`), the content the highlight parses
  /// (those lines rejoined, so a theme change recolours without re-reading the file), and whether
  /// the file was longer than `lineCap` and only the head is shown.
  struct Text: Equatable {
    let lines: [String]
    let content: String
    let truncated: Bool
  }

  /// The read outcome, classified purely from the file's bytes (no I/O) so the gating is
  /// unit-testable. `.text` carries the decoded UTF-8 string.
  enum Outcome: Equatable {
    case empty
    case binary
    case tooLarge
    case text(String)
  }

  /// Files at or over this size aren't loaded (open them in an editor instead). Comfortably above
  /// the 2 MB syntax-highlight cap, so a big-but-readable file still shows (plain).
  nonisolated static let maxBytes = 8 * 1024 * 1024
  /// Most lines rendered. Bounds the highlight work; the head is shown with a note past it.
  nonisolated static let lineCap = 5000

  private(set) var state: LoadState<Text> = .loading
  /// The themed, (optionally) syntax-highlighted content the `NSTextView` renders. Plain immediately
  /// on load, upgraded when highlighting arrives / the theme changes.
  private(set) var attributed = NSAttributedString()
  /// Bumped whenever `attributed` is replaced, so `CodeTextView` resets its text storage only then.
  private(set) var version = 0
  /// Bumped when a file finishes loading, so the highlight task (keyed on it) re-runs against the
  /// freshly loaded content without re-reading on every theme change.
  private(set) var loadToken = 0
  /// The path of whichever `.task(id:)` invocation most recently started a load at this
  /// view-identity slot — a generation token, held ALONGSIDE `Task.isCancelled` rather than
  /// instead of it. Retargeting the pane swaps the id value at a stable slot (the view instance is
  /// reused, not recreated), and cancellation delivery for that shape does not measure the same
  /// way everywhere: `AvatarView` measured `Task.isCancelled == false` throughout the outgoing
  /// invocation in the live app (2026-08-13), while `DiffViewer` measured it DELIVERED in a
  /// hosted-view harness (`DiffViewerStaleLoadTests`). The harness is not the app's view tree and
  /// the flag's delivery is an unspecified SwiftUI detail, so the flag is the guard the test proves
  /// and the token is the belt. The loader survives the slot being reused (it is the view's
  /// `@State`), so whichever invocation started LAST wins.
  @ObservationIgnored private var activePath: String?

  /// Read `path` under `directory` (or at `location`, when the file isn't on this Mac) and commit
  /// what it classifies as. Returns the displayed lines when a text file was committed, so the
  /// caller can feed find; nil for anything else, a stale read included.
  func load(
    path: String, directory: String, location: RepositoryLocation?, tokens: ThemeTokens,
    font: NSFont
  ) async -> [String]? {
    activePath = path
    state = .loading
    attributed = NSAttributedString()
    let outcome = await Self.loadOutcome(directory: directory, location: location, relative: path)
    // Stale-write guard (see `activePath`): a slow read of the file this pane USED to show must
    // never paint file A's text into file B's slot.
    guard !Task.isCancelled, activePath == path else { return nil }
    switch outcome {
    case .none: state = .failed("File unavailable")
    case .empty: state = .empty
    case .binary: state = .binary
    case .tooLarge: state = .tooLarge
    case .text(let full):
      var split = Self.splitLines(full)
      var truncated = false
      if split.count > Self.lineCap {
        split = Array(split.prefix(Self.lineCap))
        truncated = true
      }
      let content = split.joined(separator: "\n")
      // Show the content plain immediately; `applyHighlight` upgrades it with syntax colours.
      attributed = FileHighlightMapper.nsAttributedString(
        content: content, spans: [], tokens: tokens, font: font)
      version &+= 1
      state = .loaded(Text(lines: split, content: content, truncated: truncated))
      loadToken &+= 1
      return split
    }
    return nil
  }

  /// Build syntax highlighting for the loaded file, off-main and cancellable. Any miss (no grammar,
  /// parse failure, stale/cancelled) leaves the file rendering plain — highlighting can never block
  /// or break the viewer.
  func applyHighlight(path: String, tokens: ThemeTokens, font: NSFont) async {
    guard case .loaded(let text) = state, !text.content.isEmpty else { return }
    // Detect by path, then by the shebang on the first line — so an extension-less script
    // (`#!/usr/bin/env bash`) still highlights. No grammar ⇒ keep the plain (already-shown) string.
    guard let grammar = SyntaxLanguage.grammar(forPath: path, firstLine: text.lines.first)
    else { return }
    let source = text.content
    let highlighted = await FileHighlightMapper.highlighted(
      content: source, grammar: grammar, tokens: tokens, font: font)
    guard !Task.isCancelled, case .loaded(let current) = state, source == current.content,
      let highlighted
    else { return }
    attributed = highlighted
    version &+= 1
  }

  // MARK: Pure helpers (unit-tested)

  /// Read `relative` under `directory` through the file service and classify it, or `nil` when it
  /// cannot be shown (`.failed`).
  ///
  /// The read runs on whichever host holds the file, and CONTAINMENT is enforced there, on the opened
  /// descriptor: a committed symlink like `notes -> ~/.ssh/id_rsa` (the Files tree lists repo files)
  /// is refused rather than showing the target's contents, and a FIFO or a file swapped for a link
  /// mid-read cannot hang or escape. In-repo links are followed. This used to be a client-side
  /// path check followed by a separate open, which a remote host would have lost entirely.
  static func loadOutcome(
    directory: String, location supplied: RepositoryLocation? = nil, relative: String,
    router: RepositoryRouter = .shared
  ) async -> Outcome? {
    let resolved: RepositoryLocation? =
      if let supplied { supplied } else { try? await RepositoryLocation.local(directory) }
    guard let location = resolved else { return nil }
    do {
      let files = try await router.files(for: location)
      let data = try await files.read(
        path: relative, symlinks: .followWithinRoot, maxBytes: maxBytes)
      return classify(data: data)
    } catch FileServiceError.tooLarge {
      return .tooLarge
    } catch {
      return nil
    }
  }

  /// Classify a file's bytes into a render outcome. Empty → `.empty`; over `byteCap` → `.tooLarge`;
  /// a NUL byte in the first 8 KB or non-UTF-8 → `.binary`; else the decoded text.
  nonisolated static func classify(data: Data, byteCap: Int = maxBytes) -> Outcome {
    if data.isEmpty { return .empty }
    if data.count > byteCap { return .tooLarge }
    if data.prefix(8192).contains(0) { return .binary }
    guard let string = String(data: data, encoding: .utf8) else { return .binary }
    return .text(string)
  }

  /// Split into display lines, dropping the phantom empty line a trailing newline would add (so the
  /// line count matches an editor's and `FileHighlightMapper`'s).
  nonisolated static func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    return lines
  }
}
