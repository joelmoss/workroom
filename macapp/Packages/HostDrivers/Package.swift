// swift-tools-version: 6.0
//
// The host drivers: the `HostDriver` protocol, the boxd, exe.dev and container drivers, the ssh
// transport they share, the pending-machine journal, a create's progress steps and the daemon
// bootstrap that puts this build's daemon on a host. What the app builds on top of them (the host
// registry, routing, the create sequence) stays in the app, and so does what the app bundles: the
// host-setup scripts, which the app hands each provider driver as a `HostSetup`, and the
// bootstrap's daemons, Ghostty set and far-side scripts, which the app hands `DaemonBootstrap`.
// It sits above DaemonConnection and WorkroomSystem, and its tests run with plain `swift test`
// (`make app-package-test`), with no app host; they read the scripts from the checkout.
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
    .package(path: "../WorkroomWire"),
  ],
  targets: [
    .target(
      name: "HostDrivers",
      dependencies: ["DaemonConnection", "WorkroomDomain", "WorkroomSystem", "WorkroomWire"]),
    .testTarget(
      name: "HostDriversTests",
      dependencies: ["HostDrivers", "DaemonConnection", "WorkroomDomain", "WorkroomSystem"]),
  ]
)
