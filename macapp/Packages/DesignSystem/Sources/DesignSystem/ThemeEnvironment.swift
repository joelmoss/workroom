import SwiftUI

/// What an un-injected tree reads: the system palette (`ThemeTokens(preview: nil)`), the look the
/// chrome falls back to when no theme resolves. It is not the active theme: the app injects that
/// at every SwiftUI root, so a tree that draws this default is one a root is missing from. One
/// shared instance, so repeated reads of the default never count as a change.
private struct ThemeTokensKey: EnvironmentKey {
  static let defaultValue = ThemeTokens(preview: nil)
}

extension EnvironmentValues {
  /// The active theme's chrome colours. Views and this package's components read this; the app
  /// injects it at every SwiftUI root (window, scene, hosting view or controller).
  public var themeTokens: ThemeTokens {
    get { self[ThemeTokensKey.self] }
    set { self[ThemeTokensKey.self] = newValue }
  }
}
