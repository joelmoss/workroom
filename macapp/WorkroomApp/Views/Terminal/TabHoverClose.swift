import DesignSystem
import SwiftUI

/// Geometry of a tab chip's hover ✕, shared by the pane tabs (`TerminalTabChip`) and the title bar's
/// tabs (`WorkroomTabChip`) so the two can't drift.
enum TabHoverCloseMetrics {
  /// The ✕'s inset from the chip's trailing edge.
  static let inset: CGFloat = 4
  /// The button's own size: a 9pt glyph in a 3pt well on each side.
  static let button: CGFloat = 15
  /// How far the title takes to fade out.
  static let fade: CGFloat = 22
  /// The clear space between the faded-out title and the ✕.
  static let gap: CGFloat = 4
}

extension View {
  /// A tab chip's close button, shown only while the chip is hovered and laid OVER the chip's
  /// trailing end: the chip reserves no room for it, so at rest the title has the chip's full width,
  /// and the chip's measured width (the drag and overflow maths read it) never changes on hover.
  ///
  /// The content under the ✕ fades out through a mask rather than behind an opaque backing: a
  /// hovered idle tab's wash (`tokens.hover`) is translucent over the strip, and the title bar's
  /// strip is the window's own background, so no one fill could match every tab. Apply this to the
  /// chip's padded content, BEFORE its fills, so only the content fades and the pill stays whole.
  ///
  /// Hidden, the button is transparent and takes no clicks; it stays in the view tree, so its `.help`
  /// and accessibility label are kept. A chip that makes itself one accessibility element swallows
  /// it, so such a chip also offers Close as an accessibility action of its own.
  func tabHoverClose<Button: View>(
    isHovered: Bool, @ViewBuilder button: () -> Button
  ) -> some View {
    modifier(TabHoverClose(isHovered: isHovered, button: button()))
  }
}

private struct TabHoverClose<CloseButton: View>: ViewModifier {
  let isHovered: Bool
  let button: CloseButton

  func body(content: Content) -> some View {
    content
      .mask {
        HStack(spacing: 0) {
          Rectangle()
          if isHovered {
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
              .frame(width: TabHoverCloseMetrics.fade)
            Color.clear
              .frame(
                width: TabHoverCloseMetrics.gap + TabHoverCloseMetrics.button
                  + TabHoverCloseMetrics.inset)
          }
        }
        // The fade and the ✕ come and go with the pointer at once, not animated.
        .transaction { $0.animation = nil }
      }
      // The mask must not shrink the chip's hit area to the content it leaves visible.
      .contentShape(.interaction, Rectangle())
      .overlay(alignment: .trailing) {
        button
          .opacity(isHovered ? 1 : 0)
          .allowsHitTesting(isHovered)
          .padding(.trailing, TabHoverCloseMetrics.inset)
          .transaction { $0.animation = nil }
      }
  }
}

/// A tab's close button, laid over the chip's trailing end by `tabHoverClose`. Its own hover paints a
/// subtle well behind the ✕.
struct TabCloseButton: View {
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(hovering ? .primary : .secondary)
        .frame(width: TabHoverCloseMetrics.button - 6, height: TabHoverCloseMetrics.button - 6)
        .padding(3)
        // A circular hover well behind the ✕ (matches a round close affordance), faded in/out.
        .background(
          Circle()
            .fill(tokens.hover.opacity(hovering ? 1 : 0))
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovering)
  }
}
