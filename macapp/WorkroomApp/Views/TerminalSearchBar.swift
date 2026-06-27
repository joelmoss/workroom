import SwiftUI

/// The scrollback **find** bar, overlaid on the focused terminal pane while a search is active
/// (`model.isActive`). It owns no search logic: the text field edits `model.needle` (pushed to
/// libghostty on change), and the count + match navigation read/drive the engine through the model.
/// Rendered by `PaneTreeView` over the focused leaf only — search state is per-surface.
struct TerminalSearchBar: View {
  @ObservedObject var model: TerminalSearchModel
  @FocusState private var fieldFocused: Bool

  var body: some View {
    if model.isActive {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)

        TextField("Find", text: $model.needle)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .frame(width: 170)
          .focused($fieldFocused)
          .onChange(of: model.needle) { _, text in model.setNeedle(text) }
          .onSubmit { model.navigate(.next) }

        Text(model.matchSummary)
          .font(.system(size: 11))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 58, alignment: .trailing)

        Divider().frame(height: 14)

        Button {
          model.navigate(.previous)
        } label: {
          Image(systemName: "chevron.up")
        }
        .help("Previous match (⇧⌘G)")
        .disabled(!model.hasMatches)

        Button {
          model.navigate(.next)
        } label: {
          Image(systemName: "chevron.down")
        }
        .help("Next match (⌘G)")
        .disabled(!model.hasMatches)

        Button {
          model.end()
        } label: {
          Image(systemName: "xmark")
        }
        .help("Close (Esc)")
      }
      .buttonStyle(.borderless)
      .font(.system(size: 12))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator)
      )
      .shadow(radius: 8, y: 2)
      .padding(10)
      // Focus the field as soon as the bar opens so you can type immediately. Deferred a runloop:
      // at `onAppear` the field's backing view isn't in the window yet, and the surrounding pane is
      // re-rendering (the overlay just appeared) — setting focus synchronously there gets clobbered.
      // `TerminalContainerView.applyFocus` also yields to us while the search is active, so the
      // terminal surface doesn't steal first responder back.
      .onAppear { DispatchQueue.main.async { fieldFocused = true } }
      // Esc closes even when focus sits on a button rather than the field.
      .onExitCommand { model.end() }
    }
  }
}
