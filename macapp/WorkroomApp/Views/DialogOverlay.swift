import SwiftUI

/// A centered, **blocking** overlay for the command-palette dialogs (New / Open Workroom).
///
/// Used instead of a `.sheet` for one reason: a click anywhere on the dimmed backdrop closes the
/// dialog, which a macOS sheet won't do. That is the *only* way it is less modal than a sheet — while
/// it's up, keyboard shortcuts are inert (the key monitor's `shortcutStore` won't route to a window
/// with an `activePicker`, and menu items AND in `AppStore.hasModalPresentation`), the terminal gives
/// up first responder, and clicks can't reach the panes behind it. Do not read "not a sheet" as "not
/// modal": it was exactly that gap this overlay was fixed for.
///
/// The card springs in on appear (mirrors `SetupOverlay`); its opaque `panel` fill captures taps so
/// clicks on the dialog itself never reach the backdrop. Verified with a real HID-level click that the
/// backdrop wins the hit test even over a mounted Ghostty surface — a synthetic accessibility "click"
/// does NOT reproduce this and will report a false leak.
/// The dim + reveal curve shared by `DialogOverlay`'s backdrop and the title-bar accessory's own dim
/// (`RootView.accessoryBarContent`). The accessory is a separate window-level AppKit hosting tree that
/// the backdrop can never cover, so it has to draw its own half of the same dim — one source here
/// stops the two drifting apart, in either opacity or timing.
///
/// A non-generic namespace on purpose: these can't live on `DialogOverlay` itself, because referring
/// to a static member of a generic type from outside gives "generic parameter 'Content' could not be
/// inferred".
enum DialogOverlayStyle {
  static func backdropOpacity(for scheme: ColorScheme) -> Double {
    scheme == .light ? 0.08 : 0.25
  }

  /// Driven off a plain bool an un-animated accessory dim snaps in while the backdrop fades over
  /// ~0.32s, and the mismatch is visible.
  static var revealAnimation: Animation { .spring(response: 0.32, dampingFraction: 0.85) }
}

struct DialogOverlay<Content: View>: View {
  let onDismiss: () -> Void
  @ViewBuilder var content: Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  private let theme = ThemeService.shared
  @State private var shown = false

  var body: some View {
    ZStack {
      // Dimmed backdrop — a tap anywhere on it dismisses (lighter in light mode, like SetupOverlay).
      Rectangle()
        .fill(Color.black.opacity(shown ? DialogOverlayStyle.backdropOpacity(for: colorScheme) : 0))
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)

      content
        .background(theme.tokens.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.tokens.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .scaleEffect(shown ? 1 : 0.96)
        .opacity(shown ? 1 : 0)
    }
    // Esc otherwise depends entirely on the Cancel button's `.keyboardShortcut(.cancelAction)`, which
    // needs SwiftUI focus to already be inside the dialog. `onDismiss` is idempotent (it nils
    // `activePicker`), so the two paths are safe together.
    .onExitCommand(perform: onDismiss)
    .onAppear {
      guard !shown else { return }
      if reduceMotion {
        shown = true
      } else {
        withAnimation(DialogOverlayStyle.revealAnimation) { shown = true }
      }
    }
  }
}
