import SwiftUI

/// Hover/press chrome for the title-bar toolbar's icon buttons (sidebar toggle, back/forward, quick
/// terminal, run/stop/restart, bell, inspector toggle). Replaces the bare `.borderless` style so they
/// get the SAME affordance as every other icon button in the app — the sidebar's theme/add buttons and
/// the tab strips' "+" all use a `tokens.hover` rounded square on hover — instead of no feedback at all.
///
/// A `ButtonStyle` (not a per-button `.onHover` + manual background) so one modifier on each title-bar
/// bar covers all its buttons, including nested ones, and the hover rect sizes itself to each glyph.
struct ToolbarIconButtonStyle: ButtonStyle {
  /// Minimum square well side for the window and workroom title bars — the default every caller got
  /// before the style took parameters.
  static let wellSize: CGFloat = 22
  static let horizontalPadding: CGFloat = 3

  /// One well's full horizontal footprint at the default size, for callers that must reserve space
  /// for a control which isn't rendered yet (see `RunControls.reservedWidth`).
  static var footprint: CGFloat { wellSize + horizontalPadding * 2 }

  /// Per-instance so a denser row can shrink its wells without shrinking every bar in the app. The
  /// detail-panel title bar is the one caller that does: it carries up to four buttons plus a mode
  /// switch in a pane that can be 300pt wide, where the title-bar defaults crowd the title out.
  var wellSize: CGFloat = ToolbarIconButtonStyle.wellSize
  var horizontalPadding: CGFloat = ToolbarIconButtonStyle.horizontalPadding

  func makeBody(configuration: Configuration) -> some View {
    Chrome(
      configuration: configuration, wellSize: wellSize, horizontalPadding: horizontalPadding)
  }

  /// A view (not an inline modifier chain) so it can hold the `@State hovering` a `ButtonStyle`'s
  /// `Configuration` doesn't carry, and read `isEnabled` to suppress hover on a disabled button.
  private struct Chrome: View {
    let configuration: Configuration
    let wellSize: CGFloat
    let horizontalPadding: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    private let theme = ThemeService.shared

    var body: some View {
      configuration.label
        // A uniform tap target so every glyph gets the same square hover well, matching the sidebar's
        // 28pt buttons in spirit while staying compact enough for the 28pt-tall title-bar row.
        .frame(minWidth: wellSize, minHeight: wellSize)
        .padding(.horizontal, horizontalPadding)
        .background(
          // Animate ONLY the hover fill's opacity — never the whole button. A view-tree
          // `.animation(.easeOut, value: hovering)` at the end of this chain would also animate the
          // *label's* layout: on hover-in the glyph's pixel-snapped origin can re-round by one device
          // pixel (release/optimized builds and fractional display scaling snap differently than a
          // Debug build on an integer-scale display), and the implicit animation interpolates that 1pt
          // re-round into a visible "slide then settle" of the icon (issue #78). Scoping the animation
          // to the fill keeps the glyph out of every animation transaction, so any re-round snaps
          // instantly and imperceptibly while the well still fades in.
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.tokens.hover)
            .opacity(hovering && isEnabled ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // Dim on press; dim further when disabled — restoring what `.borderless` gave. Without the
        // disabled case a disabled button (e.g. Back/Forward with no history) renders at full strength,
        // so it looks active yet never shows a hover well — reading as a broken/"missing" hover. The
        // dim makes "disabled, so no hover" legible; enabled buttons keep the hover fill.
        .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.4))
        .onHover { hovering = $0 }
    }
  }
}
