import Foundation

/// Pure helpers for the inline terminal agent's capture path (issue #49). No libghostty here, so
/// the logic is unit-tested directly; the thin `ghostty_surface_*` shims live on `GhosttySurfaceView`.
enum TerminalCapture {
  /// Resolve a command's exit code. `ghostty_action_command_finished_s.exit_code` is an `Int16`
  /// that is `-1` when the shell did not report a status in OSC 133;D (zsh's payload-free `D`, and
  /// some `fish` paths). When the per-command code is absent, fall back to a known child-exit code
  /// (a run tab's supervisor, or a shell `exit`) if one was supplied. Returns `nil` when no code is
  /// known — the caller then skips diagnosis rather than guessing.
  static func resolveExitCode(commandFinished: Int16, childExited: Int32? = nil) -> Int32? {
    if commandFinished >= 0 { return Int32(commandFinished) }
    return childExited
  }

  /// Post-process raw rendered text (from `ghostty_surface_read_text`) before handing it to the
  /// agent:
  /// - drop trailing blank lines (a screen selection includes the empty cells below the cursor),
  /// - cap to `maxBytes`, keeping the **tail** — a command's error and stack trace live at the end,
  /// - return `nil` when nothing meaningful remains, so the caller skips a useless diagnosis.
  /// The cap keeps the largest tail of **whole characters** that fits in `maxBytes`, so it never
  /// splits a multi-byte character (no U+FFFD) and the result's UTF-8 length is a true bound.
  static func tidy(_ raw: String, maxBytes: Int = 16_384) -> String? {
    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    let joined = lines.joined(separator: "\n")
    if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    guard joined.utf8.count > maxBytes else { return joined }

    // Walk back from the end, accumulating whole characters until the next would overflow.
    var kept = 0
    var start = joined.endIndex
    for character in joined.reversed() {
      let size = String(character).utf8.count
      if kept + size > maxBytes { break }
      kept += size
      start = joined.index(before: start)
    }
    return start == joined.endIndex ? nil : String(joined[start...])
  }
}
