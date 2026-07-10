import SwiftUI

/// The shared selected/hover row-highlight fill used by the source lists (Settings sidebar, project
/// sidebar) and the activity bar. Drawn ourselves rather than relying on `List`'s built-in selection
/// so it uses the theme tokens and we control the inset geometry: a stronger `surface` fill for the
/// selected row, a subtle `hover` fill on hover, clear otherwise. One definition so a tweak to the
/// highlight lands in every list at once (was duplicated across `SettingsView`/`ProjectSidebar`).
struct RowHighlight: View {
  var selected: Bool
  var hovered: Bool
  var cornerRadius: CGFloat = 6
  var horizontalPadding: CGFloat = 8
  var verticalPadding: CGFloat = 1

  var body: some View {
    let tokens = ThemeService.shared.tokens
    RoundedRectangle(cornerRadius: cornerRadius)
      .fill(selected ? tokens.surface : (hovered ? tokens.hover : Color.clear))
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
  }
}
