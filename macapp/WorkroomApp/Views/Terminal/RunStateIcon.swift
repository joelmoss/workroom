import DesignSystem
import SwiftUI

/// A run tab's run-state icon: green play while running, a warning spinner while stopping, dim play
/// once it exits, and a red octagon if it failed (#7, #79). Failure is carried by both the glyph
/// and the colour, so it survives red/green colourblindness. One spec for the pane tab strip's chip
/// and the tab's Open section row (#819), so the two can't drift. Its slot keeps one size across
/// states.
struct RunStateIcon: View {
  let state: TabRunState
  @Environment(\.themeTokens) private var tokens

  /// The word for `state` in help and accessibility text.
  nonisolated static func label(_ state: TabRunState) -> String {
    switch state {
    case .running: "running"
    case .stopping: "stopping"
    case .stopped: "stopped"
    case .failed: "failed"
    }
  }

  /// `state`'s glyph, which a workroom tab's run mark (`WorkroomRunMark`) draws too.
  nonisolated static func glyph(_ state: TabRunState) -> String {
    switch state {
    case .running, .stopped: "play.circle.fill"
    case .stopping: "stop.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  /// `state`'s colour in `tokens`.
  static func color(_ state: TabRunState, in tokens: ThemeTokens) -> Color {
    switch state {
    case .running: tokens.success
    case .stopping: tokens.warning
    case .stopped: tokens.fgMuted
    case .failed: tokens.failure
    }
  }

  /// The glyph's size.
  static let glyphFont = Font.system(size: 10)

  var body: some View {
    let color = Self.color(state, in: tokens)
    Group {
      if state == .stopping {
        ProgressView().controlSize(.mini).tint(color)
      } else {
        Image(systemName: Self.glyph(state))
          .font(Self.glyphFont)
          .foregroundStyle(color)
      }
    }
    .frame(width: 12, height: 12)
    .help("Run command \(Self.label(state))")
  }
}
