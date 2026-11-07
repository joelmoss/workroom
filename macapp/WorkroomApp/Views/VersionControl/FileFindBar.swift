import SwiftUI

/// The find bar overlaid on the focused file viewer (`PlainFileViewer`) while a search is open. Binds
/// the field to `FileFindModel.needle` (re-searching on change) and reads the match count; prev/next
/// step matches, Esc/✕ closes. Styled to match the terminal scrollback find bar.
struct FileFindBar: View {
  @ObservedObject var model: FileFindModel
  @FocusState private var fieldFocused: Bool

  var body: some View {
    if model.isOpen {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)

        TextField(
          "Find",
          text: Binding(get: { model.needle }, set: { model.setNeedle($0) })
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .frame(width: 170)
        .focused($fieldFocused)
        .onSubmit { model.next() }

        Text(model.summary)
          .font(.system(size: 11))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 58, alignment: .trailing)

        Divider().frame(height: 14)

        Button {
          model.previous()
        } label: {
          Image(systemName: "chevron.up")
        }
        .help("Previous match (⇧⌘G)")
        .disabled(!model.hasMatches)

        Button {
          model.next()
        } label: {
          Image(systemName: "chevron.down")
        }
        .help("Next match (⌘G)")
        .disabled(!model.hasMatches)

        Button {
          model.close()
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
      .onAppear { DispatchQueue.main.async { fieldFocused = true } }
      .onExitCommand { model.close() }
    }
  }
}
