import SwiftUI

/// A pane's program-status mark (#358): the raised hand while a program waits on the user, the
/// check for a finished turn. A host whose link is down keeps the colour and gains a small clock at
/// the bottom-right, drawn as an overlay so it never changes the slot's size. (The plan's first
/// choice, a hairline `fgMuted` ring, measured under 3:1 on 25 bundled themes, so it takes the
/// plan's fallback: `SwitcherThemeSweepTests` pins the clock's colour instead.)
struct ProgramStatusGlyph: View {
  enum Mark { case blocked, done }

  let mark: Mark
  var stale = false
  var size: CGFloat = 11
  private let theme = ThemeService.shared

  var body: some View {
    let palette = ProgramStatusPalette.current
    Image(systemName: mark == .blocked ? "hand.raised.fill" : "checkmark.circle.fill")
      .font(.system(size: size))
      .foregroundStyle(mark == .blocked ? palette.attention : palette.done)
      .overlay(alignment: .bottomTrailing) {
        if stale {
          Image(systemName: "clock.fill")
            .font(.system(size: max(6, (size * 0.6).rounded())))
            .foregroundStyle(theme.tokens.fg)
            .background(Circle().fill(theme.tokens.panel).padding(-1))
            .offset(x: 3, y: 2)
        }
      }
  }
}

/// The waiting glyph as a button (a workroom row, a collapsed project header): shows the terminal
/// that has waited longest. A 24×24 pt hit area whatever the glyph's size, and the count's width is
/// reserved so a second waiting terminal never shifts the row.
struct NeedsYouButton: View {
  let count: Int
  let stale: Bool
  var showsCount = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 1) {
        ProgramStatusGlyph(mark: .blocked, stale: stale)
        if showsCount {
          Text(count > 1 ? "\(count)" : "")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 12, alignment: .leading)
        }
      }
      .frame(minWidth: 24, minHeight: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(ProgramStatusPresentation.waitingTooltip(count: count))
    .accessibilityLabel(ProgramStatusPresentation.waitingLabel(count: count, stale: stale))
    .accessibilityHint(ProgramStatusPresentation.showWaitingAction)
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
