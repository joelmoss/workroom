import Foundation

/// File tree for the inspector's **Files** section: list the selected repo's working tree (honoring
/// VCS ignores), show it as a collapsible tree, and open a file read-only in the main pane. This
/// file is the pure, engine-free core — VCS command construction + output parsing, the flat-list →
/// tree builder, and the tree → visible-rows flattener — all unit-tested without shelling out or a
/// view (`FileTreeTests`). The live data source (`FileTreeModel`) and the SwiftUI panel
/// (`FilesPanel`) build on these.

// MARK: - Content-tab payload

/// The `.file` payload of a content tab: a repo-relative file shown read-only in the main pane.
/// Sibling of `DiffDescriptor` — a value type, so retargeting the preview mutates a copy in place
/// and reassigns it, keeping the tab's id (and thus its strip slot / split position) stable.
struct FileDescriptor: Equatable, Hashable, Sendable {
  /// Repo-relative path (resolved against the workroom directory).
  var path: String
  /// True while this is the target's single preview tab (italic chip, replaced by the next preview);
  /// false once persisted ("Keep Open" / double-click / opened persistently).
  var isPreview: Bool

  /// Two descriptors address the *same* file tab when they point at the same path — the identity used
  /// to dedupe (re-select an already-open file) and to retarget the preview. The preview flag is
  /// deliberately excluded, mirroring `DiffDescriptor.sameFile`.
  func sameFile(as other: FileDescriptor) -> Bool { path == other.path }
}

extension FileDescriptor: ContentDescriptor {
  func makeTabContent() -> TabContent { .file(self) }
  func matches(_ content: TabContent) -> Bool {
    if case .file(let f) = content { return f.sameFile(as: self) }
    return false
  }
}

// MARK: - Tree model (pure)

/// A node in the repo file tree: a directory (with sorted children) or a file leaf. Built by
/// `FileTreeBuilder`; `children == nil` marks a file leaf (vs. `[]` — an empty directory, which a
/// flat file listing never produces but the type still distinguishes).
struct FileNode: Identifiable, Equatable, Sendable {
  /// The last path component (display name).
  let name: String
  /// The repo-relative path (`"src/app/main.swift"`) — also the stable identity.
  let path: String
  let isDirectory: Bool
  /// Sorted children (directories first, then files; each group alpha, case-insensitive). `nil` for
  /// a file leaf.
  let children: [FileNode]?

  var id: String { path }
}

/// One visible row of the tree: a node plus its indent depth. Produced by flattening the tree
/// against the set of expanded directory paths — the Files panel renders these as an indented list
/// (it lives inside the inspector's own scroll view, so it can't host a `List`/`OutlineGroup`).
struct FileTreeRow: Equatable {
  let node: FileNode
  let depth: Int
}

/// Pure builders for the Files panel: a flat list of repo-relative paths → a sorted `FileNode` tree,
/// and a tree + expansion set → the visible rows. No I/O, no view — unit-tested directly.
enum FileTreeBuilder {
  /// Build the sorted tree from a flat list of repo-relative file paths (as `git ls-files` / `jj file
  /// list` emit them). Intermediate directories are synthesised; duplicates collapse; each level is
  /// sorted directories-first then alpha (case-insensitive). Empty / `.`-only components are skipped.
  static func build(from relativePaths: [String]) -> [FileNode] {
    let root = MutableNode(name: "", path: "")
    for raw in relativePaths {
      let components = raw.split(separator: "/").map(String.init).filter {
        $0 != "." && !$0.isEmpty
      }
      guard !components.isEmpty else { continue }
      var node = root
      var accumulated = ""
      for (index, component) in components.enumerated() {
        accumulated = accumulated.isEmpty ? component : accumulated + "/" + component
        let isLeaf = index == components.count - 1
        if let existing = node.children[component] {
          // A path already seen as a directory prefix wins over a later "leaf" claim (can't really
          // happen from a flat file list, but keep directories sticky).
          node = existing
        } else {
          let child = MutableNode(name: component, path: accumulated, isFileLeaf: isLeaf)
          node.children[component] = child
          node = child
        }
      }
    }
    return root.sortedChildren()
  }

  /// Flatten the tree into the rows currently visible, given which directory paths are expanded.
  /// A collapsed directory contributes its own row but none of its descendants.
  static func flatten(_ roots: [FileNode], expanded: Set<String>, depth: Int = 0) -> [FileTreeRow] {
    var rows: [FileTreeRow] = []
    for node in roots {
      rows.append(FileTreeRow(node: node, depth: depth))
      if node.isDirectory, expanded.contains(node.path), let children = node.children {
        rows.append(contentsOf: flatten(children, expanded: expanded, depth: depth + 1))
      }
    }
    return rows
  }

  /// Mutable scratch node used only while building; converted to the immutable `FileNode` tree.
  private final class MutableNode {
    let name: String
    let path: String
    /// Starts as a file leaf only if created for the last component; gains children → becomes a dir.
    private var isFileLeaf: Bool
    var children: [String: MutableNode] = [:]

    init(name: String, path: String, isFileLeaf: Bool = false) {
      self.name = name
      self.path = path
      self.isFileLeaf = isFileLeaf
    }

    /// A node with children is a directory regardless of how it was first created.
    private var isDirectory: Bool { !children.isEmpty || !isFileLeaf }

    func sortedChildren() -> [FileNode] {
      children.values
        .map { child -> FileNode in
          let dir = child.isDirectory
          return FileNode(
            name: child.name, path: child.path, isDirectory: dir,
            children: dir ? child.sortedChildren() : nil)
        }
        .sorted(by: FileTreeBuilder.order)
    }
  }

  /// Directories before files; within a group, case-insensitive alphabetical, ties broken by the
  /// exact name so the order is total (stable across runs).
  private static func order(_ a: FileNode, _ b: FileNode) -> Bool {
    if a.isDirectory != b.isDirectory { return a.isDirectory }
    let byName = a.name.localizedCaseInsensitiveCompare(b.name)
    return byName == .orderedSame ? a.name < b.name : byName == .orderedAscending
  }
}

// MARK: - VCS listing (pure)

/// Which VCS lists the working tree. The Files panel probes git first (covers git worktrees and
/// colocated jj repos), then jj (a non-colocated jj workspace has no `.git` of its own).
enum FileListVCS: Equatable, Sendable {
  case git
  case jj
}

/// Pure command construction + output parsing for the working-tree listing, so the args and the
/// path-cleanup are unit-tested without spawning git/jj.
enum FileListing {
  /// The executable + args that list the working tree honoring ignore rules.
  /// - git: tracked + untracked-but-not-ignored, NUL-separated (`-z`) so odd filenames survive.
  /// - jj: the working-copy files (jj auto-tracks, so this reflects new files too).
  static func command(_ vcs: FileListVCS) -> (executable: String, args: [String]) {
    switch vcs {
    case .git: return ("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    case .jj: return ("jj", ["file", "list"])
    }
  }

  /// Parse a listing command's stdout into clean repo-relative paths. git output is NUL-separated
  /// (never split on newlines — a filename may legitimately contain spaces or a newline, which is
  /// exactly why `-z` is used); jj output is newline-separated (split on any newline — `\n`, `\r\n`,
  /// or `\r` — via `isNewline`, since Swift treats `\r\n` as a *single* Character that a literal
  /// `"\n"` split would miss). Empties and a leading `./` are dropped.
  static func parse(_ stdout: String, vcs: FileListVCS) -> [String] {
    let raw: [Substring]
    switch vcs {
    case .git:
      raw = stdout.split(separator: "\0", omittingEmptySubsequences: true)
    case .jj:
      raw = stdout.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
    }
    return
      raw
      .map(String.init)
      .filter { !$0.isEmpty }
      .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
  }
}
