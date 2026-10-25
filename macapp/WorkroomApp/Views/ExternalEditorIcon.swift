import SwiftUI

/// Keep icon readiness observation in this leaf, rather than re-evaluating every pane toolbar.
struct ExternalEditorIcon: View {
  let editor: ExternalEditor
  var size: CGFloat = 20

  var body: some View {
    Group {
      if let image = editor.icon {
        Image(nsImage: image).renderingMode(.original).resizable().scaledToFit()
      } else {
        Image(systemName: "arrow.up.forward.app")
          .resizable().scaledToFit().foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
