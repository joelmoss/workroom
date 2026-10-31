// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GhosttyKit",
  platforms: [.macOS(.v15)],
  products: [.library(name: "GhosttyKit", targets: ["GhosttyKitLink"])],
  targets: [
    .target(
      name: "GhosttyKitLink",
      dependencies: ["GhosttyKit"],
      linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Carbon")]),
    // A link to vcs/scripts/build-ghostty-vt.sh's build, made by project.yml's preGenCommand.
    .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
  ]
)
