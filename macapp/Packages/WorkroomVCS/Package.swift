// swift-tools-version: 6.0
//
// The VCS layer's values and interfaces: history, changesets, refs and remote state, the write
// results, the working-tree status record, routing errors, the file service's values and its
// interface (`FileProviding`, which the native and daemon providers conform to), a repository's
// validated location and routing context, the bound services every reader and writer conforms to
// (`VCSProviding`, `VCSWriting`), and the local engines' interfaces (LocalVCSProviding,
// LocalVCSWriting). No engine, transport, routing or process: the git engine is WorkroomGit, and the
// daemon adapters, the router and the context-bound services stay in the app. It depends on
// WorkroomDomain (for `HostID`) and WorkroomSystem (for `runBlocking`) and sits below the daemon
// connection; its tests run with plain `swift test` (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "WorkroomVCS",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WorkroomVCS", targets: ["WorkroomVCS"])
  ],
  dependencies: [
    .package(path: "../WorkroomDomain"),
    .package(path: "../WorkroomSystem"),
  ],
  targets: [
    .target(name: "WorkroomVCS", dependencies: ["WorkroomDomain", "WorkroomSystem"]),
    .testTarget(name: "WorkroomVCSTests", dependencies: ["WorkroomVCS"]),
  ]
)
