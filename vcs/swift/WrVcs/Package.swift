// swift-tools-version:6.0
import PackageDescription

// Local package wrapping the Workroom VCS Rust core for the app.
//
// Layout (all but this manifest + shim.c are produced by vcs/scripts/build-apple.sh and gitignored):
//   Frameworks/WrVcsFFI.xcframework          — LIBRARY-ONLY static xcframework (no headers)
//   Sources/wr_vcs_uniffiFFI/include/*        — the FFI header + modulemap (generated)
//   Sources/wr_vcs_uniffiFFI/shim.c           — empty TU so SPM accepts the C target (tracked)
//   Sources/WrVcs/wr_vcs_uniffi.swift         — the idiomatic Swift API (generated)
//
// Why a separate C target instead of shipping headers in the xcframework: a headers-bearing static
// xcframework copies its module.modulemap into the app's shared Debug/include/, colliding with
// GhosttyKit's. The C target keeps its modulemap namespaced; the xcframework provides only the
// static library (symbols).
let package = Package(
  name: "WrVcs",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WrVcs", targets: ["WrVcs"])
  ],
  targets: [
    .binaryTarget(name: "WrVcsLib", path: "Frameworks/WrVcsFFI.xcframework"),
    // C target whose module (`wr_vcs_uniffiFFI`, per include/module.modulemap) the generated Swift
    // imports. Target name == module name so SPM is happy.
    .target(name: "wr_vcs_uniffiFFI", path: "Sources/wr_vcs_uniffiFFI"),
    .target(
      name: "WrVcs",
      dependencies: ["wr_vcs_uniffiFFI", "WrVcsLib"],
      path: "Sources/WrVcs"
    ),
  ]
)
