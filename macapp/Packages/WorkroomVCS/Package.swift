// swift-tools-version: 6.0
//
// The VCS layer's values and interfaces: history, changesets, refs, remote state, write results,
// the working-tree status record, repository locations and the file-service values. No engine,
// transport or process: the git engine, the agent adapters and routing stay in the app. It sits
// above WorkroomDomain and below the agent connection, and its tests run with plain `swift test`
// (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "WorkroomVCS",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WorkroomVCS", targets: ["WorkroomVCS"])
  ],
  targets: [
    .target(name: "WorkroomVCS"),
    .testTarget(name: "WorkroomVCSTests", dependencies: ["WorkroomVCS"]),
  ]
)
