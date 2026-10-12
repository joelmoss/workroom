// swift-tools-version: 6.0
//
// The app's theme catalog and design tokens: the bundled theme families, the ghostty theme-file
// parser and its preview cache, and the chrome tokens derived from a parsed theme. AppKit and
// SwiftUI, but no app state: which family is active, the ghostty runtime and the windows'
// terminals stay with the app's `ThemeService`. Its tests run with plain `swift test`
// (`make app-package-test`), with no app host.
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
