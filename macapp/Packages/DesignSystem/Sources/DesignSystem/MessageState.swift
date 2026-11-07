import SwiftUI

/// What a pane shows instead of its content when there is none to show, or it failed to load: a
/// glyph, a title and an optional detail line, centred in all the space the pane has. Failures
/// pass `exclamationmark.triangle`.
public struct MessageState: View {
  let title: String
  let systemImage: String
  let detail: String?

  public init(_ title: String, systemImage: String, detail: String? = nil) {
    self.title = title
    self.systemImage = systemImage
    self.detail = detail
  }

  public var body: some View {
    VStack(spacing: Spacing.s) {
      Image(systemName: systemImage).font(FontRole.messageGlyph).foregroundStyle(.tertiary)
      Text(title).font(FontRole.body).foregroundStyle(.secondary)
      if let detail, !detail.isEmpty {
        Text(detail).font(FontRole.detail).foregroundStyle(.tertiary)
          .multilineTextAlignment(.center).lineLimit(3)
      }
    }
    .padding(Spacing.xxxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

/// A one-line message at the top of a list that has nothing to list, or failed to load: a glyph
/// and a line of text, inset like the list's rows.
public struct InlineMessage: View {
  let text: String
  let systemImage: String
  let glyphStyle: HierarchicalShapeStyle

  /// `glyphStyle` is the glyph's emphasis; the text is always `.secondary`.
  public init(
    _ text: String, systemImage: String, glyphStyle: HierarchicalShapeStyle = .tertiary
  ) {
    self.text = text
    self.systemImage = systemImage
    self.glyphStyle = glyphStyle
  }

  public var body: some View {
    HStack(spacing: Spacing.s) {
      Image(systemName: systemImage).foregroundStyle(glyphStyle)
      Text(text).font(FontRole.body).foregroundStyle(.secondary)
    }
    .padding(.vertical, Spacing.s).padding(.horizontal, Spacing.m)
  }
}

#Preview("MessageState") {
  MessageState(
    "Diff unavailable", systemImage: "exclamationmark.triangle",
    detail: "The file is no longer in the worktree."
  )
  .frame(width: 320, height: 200)
}

#Preview("InlineMessage") {
  VStack(alignment: .leading) {
    InlineMessage("No files", systemImage: "folder")
    InlineMessage("No history", systemImage: "clock", glyphStyle: .secondary)
  }
}
