// swift-tools-version: 6.0
//
// The tree-sitter C runtime (parser, query and cursor), built from the copy of upstream's `lib/`
// that macapp/Scripts/vendor-tree-sitter.sh vendors; VENDOR.md records its release. Upstream
// dropped its own Package.swift in 0.27.0, so this package stands in for it, and keeps its
// `TreeSitter` product and module names so SyntaxHighlighting's `import TreeSitter` is unchanged.
import PackageDescription

let package = Package(
  name: "TreeSitter",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "TreeSitter", targets: ["TreeSitter"])
  ],
  targets: [
    // The flags are upstream Makefile's: one amalgamated `lib.c` (which #includes every other
    // source file), C11 and its four feature-test macros. The source list is written out, not
    // probed: a FileManager check evaluates under the wrong directory in Xcode's SwiftPM. Wasm
    // stays off, so `wasm_store.c` compiles to nothing and `wasm-stdlib/` is never included.
    .target(
      name: "TreeSitter",
      path: "lib",
      sources: ["src/lib.c"],
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("src"),
        .define("_POSIX_C_SOURCE", to: "200112L"),
        .define("_DEFAULT_SOURCE"),
        .define("_BSD_SOURCE"),
        .define("_DARWIN_C_SOURCE"),
        // Upstream's code, which we do not patch: silence its warnings (parser.c trips
        // -Wshorten-64-to-32), as SwiftPM did when the runtime was a github.com dependency.
        .unsafeFlags(["-w"]),
      ]),
    .testTarget(name: "TreeSitterTests", dependencies: ["TreeSitter"]),
  ],
  cLanguageStandard: .c11
)
