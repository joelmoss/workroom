// swift-tools-version: 6.0
//
// The local git engine: reads on SwiftGitX (`GitProvider`), the libgit2 C API behind the three reads
// SwiftGitX cannot express (ADR 0002: only `LibGit2`, `GitGraph`, `GitCommitDiff` and
// `GitDiffStats` import it), the unified-diff model and its line algorithms, and writes through the
// real `git` CLI (`CLIVCSWriter`, serialized per project root by `RepositoryWriteGate`). It
// implements WorkroomVCS's local engine interfaces; routing, the daemon adapters and GitHub stay in
// the app. Its tests run with plain `swift test` (`make app-package-test`), with no app host.
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
    // SwiftGitX (libgit2, pure Swift) serves the local reads.
    .package(url: "https://github.com/ibrahimcetin/SwiftGitX", exact: "0.4.0"),
    // Raw libgit2, linked DIRECTLY as well as through SwiftGitX. SwiftGitX cannot express a commit
    // RANGE (its CommitSequence only calls git_revwalk_push, never git_revwalk_hide) and keeps its
    // repository pointer internal, so push-state reachability (`GitGraph`) needs the C API itself.
    // URL and version match SwiftGitX's own dependency EXACTLY (`.git` suffix included) so SwiftPM
    // resolves one package identity, not two (ADR 0002).
    .package(url: "https://github.com/ibrahimcetin/libgit2.git", exact: "1.9.2"),
  ],
  targets: [
    .target(
      name: "WorkroomGit",
      dependencies: [
        "WorkroomDomain", "WorkroomVCS", "WorkroomSystem",
        .product(name: "SwiftGitX", package: "SwiftGitX"),
        .product(name: "libgit2", package: "libgit2"),
      ]),
    .testTarget(
      name: "WorkroomGitTests",
      dependencies: ["WorkroomGit", "WorkroomDomain", "WorkroomVCS", "WorkroomSystem"]),
  ]
)
