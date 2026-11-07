import SwiftUI

/// The warning triangle every warning in the app is marked with.
let warningSymbol = "exclamationmark.triangle.fill"

/// A warning shown inline, in the flow of a sheet or panel rather than over it: the warning
/// triangle beside a text column, on a faint warning-tinted panel. `accessory` sits below the
/// header row at the panel's full width, for output too long to sit beside the glyph.
public struct Notice<Content: View, Accessory: View>: View {
  /// The panel's inset, wider than its rows' 8pt spacing so the tint reads as a panel.
  static var padding: CGFloat { 10 }

  let tokens: ThemeTokens
  let content: Content
  let accessory: Accessory

  public init(
    tokens: ThemeTokens, @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.tokens = tokens
    self.content = content()
    self.accessory = accessory()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.m) {
      HStack(alignment: .top, spacing: Spacing.m) {
        Image(systemName: warningSymbol)
          .foregroundStyle(tokens.warning)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Spacing.xs) { content }
      }
      accessory
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Self.padding)
    .background(RoundedRectangle(cornerRadius: Radius.s).fill(tokens.warning.opacity(0.08)))
  }
}

extension Notice where Accessory == EmptyView {
  public init(tokens: ThemeTokens, @ViewBuilder content: () -> Content) {
    self.init(tokens: tokens, content: content) { EmptyView() }
  }
}

/// A one-line warning: the warning triangle and its text, both in the theme's warning colour.
/// The caller sets the font.
public struct WarningLabel: View {
  let label: Label<Text, Image>
  let tokens: ThemeTokens

  public init(_ titleKey: LocalizedStringKey, tokens: ThemeTokens) {
    label = Label(titleKey, systemImage: warningSymbol)
    self.tokens = tokens
  }

  @_disfavoredOverload
  public init<S: StringProtocol>(_ title: S, tokens: ThemeTokens) {
    label = Label(title, systemImage: warningSymbol)
    self.tokens = tokens
  }

  public var body: some View {
    label.foregroundStyle(tokens.warning)
  }
}

/// The warning triangle alone, in the theme's warning colour: a row's or a field's mark that
/// something needs attention. The caller sets its size and gives it a `.help` saying what.
public struct WarningGlyph: View {
  let tokens: ThemeTokens

  public init(tokens: ThemeTokens) {
    self.tokens = tokens
  }

  public var body: some View {
    Image(systemName: warningSymbol).foregroundStyle(tokens.warning)
  }
}

#Preview("Warnings") {
  let tokens = ThemeTokens(preview: nil)
  VStack(alignment: .leading, spacing: Spacing.l) {
    Notice(tokens: tokens) {
      Text("1 file has staged changes that differ from the file on disk")
        .font(FontRole.noticeTitle)
      Text("Committing records what is on disk, so the version you staged will be replaced.")
        .font(FontRole.noticeBody).foregroundStyle(.secondary)
    }
    WarningLabel("Another workroom in this project already shows that name.", tokens: tokens)
      .font(.caption)
    HStack {
      Text("Project folder")
      WarningGlyph(tokens: tokens).help("Project folder not found")
    }
  }
  .padding(Spacing.xxl)
  .frame(width: 420)
}
