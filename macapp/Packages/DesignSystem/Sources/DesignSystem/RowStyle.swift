import SwiftUI

/// The shared selected/hover row-highlight fill used by the source lists (Settings sidebar, project
/// sidebar). Drawn ourselves rather than relying on `List`'s built-in selection so it uses the
/// theme tokens and we control the inset geometry: a stronger `surface` fill for the selected row,
/// a subtle `hover` fill on hover, clear otherwise. One definition so a tweak to the highlight
/// lands in every list at once.
public struct RowHighlight: View {
  @Environment(\.themeTokens) private var tokens
  let selected: Bool
  let hovered: Bool
  let horizontalPadding: CGFloat

  public init(selected: Bool, hovered: Bool, horizontalPadding: CGFloat = Spacing.m) {
    self.selected = selected
    self.hovered = hovered
    self.horizontalPadding = horizontalPadding
  }

  public var body: some View {
    RoundedRectangle(cornerRadius: Radius.s)
      .fill(selected ? tokens.surface : (hovered ? tokens.hover : Color.clear))
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, 1)
  }
}

/// A picker row's fill and ring; see `pickerRowChrome`.
private struct PickerRowChrome: ViewModifier {
  @Environment(\.themeTokens) private var tokens
  let highlighted: Bool
  let hovered: Bool
  let active: Bool

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: Radius.s)
          .fill(
            active
              ? tokens.accentSoft
              : (highlighted ? tokens.surface : (hovered ? tokens.hover : .clear)))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.s)
          .strokeBorder(
            active ? tokens.accent : (highlighted ? tokens.fgDim : .clear), lineWidth: 1.5)
      )
  }
}

extension View {
  /// A picker row's fill and ring (the open and new-workroom pickers, the theme picker): the
  /// `surface` fill and a faint ring on the keyboard-highlighted row, the `hover` wash under the
  /// pointer. An `active` row (the theme picker's chosen family) wears the accent instead, so ↑/↓
  /// focus stays visible on a row that isn't the chosen one.
  public func pickerRowChrome(highlighted: Bool, hovered: Bool, active: Bool = false)
    -> some View
  {
    modifier(PickerRowChrome(highlighted: highlighted, hovered: hovered, active: active))
  }
}

#Preview("Rows") {
  VStack(spacing: Spacing.xs) {
    Text("Selected").frame(maxWidth: .infinity, minHeight: 24)
      .background(RowHighlight(selected: true, hovered: false))
    Text("Hovered").frame(maxWidth: .infinity, minHeight: 24)
      .background(RowHighlight(selected: false, hovered: true))
    Text("Highlighted picker row").padding(Spacing.s).frame(maxWidth: .infinity)
      .pickerRowChrome(highlighted: true, hovered: false)
    Text("Active picker row").padding(Spacing.s).frame(maxWidth: .infinity)
      .pickerRowChrome(highlighted: false, hovered: false, active: true)
  }
  .padding(Spacing.xxl)
  .frame(width: 300)
}
