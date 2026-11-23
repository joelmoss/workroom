import SwiftUI

/// A pane's program-status mark (#358): the raised hand while a program waits on the user, the
/// check for a finished turn. While its host's link is down there is nothing to answer, so the
/// mark gives way to a disconnected cloud in a neutral colour, the same size, with a tooltip that
/// says it is reconnecting and what the terminal last showed.
struct ProgramStatusGlyph: View {
  enum Mark { case blocked, done }

  let mark: Mark
  var stale = false
  var size: CGFloat = 11
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    if stale {
      Image(systemName: "icloud.slash")
        .font(.system(size: size))
        .foregroundStyle(tokens.disconnected)
        .help(ProgramStatusPresentation.disconnectedTooltip(lastSeen: mark))
    } else {
      Image(systemName: mark == .blocked ? "hand.raised.fill" : "checkmark.circle.fill")
        .font(.system(size: size))
        .foregroundStyle(mark == .blocked ? tokens.warning : tokens.success)
    }
  }
}

/// The waiting glyph as a button (a workroom row, a collapsed project header): shows the terminal
/// that has waited longest. A 24 pt tall hit area whatever the glyph's size, with the glyph centred
/// in it so it sits on a sidebar row's trailing column like every other mark. How many terminals
/// wait is in its tooltip and spoken label, not drawn: the hand is enough. While every waiting
/// terminal's host is disconnected there is nothing to answer, so it is a plain mark that only
/// says so: not a disabled button, which would dim the disconnected colour below its contrast.
struct NeedsYouButton: View {
  let count: Int
  let stale: Bool
  let action: () -> Void

  var body: some View {
    if stale {
      glyph
        .help(ProgramStatusPresentation.disconnectedTooltip(lastSeen: .blocked))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProgramStatusPresentation.waitingLabel(count: count, stale: true))
    } else {
      Button(action: action) { glyph.contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .help(ProgramStatusPresentation.waitingTooltip(count: count))
        .accessibilityLabel(ProgramStatusPresentation.waitingLabel(count: count, stale: false))
        .accessibilityHint(ProgramStatusPresentation.showWaitingAction)
    }
  }

  private var glyph: some View {
    ProgramStatusGlyph(mark: .blocked, stale: stale)
      .frame(minWidth: SidebarRowMetrics.iconColumnWidth, minHeight: 24)
  }
}

/// A static two-point underline along a chip's base: the waiting colour, or the failure colour for a
/// program that stopped on an error. Never sweeps, unlike `RunningUnderline`.
struct StatusUnderline: View {
  let color: Color

  var body: some View {
    Capsule().fill(color).frame(height: 2)
  }
}
