import SwiftUI

/// The warning triangle every warning in the app is marked with.
let warningSymbol = "exclamationmark.triangle.fill"

/// A warning shown inline, in the flow of a sheet or panel rather than over it: the warning
/// triangle beside a text column, on a faint warning-tinted panel. `accessory` sits below the
/// header row at the panel's full width, for output too long to sit beside the glyph.
public struct Notice<Content: View, Accessory: View>: View {
  /// The panel's inset, wider than its rows' 8pt spacing so the tint reads as a panel.
  static var padding: CGFloat { 10 }

  @Environment(\.themeTokens) private var tokens
  let content: Content
  let accessory: Accessory

  public init(@ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
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
  public init(@ViewBuilder content: () -> Content) {
    self.init(content: content) { EmptyView() }
  }
}

/// A one-line warning: the warning triangle and its text, both in the theme's warning colour.
/// The caller sets the font.
public struct WarningLabel: View {
  @Environment(\.themeTokens) private var tokens
  let label: Label<Text, Image>

  public init(_ titleKey: LocalizedStringKey) {
    label = Label(titleKey, systemImage: warningSymbol)
  }

  @_disfavoredOverload
  public init<S: StringProtocol>(_ title: S) {
    label = Label(title, systemImage: warningSymbol)
  }

  public var body: some View {
    label.foregroundStyle(tokens.warning)
  }
}

/// The warning triangle alone, in the theme's warning colour: a row's or a field's mark that
/// something needs attention. The caller sets its size and gives it a `.help` saying what.
public struct WarningGlyph: View {
  @Environment(\.themeTokens) private var tokens

  public init() {}

  public var body: some View {
    Image(systemName: warningSymbol).foregroundStyle(tokens.warning)
  }
}

#Preview("Warnings") {
  VStack(alignment: .leading, spacing: Spacing.l) {
    Notice {
      Text("1 file has staged changes that differ from the file on disk")
        .font(FontRole.noticeTitle)
      Text("Committing records what is on disk, so the version you staged will be replaced.")
        .font(FontRole.noticeBody).foregroundStyle(.secondary)
    }
    WarningLabel("Another workroom in this project already shows that name.")
      .font(.caption)
    HStack {
      Text("Project folder")
      WarningGlyph().help("Project folder not found")
    }
  }
  .padding(Spacing.xxl)
  .frame(width: 420)
}
