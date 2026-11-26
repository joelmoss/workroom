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
        // Its terminal popped out into a window of its own (issue #172): the mark leads the
        // title, which goes secondary.
        if presentation.isPoppedOut { PoppedOutMark() }
        TerminalTitleLabel(title: standalone, folderFont: folderFont)
          .foregroundStyle(
            hasUnread ? tokens.accent : (presentation.isPoppedOut ? Color.secondary : .primary),
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
/// red tint). Nothing once a run stops cleanly. Its glyph and colour are the run tab's
/// (`RunStateIcon`).
struct WorkroomRunMark: View {
  let run: WorkroomTabMarks.Run
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let state: TabRunState = run == .running ? .running : .failed
    let label = RunStateIcon.label(state)
    Image(systemName: RunStateIcon.glyph(state))
      .font(RunStateIcon.glyphFont)
      .foregroundStyle(RunStateIcon.color(state, in: tokens))
      .help("Run command \(label)")
      .accessibilityLabel("run \(label)")
  }
}
