// swift-tools-version: 6.0
//
// The VCS layer's values: history, changesets, refs and remote state, the write results, the
// working-tree status record, host identity and routing errors, the file-service values, and the
// local engines' interfaces (LocalVCSProviding, LocalVCSWriting). No engine, transport, routing or
// process: the git engine, the agent adapters, the router and the context-bound services stay in
// the app. It depends on Foundation only and sits below the agent connection; its tests run with plain
// `swift test` (`make app-package-test`), with no app host.
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
