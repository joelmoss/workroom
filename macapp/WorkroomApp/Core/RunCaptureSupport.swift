import Foundation

/// Capturing a Run-feature command's output for the inline agent (issue #49, A1 + X3). Run-tab
/// commands `exec` over the shell, so they emit NO OSC 133 marks — the ad-hoc path (T2) misses them.
/// Instead the whole surface is the command's output, and the run supervisor prints a fixed trailer
/// in-band AFTER the command exits. Reading the surface only once that trailer has rendered closes
/// the race where the `.status` file (written out-of-band) lands before the last output lines paint.
enum RunCaptureSupport {
  /// Printed by `Resources/run-supervisor/supervisor.sh` after a natural child exit. In-band, so its
  /// presence in the rendered surface means all of the command's output has rendered (X3).
  static let exitTrailer = "Process exited. Press any key to close the terminal."

  /// Whether the supervisor's exit trailer has rendered yet — the signal that capture is safe.
  static func hasRenderedTrailer(_ surfaceText: String) -> Bool {
    surfaceText.contains(exitTrailer)
  }

  /// Extract the command's output from the full run-tab surface: everything before the exit trailer,
  /// with trailing blank lines trimmed and capped (via `TerminalCapture.tidy`). nil when empty.
  static func extractOutput(fromSurface surfaceText: String, maxBytes: Int = 65_536) -> String? {
    let body: String
    if let range = surfaceText.range(of: exitTrailer) {
      body = String(surfaceText[..<range.lowerBound])
    } else {
      body = surfaceText
    }
    return TerminalCapture.tidy(body, maxBytes: maxBytes)
  }
}
