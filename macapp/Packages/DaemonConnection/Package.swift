// swift-tools-version: 6.0
//
// The app's connection to `workroomd`: the handshake, the multiplexed service connection and its
// wire types, and the stream a host driver hands it. What the app builds on top of it (the
// repository, file, layout and forward services, routing) stays in the app. It sits above
// WorkroomVCS, WorkroomWire and WorkroomSystem, and its tests run with plain `swift test`
// (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "DaemonConnection",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DaemonConnection", targets: ["DaemonConnection"])
  ],
  dependencies: [
    .package(path: "../WorkroomVCS"),
    .package(path: "../WorkroomWire"),
    .package(path: "../WorkroomSystem"),
  ],
  targets: [
    .target(
      name: "DaemonConnection", dependencies: ["WorkroomVCS", "WorkroomWire", "WorkroomSystem"]),
    .testTarget(name: "DaemonConnectionTests", dependencies: ["DaemonConnection"]),
  ]
)
