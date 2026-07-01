import Foundation

/// Renders a diagnosis as dim ANSI text to write into the terminal output (issue #49, inline
/// presentation). Pure + unit-tested. The text is fed to the surface via
/// `ghostty_surface_write_buffer`, so it becomes real scrollback that scrolls with the output and
/// never covers the terminal — the actions live in the tab-chip popover instead.
enum AgentInlineRenderer {
  private static let faint = "\u{1b}[2m"
  private static let reset = "\u{1b}[0m"

  /// Strip control characters (ESC, CR/LF, etc.) from model-supplied text before it's written into
  /// the terminal — otherwise a crafted diagnosis could smuggle its own escape sequences into the
  /// display (prompt-injection's second-order cousin). Keeps printable characters incl. Unicode.
  static func sanitize(_ text: String) -> String {
    String(
      text.unicodeScalars.filter { scalar in
        // Drop C0 controls (< 0x20), DEL (0x7f), and C1 controls (0x80…0x9f).
        !(scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value))
      })
  }

  /// The ANSI block for a finished-diagnosis state, or nil for transient states that shouldn't be
  /// written to scrollback (loading — we inject only the final result; remote — the local diagnosis
  /// is suppressed). Framed with leading/trailing CRLF so it lands on its own lines below the output.
  static func ansi(for state: AgentBannerState) -> String? {
    switch state {
    case .ready(_, let diagnosis):
      var out = "\r\n" + line("✦ \(sanitize(diagnosis.summary))")
      if let fix = diagnosis.fixCommand { out += line("  fix: \(sanitize(fix))") }
      out += line("  actions: ✦ on the tab  ·  ⌥⇧D")
      return out
    case .failure(_, let kind):
      return "\r\n" + line("✦ \(AgentBannerViewModel.message(for: kind))")
    case .awaitingDiagnose:
      return "\r\n" + line("✦ command failed — press ⌥⇧D to diagnose")
    case .loading, .remoteCaveat:
      return nil
    }
  }

  private static func line(_ text: String) -> String { "\(faint)\(text)\(reset)\r\n" }
}
