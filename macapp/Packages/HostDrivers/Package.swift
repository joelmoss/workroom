// swift-tools-version: 6.0
//
// The host drivers: the `HostDriver` protocol, the boxd, exe.dev and container drivers, the ssh
// transport they share, the pending-machine journal and a create's progress steps. What the app
// builds on top of them (the host registry, routing, the create sequence, the daemon bootstrap)
// stays in the app, and so do the host-setup scripts, which `HostSetup` reads from the app's
// bundle. It sits above DaemonConnection and WorkroomSystem, and its tests run with plain
// `swift test` (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "HostDrivers",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "HostDrivers", targets: ["HostDrivers"])
  ],
  dependencies: [
    .package(path: "../DaemonConnection"),
    .package(path: "../WorkroomDomain"),
    .package(path: "../WorkroomSystem"),
    .package(path: "../WorkroomVCS"),
    .package(path: "../WorkroomWire"),
  ],
  targets: [
    .target(
      name: "HostDrivers",
      dependencies: [
        "DaemonConnection", "WorkroomDomain", "WorkroomSystem", "WorkroomVCS", "WorkroomWire",
      ]),
    .testTarget(name: "HostDriversTests", dependencies: ["HostDrivers"]),
  ]
)
