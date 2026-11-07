import SwiftUI

/// The shared selected/hover row-highlight fill used by the source lists (Settings sidebar, project
/// sidebar). Drawn ourselves rather than relying on `List`'s built-in selection so it uses the
/// theme tokens and we control the inset geometry: a stronger `surface` fill for the selected row,
/// a subtle `hover` fill on hover, clear otherwise. One definition so a tweak to the highlight
/// lands in every list at once.
public struct RowHighlight: View {
  let tokens: ThemeTokens
  let selected: Bool
  let hovered: Bool
  let cornerRadius: CGFloat
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat

  public init(
    tokens: ThemeTokens, selected: Bool, hovered: Bool, cornerRadius: CGFloat = Radius.s,
    horizontalPadding: CGFloat = Spacing.m, verticalPadding: CGFloat = 1
  ) {
    self.tokens = tokens
    self.selected = selected
    self.hovered = hovered
    self.cornerRadius = cornerRadius
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
  }

  public var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .fill(selected ? tokens.surface : (hovered ? tokens.hover : Color.clear))
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
  }
}

extension View {
  /// A picker row's fill and ring (the open and new-workroom pickers, the theme picker): the
  /// `surface` fill and a faint ring on the keyboard-highlighted row, the `hover` wash under the
  /// pointer. An `active` row (the theme picker's chosen family) wears the accent instead, so ↑/↓
  /// focus stays visible on a row that isn't the chosen one.
  public func pickerRowChrome(
    tokens: ThemeTokens, highlighted: Bool, hovered: Bool, active: Bool = false
  ) -> some View {
    background(
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

#Preview("Rows") {
  let tokens = ThemeTokens(preview: nil)
  VStack(spacing: Spacing.xs) {
    Text("Selected").frame(maxWidth: .infinity, minHeight: 24)
      .background(RowHighlight(tokens: tokens, selected: true, hovered: false))
    Text("Hovered").frame(maxWidth: .infinity, minHeight: 24)
      .background(RowHighlight(tokens: tokens, selected: false, hovered: true))
    Text("Highlighted picker row").padding(Spacing.s).frame(maxWidth: .infinity)
      .pickerRowChrome(tokens: tokens, highlighted: true, hovered: false)
    Text("Active picker row").padding(Spacing.s).frame(maxWidth: .infinity)
      .pickerRowChrome(tokens: tokens, highlighted: false, hovered: false, active: true)
  }
  .padding(Spacing.xxl)
  .frame(width: 300)
}
