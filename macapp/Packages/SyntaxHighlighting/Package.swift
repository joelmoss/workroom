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
    // SwiftTreeSitter is the Swift wrapper over the tree-sitter C runtime: Language/Parser/Query +
    // the resource-bundle query loader (`LanguageConfiguration(_:name:)` finds each grammar's
    // `TreeSitter{name}_TreeSitter{name}` bundle and loads its `queries/highlights.scm`). Pinned
    // EXACT — the C ABI between the runtime and the pinned grammars must not drift under us.
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
    // The tree-sitter C runtime. Pulled transitively by SwiftTreeSitter, but declared explicitly so we
    // can `import TreeSitter` for the `TSInputEncodingUTF8` constant (SwiftTreeSitter exposes the
    // `TSInputEncoding` type in its API but does not re-export the C module's enum constants). Pinned
    // to the version SwiftTreeSitter 0.25.0 resolves, so there's no second copy of the runtime.
    .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
    // Each grammar ships a `Package.swift` whose library target (`dependencies: []`) compiles only
    // `src/parser.c` (+ `src/scanner.c` for external-scanner grammars) and copies `queries/` as a
    // resource bundle. Their own (test-only) SwiftTreeSitter dependency is pruned by SPM, so we link
    // just the C product and supply SwiftTreeSitter ourselves. Pinned by EXACT COMMIT (the generated
    // parser's ABI is tied to the runtime above). TreeSitterBash carries an external scanner — the
    // lane-A packaging proof.
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
      revision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-go",
      revision: "2346a3ab1bb3857b48b29d779a1ef9799a248cd7"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-ruby",
      revision: "ad907a69da0c8a4f7a943a7fe012712208da6dee"),
    // JS/Python/CSS/YAML are pinned to the newest tag whose Package.swift HARDCODES
    // `sources: ["src/parser.c", "src/scanner.c"]`. Their later tags switched to a
    // `FileManager.fileExists("src/scanner.c")` check that evaluates false under Xcode's SPM (wrong
    // CWD), silently dropping the external scanner and breaking the link.
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-javascript",
      revision: "3a837b6f3658ca3618f2022f8707e29739c91364"),
    // One package, one product (`TreeSitterTypeScript`) wrapping two targets/modules:
    // `TreeSitterTypeScript` + `TreeSitterTSX`. Both link from the single product dependency.
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-typescript",
      revision: "75b3874edb2dc714fb1fd77a32013d0f8699989f"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-python",
      revision: "bffb65a8cfe4e46290331dfef0dbf0ef3679de11"),
    .package(
      url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml",
      revision: "b733d3f5f5005890f324333dd57e1f0badec5c87"),
    .package(
      url: "https://github.com/tree-sitter-grammars/tree-sitter-toml",
      revision: "64b56832c2cffe41758f28e05c756a3a98d16f41"),
    // Split grammar (default branch `split_parser`): one product `TreeSitterMarkdown` over two
    // modules (block `TreeSitterMarkdown` + inline `TreeSitterMarkdownInline`). Phase 1 uses the block
    // grammar only (injections/inline are deferred), but linking the product pulls both.
    .package(
      url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
      revision: "c3570720f7f7bbad22fe96603f106276618e0cf5"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-html",
      revision: "73a3947324f6efddf9e17c0ea58d454843590cc0"),
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-css",
      revision: "c0d581e32d183a536731ed6c3a72758b27e20411"),
    // Product/module is `TreeSitterSql` (lowercase `ql`), not `TreeSitterSQL`. Pinned to the
    // `gh-pages` branch, which vendors the generated `src/parser.c` + `src/tree_sitter/parser.h` that
    // `main` strips — without them the external scanner can't find `tree_sitter/parser.h` and won't
    // compile.
    .package(
      url: "https://github.com/DerekStride/tree-sitter-sql",
      revision: "851e9cb257ba7c66cc8c14214a31c44d2f1e954e"),
  ],
  targets: [
    .target(
      name: "SyntaxHighlighting",
      dependencies: [
        .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
        .product(name: "TreeSitter", package: "tree-sitter"),
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
