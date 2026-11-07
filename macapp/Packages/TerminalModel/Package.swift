// swift-tools-version: 6.0
//
// The terminal pane model, as values with no AppKit and no I/O: one target's tab order, split
// groups, focus and "Terminal N" counter (`PaneState`), the rules that read and write only those,
// and the app-wide records those ids name, with who holds each (`TabRecords`). It sits above WorkroomDomain, whose `PaneSplitGroups` holds the split rules, and its tests
// run with plain `swift test` (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "TerminalModel",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "TerminalModel", targets: ["TerminalModel"])
  ],
  dependencies: [
    .package(path: "../WorkroomDomain")
  ],
  targets: [
    .target(name: "TerminalModel", dependencies: ["WorkroomDomain"]),
    .testTarget(name: "TerminalModelTests", dependencies: ["TerminalModel", "WorkroomDomain"]),
  ]
)
