import DesignSystem
import SwiftUI

/// What a popped-out pane's slot shows while the pane is in a window of its own (issue #172): the
/// slot keeps its place in the strip and the split, and says where the pane went, with a way to it
/// and a way to bring it back. Drawn over the slot's content, below the pane's own title bar, which
/// keeps its name and its close button.
///
/// Go to Window raises the pane's window and makes it key. Pull Back Here docks the pane into this
/// slot, focused; it is the default button, but only while this slot is the focused one, so Return
/// in another pane, or in a second placeholder, never pulls this one back.
struct PoppedOutPlaceholder: View {
  let tabID: TerminalTab.ID
  let content: TabContent
  /// Whether this slot is the focused one, which alone answers Return.
  let focused: Bool
  let onGoToWindow: () -> Void
  let onPullBack: () -> Void
  /// Focus this slot, as a click into the pane's body does.
  let onActivate: () -> Void

  var body: some View {
    VStack(spacing: Spacing.l) {
      Image(systemName: "macwindow.on.rectangle")
        .font(FontRole.messageGlyph)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      TabTitleReader(content: content) { title in
        Text("\(title) is open in another window")
          .font(FontRole.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .truncationMode(.middle)
          .accessibilityIdentifier("pane.poppedOut.title.\(tabID)")
      }
      HStack(spacing: Spacing.m) {
        Button("Go to Window", action: onGoToWindow)
          .help("Bring the window this terminal is open in to the front")
          .accessibilityIdentifier("pane.poppedOut.goToWindow.\(tabID)")
        pullBackButton
          .help("Move this terminal back into this pane")
          .accessibilityIdentifier("pane.poppedOut.pullBack.\(tabID)")
      }
      .controlSize(.regular)
    }
    .padding(Spacing.xxxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    // The pane's own background, as its terminal draws on.
    .terminalBase()
    // A click on the slot outside the buttons focuses it, as a click into a pane does.
    .contentShape(Rectangle())
    .onTapGesture(perform: onActivate)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pane.poppedOut.\(tabID)")
  }

  /// Pull Back Here, the default button while this slot is focused.
  @ViewBuilder private var pullBackButton: some View {
    let button = Button("Pull Back Here", action: onPullBack)
    if focused {
      button.keyboardShortcut(.defaultAction)
    } else {
      button
    }
  }
}

/// A popped-out tab's mark, before its title wherever the tab is listed: its strip chip, its
/// title-bar tab and its Open Tabs view row (issue #172). Its title goes secondary beside it.
struct PoppedOutMark: View {
  /// The glyph's point size, matching the glyphs it sits among.
  var size: CGFloat = 10
  /// What the mark says, for a tab's tooltip and accessibility label.
  static let label = "open in another window"

  var body: some View {
    Image(systemName: "arrow.up.forward.square")
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(.secondary)
      .help("Open in another window")
      // The tab's own label says it (`label`), as one element.
      .accessibilityHidden(true)
  }
}
