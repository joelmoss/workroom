import DesignSystem
import SwiftUI

/// A workroom tab's title, as its title-bar chip and its Open section row both show it (#819): a
/// standalone terminal's program with its folder, else the project's or group's name, then a
/// workroom's own name after a slash. The accent marks unread activity. Each caller sets the font.
struct WorkroomTabTitle: View {
  let presentation: WorkroomTabPresentation
  let hasUnread: Bool
  /// The standalone terminal's folder, a size smaller than its program.
  let folderFont: Font
  /// The workroom's name at full strength, as on the focused chip, rather than secondary.
  var emphasizesWorkroom = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
      if let standalone = presentation.standaloneTitle {
        TerminalTitleLabel(title: standalone, folderFont: folderFont)
          .foregroundStyle(
            hasUnread ? tokens.accent : Color.primary,
            hasUnread ? tokens.accent.opacity(0.7) : tokens.fgMuted
          )
          .truncationMode(.middle)
      } else {
        Text(presentation.primaryLabel)
          .foregroundStyle(hasUnread ? tokens.accent : Color.primary)
      }
      if let workroom = presentation.workroomName {
        Text("/").foregroundStyle(.tertiary)
        Text(workroom).foregroundStyle(emphasizesWorkroom ? Color.primary : .secondary)
      }
    }
    .lineLimit(1)
    .truncationMode(.tail)
  }
}

/// A workroom tab's run-command mark (#7), as its chip and its Open section row show it: green
/// play while running, a red octagon once the last run failed (#79: a distinct glyph, not just a
/// red tint). Nothing once a run stops cleanly.
struct WorkroomRunMark: View {
  let run: WorkroomTabMarks.Run
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let running = run == .running
    Image(systemName: running ? "play.circle.fill" : "xmark.octagon.fill")
      .font(.system(size: 10))
      .foregroundStyle(running ? tokens.success : tokens.failure)
      .help(running ? "Run command running" : "Run command failed")
      .accessibilityLabel(running ? "run running" : "run failed")
  }
}
