import SwiftUI

/// One icon-only toolbar action, styled to match the app's other small controls (the tab strip's
/// "+" new-terminal button, the remove-from-split ✕, the Changes-panel row hover toolbar): a small
/// glyph with a hover well, a tooltip, and an accessibility label + identifier (per the "tooltips on
/// all controls" convention). Carries its own `onHover` so the `.help` tooltip's tracking area is
/// reliably installed. Shared by the tab strip (issue #72) and the Changes panel (issue #93).
struct TabToolbarButton: View {
  let systemImage: String
  let help: String
  let accessibilityLabel: String
  let identifier: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(ThemeService.shared.tokens.hover.opacity(hovering ? 1 : 0))
        )
        // The whole padded glyph — the hover well the user aims at — is hoverable/clickable, not just
        // the SF Symbol: transparent padding doesn't hit-test on its own, so without this the button's
        // real target was the ~13×10 image inside a ~24×20 well. Everything that keys off hover was
        // then dead in that ring: no well fill, no `.help` tooltip, no click — which is what "the tabs
        // toolbar buttons have no tooltips" actually was. Measured through the AX frame (13×10 → 24×20;
        // `TabStripOverflowUITests.testChromeGlyphButtonsClaimTheirWholeWell` locks it in).
        // A `.frame` will NOT do this — measured: the AX frame stays 13×10. Mirrors the strip's "+"
        // (`TerminalTabStrip.addTerminalButton`) and the inspector's header buttons, which have always
        // had their own content shape.
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(identifier)
  }
}
