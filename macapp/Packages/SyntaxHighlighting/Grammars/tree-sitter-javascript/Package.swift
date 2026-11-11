// swift-tools-version: 6.0
//
// One tree-sitter grammar, built from the upstream files that
// macapp/Scripts/vendor-tree-sitter-grammars.sh vendors here; VENDOR.md records the release. This
// manifest replaces upstream's, which adds `src/scanner.c` only when a FileManager check finds it,
// and SwiftPM runs that check from another directory. The package, product, module and
// resource-bundle names match upstream's, so SyntaxHighlighting's import and its
// `<Package>_<Target>` query bundle name are unchanged.
import PackageDescription

let package = Package(
  name: "TreeSitterJavaScript",
  products: [
    .library(name: "TreeSitterJavaScript", targets: ["TreeSitterJavaScript"])
  ],
  targets: [
    .target(
      name: "TreeSitterJavaScript",
      path: ".",
      sources: ["src/parser.c", "src/scanner.c"],
      resources: [.copy("queries")],
      publicHeadersPath: "bindings/swift",
      cSettings: [
        .headerSearchPath("src"),
        // Generated upstream code we do not patch: silence its warnings, as SwiftPM did when the
        // grammar was a github.com dependency.
        .unsafeFlags(["-w"]),
      ])
  ],
  cLanguageStandard: .c11
)
