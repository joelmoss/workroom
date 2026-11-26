// swift-tools-version: 6.0
//
// libgit2, built from the copy of an upstream release that macapp/Scripts/vendor-libgit2.sh
// vendors into libgit2/; VENDOR.md records which. Upstream ships no Package.swift, so this package
// stands in for it, with the configuration (git2_features.h) that script renders: upstream CMake's
// macOS defaults with every network transport off. Its product and module are `libgit2`, so code
// that does `import libgit2` reads the same as it did against a github.com package.
import PackageDescription

let package = Package(
  name: "LibGit2",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "libgit2", targets: ["libgit2"])
  ],
  targets: [
    // The sources are upstream's CMake globs for this configuration: the script copies exactly
    // those files, so whole directories are listed here.
    .target(
      name: "libgit2",
      path: "libgit2",
      exclude: ["COPYING", "deps/llhttp/LICENSE-MIT"],
      sources: ["src/libgit2", "src/util", "deps/xdiff", "deps/llhttp"],
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("src/libgit2"),
        .headerSearchPath("src/util"),
        .headerSearchPath("deps/xdiff"),
        .headerSearchPath("deps/llhttp"),
        // Upstream's cmake/DefaultCFlags.cmake adds this to every non-MSVC build, macOS included.
        .define("_GNU_SOURCE"),
        // Upstream's src/util/CMakeLists.txt sets these for the collision-detecting SHA-1.
        .define("SHA1DC_NO_STANDARD_INCLUDES", to: "1"),
        .define("SHA1DC_CUSTOM_INCLUDE_SHA1_C", to: "\"git2_util.h\""),
        .define("SHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C", to: "\"git2_util.h\""),
        // Upstream's code, which we do not patch. `-fno-modules` compiles its C files as CMake
        // does: with clang modules on, SwiftPM's default, the Darwin module brings in <search.h>,
        // whose `struct entry` clashes with xdiff's and the indexer's own (the fork renamed
        // theirs). `-w` silences upstream's warnings, as SwiftPM did for a github.com dependency.
        .unsafeFlags(["-fno-modules", "-w"]),
      ],
      linkerSettings: [
        // GIT_COMPRESSION_ZLIB and GIT_USE_ICONV: the system's zlib and iconv, as upstream's CMake
        // links on macOS. SHA-256 is CommonCrypto, which is in libSystem.
        .linkedLibrary("z"),
        .linkedLibrary("iconv"),
      ]),
    .testTarget(name: "LibGit2Tests", dependencies: ["libgit2"]),
  ]
)
