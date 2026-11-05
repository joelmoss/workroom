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

  /// Cut `raw` down to a UTF-8 tail *before* any grapheme work happens (WORKROOM-3S). Callers hand
  /// this whole surfaces — `readCommandRegion` reads SCREEN (scrollback + viewport) and
  /// `readFullSurface` reads the scrollback on purpose — while every step in `tidy` below (`split`,
  /// `utf8.count`, `reversed()`) is a Swift **Character** walk, i.e. Unicode grapheme breaking over
  /// megabytes, on the main thread inside libghostty's command-finished callback. A 2s+ AppHang was
  /// reported from exactly that path.
  ///
  /// Both steps work on BYTES, so they cost a scan and a memcpy rather than grapheme breaking:
  ///
  /// 1. **Drop the trailing blank lines first.** They are what `tidy` would drop anyway, and they
  ///    can be arbitrarily long — a screen read includes every empty cell below the cursor. Cutting
  ///    to a byte tail before dropping them would let a long blank run swallow the whole budget and
  ///    hand `tidy` nothing but whitespace, which returns `nil` and silently skips the diagnosis for
  ///    a command that did print an error. Blank means ASCII space or tab: the Unicode-whitespace
  ///    reading of "blank" stays in `tidy`, which re-checks the (now small) tail.
  /// 2. **Then keep a byte tail of 4x the cap**, skipping leading UTF-8 continuation bytes so the
  ///    slice starts on a scalar boundary (no U+FFFD). The cap in `tidy` returns at most `maxBytes`
  ///    from the END, so the 4x slack leaves the answer unchanged for real terminal output. It is
  ///    not a proof of equality for every input: re-decoding from a byte offset re-segments
  ///    graphemes, so a >48KB unbroken run of characters that pair with their neighbours (regional
  ///    indicators) could pair differently than it would have. No terminal produces that.
  private static func bounded(_ raw: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    let utf8 = raw.utf8

    var end = utf8.endIndex
    while true {
      let lineStart = utf8[..<end].lastIndex(of: UInt8(ascii: "\n")).map { utf8.index(after: $0) }
      let blank = isBlankLine(raw, from: lineStart ?? utf8.startIndex, to: end)
      guard blank, let lineStart else { break }
      end = utf8.index(before: lineStart)  // the "\n" that ended the line above
    }

    let (scaled, overflowed) = maxBytes.multipliedReportingOverflow(by: 4)
    let budget = overflowed ? Int.max : scaled
    let body = utf8[..<end]
    if end == utf8.endIndex, body.count <= budget { return raw }
    guard body.count > budget else { return String(decoding: body, as: UTF8.self) }
    return String(decoding: body.suffix(budget).drop { $0 & 0xC0 == 0x80 }, as: UTF8.self)
  }

  /// Is `raw[start..<end]` — one line, newline excluded — blank the way `tidy` means it?
  ///
  /// Bytes first, and any ASCII byte that is neither space nor tab settles it. That covers every
  /// ordinary line at the cost of one early-exit scan. A line whose ASCII is all blank but which
  /// carries non-ASCII falls through to the scalar reading `tidy` itself applies, where
  /// `.whitespaces` also means NBSP and its relatives: judging those by ASCII alone would read a
  /// long run of NBSP-only lines as content, let it eat the whole byte budget, and leave `tidy`
  /// trimming it away to nothing — losing the error above it, which is exactly the loss the byte
  /// scan exists to prevent.
  private static func isBlankLine(_ raw: String, from start: String.Index, to end: String.Index)
    -> Bool
  {
    var sawNonASCII = false
    for byte in raw.utf8[start..<end] {
      if byte >= 0x80 {
        sawNonASCII = true
      } else if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t") {
        return false
      }
    }
    guard sawNonASCII else { return true }
    return raw.unicodeScalars[start..<end].allSatisfy { CharacterSet.whitespaces.contains($0) }
  }

  /// Post-process raw rendered text (from `ghostty_surface_read_text`) before handing it to the
  /// agent:
  /// - drop trailing blank lines (a screen selection includes the empty cells below the cursor),
  /// - cap to `maxBytes`, keeping the **tail** — a command's error and stack trace live at the end,
  /// - return `nil` when nothing meaningful remains, so the caller skips a useless diagnosis.
  /// The cap keeps the largest tail of **whole characters** that fits in `maxBytes`, so it never
  /// splits a multi-byte character (no U+FFFD) and the result's UTF-8 length is a true bound.
  static func tidy(_ raw: String, maxBytes: Int = 16_384) -> String? {
    var lines = bounded(raw, maxBytes: maxBytes).split(
      separator: "\n", omittingEmptySubsequences: false)
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
