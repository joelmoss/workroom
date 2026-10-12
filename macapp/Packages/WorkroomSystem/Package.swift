// swift-tools-version: 6.0
//
// Runtime helpers with no app state: bounded waits (`withTimeout`), blocking work off the
// cooperative pool (`runBlocking`) and process-tree reaping (`ProcessTree`). It depends on
// Foundation only and sits below the agent connection, so the app's git and file code use these
// without importing the transport. Its tests run with plain `swift test`
// (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "WorkroomSystem",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WorkroomSystem", targets: ["WorkroomSystem"])
  ],
  targets: [
    .target(name: "WorkroomSystem"),
    .testTarget(name: "WorkroomSystemTests", dependencies: ["WorkroomSystem"]),
  ]
)
