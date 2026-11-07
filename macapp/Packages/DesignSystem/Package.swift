// swift-tools-version: 6.0
//
// The app's theme catalog and design tokens: the bundled theme families, the ghostty theme-file
// parser and its preview cache, the chrome tokens derived from a parsed theme, the spacing,
// radius and font-role scales, and the shared components built on them (messages, warnings,
// sheet chrome, row highlights), and the `\.themeTokens` environment key they read. AppKit and
// SwiftUI, but no app state: which family is active, the ghostty runtime and the windows'
// terminals stay with the app's `ThemeService`, which injects its tokens at every SwiftUI root.
// Its tests run with plain `swift test` (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "DesignSystem",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DesignSystem", targets: ["DesignSystem"])
  ],
  targets: [
    .target(name: "DesignSystem"),
    .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
  ]
)
