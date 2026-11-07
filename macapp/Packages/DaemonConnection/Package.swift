// swift-tools-version: 6.0
//
// The app's connection to `workroomd`: the handshake, the multiplexed service connection and its
// wire types, the stream a host driver hands it, and the port-forward service with its pumps. What
// the app builds on top of it (the repository, file and layout services, routing) stays in the
// app. It sits above WorkroomDomain, WorkroomVCS, WorkroomWire and WorkroomSystem, and its tests
// run with plain `swift test` (`make app-package-test`), with no app host.
//
// `DaemonConnectionTestSupport` is for tests only, here and in the app's: the scripted daemon and
// the loopback TCP fixtures the forward tests share. It imports nothing of this package's, so a
// test bundle linking it never holds a second copy of the types the app already links.
import PackageDescription

let package = Package(
  name: "DaemonConnection",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DaemonConnection", targets: ["DaemonConnection"]),
    .library(name: "DaemonConnectionTestSupport", targets: ["DaemonConnectionTestSupport"]),
  ],
  dependencies: [
    .package(path: "../WorkroomDomain"),
    .package(path: "../WorkroomVCS"),
    .package(path: "../WorkroomWire"),
    .package(path: "../WorkroomSystem"),
  ],
  targets: [
    .target(
      name: "DaemonConnection",
      dependencies: ["WorkroomDomain", "WorkroomVCS", "WorkroomWire", "WorkroomSystem"]),
    .target(name: "DaemonConnectionTestSupport"),
    .testTarget(
      name: "DaemonConnectionTests",
      dependencies: [
        "DaemonConnection", "DaemonConnectionTestSupport", "WorkroomDomain", "WorkroomVCS",
        "WorkroomSystem",
      ]),
  ]
)
