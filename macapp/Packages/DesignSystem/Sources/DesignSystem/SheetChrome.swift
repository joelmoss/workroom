import SwiftUI

/// A sheet's header: a large leading glyph beside the sheet's own title column, top-aligned so a
/// long title wraps under itself rather than under the glyph. The glyph is decoration, hidden from
/// accessibility; the title column says what the sheet is.
public struct SheetHeader<GlyphStyle: ShapeStyle, Content: View>: View {
  let systemImage: String
  let glyphStyle: GlyphStyle
  let content: Content

  public init(
    systemImage: String, glyphStyle: GlyphStyle, @ViewBuilder content: () -> Content
  ) {
    self.systemImage = systemImage
    self.glyphStyle = glyphStyle
    self.content = content()
  }

  public var body: some View {
    HStack(alignment: .top, spacing: Spacing.l) {
      Image(systemName: systemImage)
        .font(FontRole.headerGlyph)
        .foregroundStyle(glyphStyle)
        .accessibilityHidden(true)
      content
    }
  }
}

/// The header of a sheet that reports a failure or asks before something destructive: a
/// `SheetHeader` led by the theme's warning triangle.
public struct WarningHeader<Content: View>: View {
  let tokens: ThemeTokens
  let content: Content

  public init(tokens: ThemeTokens, @ViewBuilder content: () -> Content) {
    self.tokens = tokens
    self.content = content()
  }

  public var body: some View {
    SheetHeader(
      systemImage: "exclamationmark.triangle.fill", glyphStyle: tokens.warning
    ) { content }
  }
}

/// A sheet's button row: Cancel (Escape) then the sheet's primary action, trailing. The primary
/// is the caller's, so it keeps its own label, enablement, tint and identifier; give it
/// `sheetDefaultAction()` to make it the Return button.
public struct SheetFooter<Primary: View>: View {
  let cancelIdentifier: String?
  let onCancel: () -> Void
  let primary: Primary

  public init(
    cancelIdentifier: String? = nil, onCancel: @escaping () -> Void,
    @ViewBuilder primary: () -> Primary
  ) {
    self.cancelIdentifier = cancelIdentifier
    self.onCancel = onCancel
    self.primary = primary()
  }

  public var body: some View {
    HStack {
      Spacer()
      cancel
      primary
    }
  }

  @ViewBuilder private var cancel: some View {
    let button = Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
    if let cancelIdentifier {
      button.accessibilityIdentifier(cancelIdentifier)
    } else {
      button
    }
  }
}

extension View {
  /// A sheet's primary button: answers Return, drawn prominent.
  public func sheetDefaultAction() -> some View {
    keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
  }
}

#Preview("Warning sheet") {
  VStack(alignment: .leading, spacing: Spacing.xl) {
    WarningHeader(tokens: ThemeTokens(preview: nil)) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Delete project “workroom”?").font(FontRole.title)
        Text("~/dev/workroom").font(FontRole.body).foregroundStyle(.secondary)
      }
    }
    Divider()
    SheetFooter(onCancel: {}) {
      Button("Delete Project") {}.sheetDefaultAction().tint(.red)
    }
  }
  .padding(Spacing.xxl)
  .frame(width: 460)
}
