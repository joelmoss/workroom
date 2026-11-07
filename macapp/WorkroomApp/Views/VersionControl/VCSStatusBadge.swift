import DesignSystem
import SwiftUI
import WorkroomVCS

/// Maps a status semantic to a concrete color. Color is *additive* — the SF Symbol shape
/// already carries the meaning (so color-blind users and the issue-#43 window-blur dimming
/// don't lose the signal). Unknown/neutral stay muted (`.secondary`), never alarming.
extension VCSStatusPresentation.Semantic {
  @MainActor func color(_ tokens: ThemeTokens) -> Color {
    switch self {
    case .dirty: return tokens.warning
    case .conflict: return tokens.failure
    case .unknown: return tokens.fgMuted
    case .ciPass: return tokens.success
    case .ciFail: return tokens.failure
    case .ciRunning: return tokens.warning
    case .neutral: return tokens.fgMuted
    }
  }
}

extension VCSStatusPresentation {
  /// Tint for a leading identity glyph (the sidebar/tab house or workroom cube) that now carries the
  /// dirty/conflict signal in place of a separate status dot: orange when dirty, red on conflict,
  /// otherwise the default `.secondary` (clean/unknown read as no change).
  @MainActor static func iconTint(_ s: WorkroomStatus, _ tokens: ThemeTokens) -> Color {
    dot(s)?.semantic.color(tokens) ?? tokens.fgMuted
  }
}

/// A single aggregate status dot for a collapsed project row — the worst child status, so
/// collapsing a project doesn't hide the command-center signal. Nothing to show ⇒ renders
/// nothing.
struct VCSAggregateDot: View {
  let status: WorkroomStatus
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    if let dot = VCSStatusPresentation.dot(status) {
      Image(systemName: dot.symbol)
        .font(.system(size: 7))
        .foregroundStyle(dot.semantic.color(tokens))
        .accessibilityLabel("project \(dot.accessibility)")
        .help("Project: \(dot.accessibility)")
    }
  }
}
