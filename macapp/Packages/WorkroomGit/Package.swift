// swift-tools-version: 6.0
//
// The local git engine: reads on libgit2's C API (`GitProvider` over `GitRepository`, plus the
// `GitGraph`, `GitCommitDiff` and `GitDiffStats` readers; ADR 0002: only this package imports
// `libgit2`), the unified-diff model and its line algorithms, and writes through the real `git` CLI
// (`CLIVCSWriter`, serialized per project root by `RepositoryWriteGate`). It implements WorkroomVCS's
// local engine interfaces; routing, the daemon adapters and GitHub stay in the app. Its tests run
// with plain `swift test` (`make app-package-test`), with no app host.
import PackageDescription

let package = Package(
  name: "WorkroomGit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WorkroomGit", targets: ["WorkroomGit"])
  ],
  dependencies: [
    .package(path: "../WorkroomDomain"),
    .package(path: "../WorkroomVCS"),
    .package(path: "../WorkroomSystem"),
    // libgit2, built from the release macapp/Scripts/vendor-libgit2.sh vendors (VENDOR.md there).
    .package(path: "../LibGit2"),
  ],
  targets: [
    .target(
      name: "WorkroomGit",
      dependencies: [
        "WorkroomDomain", "WorkroomVCS", "WorkroomSystem",
        .product(name: "libgit2", package: "LibGit2"),
      ]),
    .testTarget(
      name: "WorkroomGitTests",
      dependencies: ["WorkroomGit", "WorkroomDomain", "WorkroomVCS", "WorkroomSystem"]),
  ]
)
