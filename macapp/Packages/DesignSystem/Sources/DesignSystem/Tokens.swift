import SwiftUI

/// The app's spacing scale, in points: the paddings and stack spacings its views repeat. A value
/// the scale doesn't hold stays a literal at its call site, so a view never shifts to fit the
/// scale.
public enum Spacing {
  /// Between a title and its subtitle.
  public static let xxs: CGFloat = 2
  /// Between the lines of a text column.
  public static let xs: CGFloat = 4
  /// Between a glyph and its text, and inside a compact row.
  public static let s: CGFloat = 6
  /// A row's horizontal inset, and between a sheet's footer buttons.
  public static let m: CGFloat = 8
  /// Between a sheet header's glyph and its title.
  public static let l: CGFloat = 12
  /// Between a sheet's sections.
  public static let xl: CGFloat = 16
  /// A sheet's edge padding.
  public static let xxl: CGFloat = 20
  /// Around an empty or failed pane's message.
  public static let xxxl: CGFloat = 24
}

/// The app's corner radii, in points.
public enum Radius {
  /// Small icon-button hover wells and code boxes.
  public static let xs: CGFloat = 5
  /// Row highlights, picker rows and toolbar hover wells.
  public static let s: CGFloat = 6
  /// Search fields, cards and drop accents.
  public static let m: CGFloat = 8
  /// Toasts and floating notices.
  public static let l: CGFloat = 12
}

/// The app's type roles: what a piece of text or a glyph is for, mapped to its font.
public enum FontRole {
  /// A sheet header's leading glyph.
  public static let headerGlyph: Font = .system(size: 30)
  /// A sheet's title.
  public static let title: Font = .headline
  /// A sheet's or a message's body text.
  public static let body: Font = .callout
  /// Secondary detail under a message.
  public static let detail: Font = .footnote
  /// An empty or failed pane's glyph.
  public static let messageGlyph: Font = .title2
  /// An inline notice's title.
  public static let noticeTitle: Font = .subheadline.weight(.semibold)
  /// An inline notice's body text.
  public static let noticeBody: Font = .caption
}
