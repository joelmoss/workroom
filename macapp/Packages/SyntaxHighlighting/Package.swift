// swift-tools-version: 6.0
//
// Syntax highlighting: the tree-sitter runtime, its Swift wrapper and the bundled grammars, behind
// `SyntaxHighlighter`. The pins below moved here from project.yml with their reasons, so they are
// still the only record of why each grammar sits on the commit it does. The app's diff and file
// mappers, which need its diff model and theme, stay in the app and call this package.
import PackageDescription

let package = Package(
  name: "SyntaxHighlighting",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "SyntaxHighlighting", targets: ["SyntaxHighlighting"])
  ],
  dependencies: [
    // --- Syntax highlighting (issue: tree-sitter diff highlighting, phase 1 editor foundation) ---
    // The tree-sitter C runtime, used directly: parser, query and cursor. (The SwiftTreeSitter
    // wrapper was dropped in 2026-10: its match iteration cost four times the C cursor, and its
    // bundle search misfired under a hosted test.) Upstream dropped its Package.swift in 0.27.0, so
    // ../TreeSitter builds a vendored copy; macapp/Scripts/vendor-tree-sitter.sh bumps it, and its
    // VENDOR.md records the release. The runtime must keep accepting the grammar ABIs below.
    .package(path: "../TreeSitter"),
    // Each grammar ships a `Package.swift` whose library target (`dependencies: []`) compiles only
    // `src/parser.c` (+ `src/scanner.c` for external-scanner grammars) and copies `queries/` as a
    // resource bundle. Their own (test-only) SwiftTreeSitter dependency is pruned by SPM, so we link
    // just the C product. Pinned by EXACT COMMIT (the generated parser's ABI is tied to the runtime
    // above). TreeSitterBash carries an external scanner — the lane-A packaging proof.
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-json",
      revision: "001c28d7a29832b06b0e831ec77845553c89b56d"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-bash",
      revision: "a06c2e4415e9bc0346c6b86d401879ffb44058f7"),
    // The Swift grammar's `src/parser.c` is generated and committed only on the `with-generated-files`
    // branch (the default branch omits it), so we pin a commit from that branch — not `main`.
    .package(
      url: "https://github.com/alex-pinkus/tree-sitter-swift",
      revision: "82bb3a533e0801fd2bbaa11dc49676e10bf41948"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-go",
      revision: "2346a3ab1bb3857b48b29d779a1ef9799a248cd7"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-ruby",
      revision: "ad907a69da0c8a4f7a943a7fe012712208da6dee"),
    // JS/Python/CSS/YAML are vendored under Grammars/; their tags are pinned in
    // macapp/Scripts/vendor-tree-sitter-grammars.sh. From 0.25 (yaml 0.7.2), upstream's manifest
    // adds `src/scanner.c` only when `FileManager.fileExists` finds it, which is false under SwiftPM
    // (wrong CWD), so the external scanner is dropped and the link fails. Our manifests list it.
    .package(path: "Grammars/tree-sitter-javascript"),
    // One package, one product (`TreeSitterTypeScript`) wrapping two targets/modules:
    // `TreeSitterTypeScript` + `TreeSitterTSX`. Both link from the single product dependency.
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-typescript",
      revision: "75b3874edb2dc714fb1fd77a32013d0f8699989f"),
    .package(path: "Grammars/tree-sitter-python"),
    .package(path: "Grammars/tree-sitter-yaml"),
    .package(
      url: "https://github.com/tree-sitter-grammars/tree-sitter-toml",
      revision: "64b56832c2cffe41758f28e05c756a3a98d16f41"),
    // Split grammar (default branch `split_parser`): one product `TreeSitterMarkdown` over two
    // modules (block `TreeSitterMarkdown` + inline `TreeSitterMarkdownInline`). Phase 1 uses the block
    // grammar only (injections/inline are deferred), but linking the product pulls both.
    .package(
      url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
      revision: "41ff24a6c775492c543b09228aeb98d1cd2b3a0f"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-html",
      revision: "73a3947324f6efddf9e17c0ea58d454843590cc0"),
    .package(path: "Grammars/tree-sitter-css"),
    // Product/module is `TreeSitterSql` (lowercase `ql`), not `TreeSitterSQL`. Pinned to the
    // `gh-pages` branch, which vendors the generated `src/parser.c` + `src/tree_sitter/parser.h` that
    // `main` strips — without them the external scanner can't find `tree_sitter/parser.h` and won't
    // compile.
    .package(
      url: "https://github.com/DerekStride/tree-sitter-sql",
      revision: "2d088525f3f986108d969dab526a0d7129281e24"),
  ],
  targets: [
    .target(
      name: "SyntaxHighlighting",
      dependencies: [
        .product(name: "TreeSitter", package: "TreeSitter"),
        .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
        .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
        .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
        .product(name: "TreeSitterGo", package: "tree-sitter-go"),
        .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
        .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
        .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
        .product(name: "TreeSitterPython", package: "tree-sitter-python"),
        .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
        .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
        .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
        .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
        .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
        .product(name: "TreeSitterSql", package: "tree-sitter-sql"),
      ]),
    .testTarget(name: "SyntaxHighlightingTests", dependencies: ["SyntaxHighlighting"]),
  ]
)
