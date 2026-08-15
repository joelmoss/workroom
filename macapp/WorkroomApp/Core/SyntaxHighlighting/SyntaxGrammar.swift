import Foundation
import SwiftTreeSitter
// Bundled tree-sitter grammars. Each `import` links one grammar's C parser (+ any `src/scanner.c`
// external scanner) and copies its `queries/` into an SPM resource bundle. Adding a language =
// pin the package in project.yml, import it here, add a `GrammarID` case with its `tree_sitter_*`
// pointer + query-bundle name, and map its extensions/filenames below.
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRuby
import TreeSitterSql
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// A bundled grammar. New-file content is parsed with this grammar and the highlight captures drive
/// the colours. Phase 1 ships ~14 languages; everything else (and the skip-list) renders plain.
enum GrammarID: String, CaseIterable, Sendable {
  case swift, go, ruby, javascript, typescript, tsx, python, json, yaml, toml, markdown, bash, html,
    css, sql

  /// The tree-sitter `TSLanguage` pointer from the grammar's C entry point.
  var tsLanguage: OpaquePointer {
    switch self {
    case .swift: return tree_sitter_swift()
    case .go: return tree_sitter_go()
    case .ruby: return tree_sitter_ruby()
    case .javascript: return tree_sitter_javascript()
    case .typescript: return tree_sitter_typescript()
    case .tsx: return tree_sitter_tsx()
    case .python: return tree_sitter_python()
    case .json: return tree_sitter_json()
    case .yaml: return tree_sitter_yaml()
    case .toml: return tree_sitter_toml()
    case .markdown: return tree_sitter_markdown()
    case .bash: return tree_sitter_bash()
    case .html: return tree_sitter_html()
    case .css: return tree_sitter_css()
    case .sql: return tree_sitter_sql()
    }
  }

  /// The SPM resource-bundle directory name (`<package>_<target>`) holding this grammar's
  /// `queries/highlights.scm`. Usually `TreeSitter<X>_TreeSitter<X>`, but two grammars differ: TSX
  /// is a second target inside the TypeScript *package*, and SQL's module is `TreeSitterSql`.
  var queryBundleName: String {
    switch self {
    case .swift: return "TreeSitterSwift_TreeSitterSwift"
    case .go: return "TreeSitterGo_TreeSitterGo"
    case .ruby: return "TreeSitterRuby_TreeSitterRuby"
    case .javascript: return "TreeSitterJavaScript_TreeSitterJavaScript"
    case .typescript: return "TreeSitterTypeScript_TreeSitterTypeScript"
    case .tsx: return "TreeSitterTypeScript_TreeSitterTSX"
    case .python: return "TreeSitterPython_TreeSitterPython"
    case .json: return "TreeSitterJSON_TreeSitterJSON"
    case .yaml: return "TreeSitterYAML_TreeSitterYAML"
    case .toml: return "TreeSitterTOML_TreeSitterTOML"
    case .markdown: return "TreeSitterMarkdown_TreeSitterMarkdown"
    case .bash: return "TreeSitterBash_TreeSitterBash"
    case .html: return "TreeSitterHTML_TreeSitterHTML"
    case .css: return "TreeSitterCSS_TreeSitterCSS"
    case .sql: return "TreeSitterSql_TreeSitterSql"
    }
  }
}

/// The extension/filename → grammar registry, plus the skip-list and byte cap. Pure and
/// synchronous so `detect` is trivially unit-testable; `nil` always means "render plain".
enum SyntaxLanguage {
  /// Files at or above this size are never parsed (a 100MB file behind a 1-line diff would stall
  /// the parse and the byte↔offset arrays). The caller falls back to plain. Matches the diff
  /// runner's own 4MB output cap intent — we never parse far more than the diff itself showed.
  static let byteCap = 2 * 1024 * 1024

  /// Lowercased file extension → grammar.
  static let byExtension: [String: GrammarID] = [
    "swift": .swift,
    "go": .go,
    "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "ru": .ruby,
    "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
    "ts": .typescript, "mts": .typescript, "cts": .typescript,
    "tsx": .tsx,
    "py": .python, "pyi": .python, "pyw": .python,
    "json": .json, "jsonc": .json,
    "yml": .yaml, "yaml": .yaml,
    "toml": .toml,
    "md": .markdown, "markdown": .markdown,
    "sh": .bash, "bash": .bash, "zsh": .bash,
    "html": .html, "htm": .html, "xhtml": .html,
    "css": .css,
    "sql": .sql,
  ]

  /// Exact (case-sensitive) filename → grammar, for extension-less or specially-named files.
  static let byFilename: [String: GrammarID] = [
    "Gemfile": .ruby, "Rakefile": .ruby, "Guardfile": .ruby, "Podfile": .ruby, "Brewfile": .ruby,
    ".bashrc": .bash, ".bash_profile": .bash, ".zshrc": .bash, ".zprofile": .bash,
    ".profile": .bash,
  ]

  /// Exact filenames that must render plain even though their extension would otherwise match a
  /// grammar — lockfiles (huge, machine-generated, no value highlighted) and friends.
  static let skipFilenames: Set<String> = [
    "package-lock.json", "Gemfile.lock", "Cargo.lock", "yarn.lock", "pnpm-lock.yaml",
    "go.sum", "Package.resolved", "composer.lock", "poetry.lock", "flake.lock",
  ]

  /// Lowercased extensions that always render plain: data dumps, vector art, minified bundles,
  /// sourcemaps. Double extensions (`min.js`, `min.css`) are matched before the bare extension.
  static let skipExtensions: Set<String> = ["csv", "tsv", "svg", "min.js", "min.css", "map"]

  /// Grammar for a file, trying the path first (extension / known filename), then the **shebang** on
  /// the first line for an extension-less script (`#!/bin/bash`, `#!/usr/bin/env python3`). `nil` ⇒
  /// render plain. Used by the file viewer, which has the content to sniff.
  static func grammar(forPath path: String, firstLine: String?) -> GrammarID? {
    if let g = grammar(forPath: path) { return g }
    if let firstLine, let g = grammar(forShebang: firstLine) { return g }
    return nil
  }

  /// Map a shebang line to a grammar. Resolves the interpreter basename — unwrapping
  /// `/usr/bin/env [flags] <interp>` — and strips a version suffix (`python3.11` → python). Returns
  /// `nil` for a non-shebang line or an unknown interpreter. Pure + unit-tested.
  static func grammar(forShebang line: String) -> GrammarID? {
    guard line.hasPrefix("#!") else { return nil }
    let tokens = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(
      String.init)
    guard var interpreter = tokens.first.map({ ($0 as NSString).lastPathComponent }) else {
      return nil
    }
    // `env` defers to the first non-flag argument (its `-S`/`-i`… options are skipped).
    if interpreter == "env" {
      guard let next = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
      interpreter = (next as NSString).lastPathComponent
    }
    // Trim any trailing CR (a CRLF first line) / whitespace before matching.
    let name = interpreter.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if ["bash", "sh", "zsh", "dash", "ksh"].contains(name) { return .bash }
    if name.hasPrefix("python") { return .python }
    if name.hasPrefix("ruby") { return .ruby }
    if name.hasPrefix("node") || name == "nodejs" { return .javascript }
    return nil
  }

  /// Grammar for a single path, honouring the skip-list. `nil` if skip-listed or unknown.
  static func grammar(forPath path: String) -> GrammarID? {
    let name = (path as NSString).lastPathComponent
    if skipFilenames.contains(name) { return nil }

    let lowerName = name.lowercased()
    // Double extensions first (`.min.js`, `.min.css`) so a minified bundle is skipped before its
    // bare `js`/`css` would match.
    if let dot = lowerName.firstIndex(of: ".") {
      let fullExt = String(lowerName[lowerName.index(after: dot)...])
      if skipExtensions.contains(fullExt) { return nil }
    }

    if let g = byFilename[name] { return g }

    let ext = (lowerName as NSString).pathExtension
    if skipExtensions.contains(ext) { return nil }
    return byExtension[ext]
  }
}
