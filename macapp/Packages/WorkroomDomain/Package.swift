// swift-tools-version: 6.0
//
// The app's domain values: ids, layout trees and labels, with no AppKit and no I/O. It is the
// bottom package layer, so it depends on nothing but Foundation, and its tests run with plain
// `swift test` (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "WorkroomDomain",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WorkroomDomain", targets: ["WorkroomDomain"])
  ],
  targets: [
    .target(name: "WorkroomDomain"),
    .testTarget(name: "WorkroomDomainTests", dependencies: ["WorkroomDomain"]),
  ]
)
