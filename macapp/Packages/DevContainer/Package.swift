// swift-tools-version: 6.0
//
// The Development Containers spec (containers.dev), as a container workroom reads it (#308): a
// repository's devcontainer.json (`DevContainerConfig`), its features, fetched from their registry
// and built into the image (`DevContainerFeatures`), and the pure arithmetic that turns both into
// HostDrivers' `ContainerSpec` (`DevContainerSetup`). The create that fetches, builds and runs
// stays in the app (`ContainerCreate`). It sits above HostDrivers, WorkroomVCS (the file service a
// devcontainer.json is read through) and WorkroomSystem, and its tests run with plain `swift test`
// (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "DevContainer",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DevContainer", targets: ["DevContainer"])
  ],
  dependencies: [
    .package(path: "../HostDrivers"),
    .package(path: "../WorkroomDomain"),
    .package(path: "../WorkroomSystem"),
    .package(path: "../WorkroomVCS"),
  ],
  targets: [
    .target(
      name: "DevContainer",
      dependencies: ["HostDrivers", "WorkroomDomain", "WorkroomSystem", "WorkroomVCS"]),
    .testTarget(
      name: "DevContainerTests",
      dependencies: ["DevContainer", "HostDrivers", "WorkroomDomain", "WorkroomVCS"]),
  ]
)
