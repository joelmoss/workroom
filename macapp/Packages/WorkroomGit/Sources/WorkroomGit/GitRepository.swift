import Foundation
import libgit2

/// One opened repository and the libgit2 reads `GitProvider` maps into the app's models: history,
/// HEAD and branches, tags, working-tree status, blobs and single-file patches. Everything it returns
/// is a Swift value (`Commit`, `Delta`, `StatusEntry`, `Patch`), so no libgit2 pointer outlives the
/// `read` that opened the repository.
final class GitRepository {
  private let pointer: OpaquePointer

  private init(pointer: OpaquePointer) {
    self.pointer = pointer
  }

  /// Open the repository at `root` (not a search upward: `root` is its working directory), run
  /// `body`, and free the handle when `body` returns.
  static func read<T>(_ root: URL, _ body: (GitRepository) throws -> T) throws -> T {
    try LibGit2.withOpenedRepository(root) { try body(GitRepository(pointer: $0)) }
  }

  // MARK: - Values

  /// A commit's fields as the app reads them. `date` is the committer time, as `git log` sorts by.
  struct Commit {
    let id: String
    /// The first 8 hex digits of `id`.
    let shortID: String
    let authorName: String
    let authorEmail: String
    let summary: String
    let message: String
    let date: Date
    let treeID: git_oid
    /// The parents, or `nil` when any of them can't be read (a shallow clone's boundary): callers
    /// then treat the commit as having none.
    let parentIDs: [String]?
  }

  /// A diff delta: what changed for one path, from a status entry or a patch.
  struct Delta {
    let type: git_delta_t
    let oldPath: String
    let newPath: String
    let oldID: git_oid
    let newID: git_oid
    let isBinary: Bool

    init(_ raw: git_diff_delta) {
      type = raw.status
      oldPath = raw.old_file.path.map { String(cString: $0) } ?? ""
      newPath = raw.new_file.path.map { String(cString: $0) } ?? ""
      oldID = raw.old_file.id
      newID = raw.new_file.id
      isBinary = raw.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0
    }
  }

  /// One path's working-tree status: its `GIT_STATUS_*` flags, and its HEAD→index and index→worktree
  /// deltas.
  struct StatusEntry {
    let flags: UInt32
    let index: Delta?
    let workingTree: Delta?

    func has(_ status: git_status_t) -> Bool { flags & status.rawValue != 0 }
  }

  /// A single-file patch: its delta and hunks, each line with libgit2's origin character
  /// (`GIT_DIFF_LINE_*`) and its content, trailing newline included.
  struct Patch {
    struct Hunk {
      let header: String
      let lines: [(origin: CChar, content: String)]
    }

    let delta: Delta
    let hunks: [Hunk]
  }

  // MARK: - HEAD and history

  /// HEAD names a branch with no commit yet (`git init`, nothing committed).
  var isHEADUnborn: Bool { git_repository_head_unborn(pointer) == 1 }

  /// The commit HEAD resolves to, attached or detached.
  func headCommitID() throws -> String {
    var oid = git_oid()
    try LibGit2.check(git_reference_name_to_id(&oid, pointer, "HEAD"), "resolve HEAD")
    return LibGit2.hexString(&oid)
  }

  /// The branch HEAD is attached to, or `nil` when HEAD is detached, unborn or unreadable.
  func currentBranchName() -> String? {
    var head: OpaquePointer?
    guard git_repository_head(&head, pointer) == 0, let head else { return nil }
    defer { git_reference_free(head) }
    guard git_reference_is_branch(head) == 1, let name = git_reference_shorthand(head) else {
      return nil
    }
    return String(cString: name)
  }

  /// `init.defaultBranch` from the repository's config (its own, then global and system), or `nil`
  /// when it is unset: what an unborn HEAD's branch is labelled with.
  func defaultBranchName() -> String? {
    var config: OpaquePointer?
    guard git_repository_config(&config, pointer) == 0, let config else { return nil }
    defer { git_config_free(config) }
    var buffer = git_buf()
    defer { git_buf_dispose(&buffer) }
    guard git_config_get_string_buf(&buffer, config, "init.defaultBranch") == 0,
      let raw = buffer.ptr
    else { return nil }
    return String(cString: raw)
  }

  /// Up to `limit` commits reachable from HEAD, in libgit2's default walk order (`GIT_SORT_NONE`,
  /// which its header calls git's default: reverse chronological). The walk stops early, without an
  /// error, at the first commit it can't read.
  func log(limit: Int) throws -> [Commit] {
    var head = git_oid()
    try LibGit2.check(git_reference_name_to_id(&head, pointer, "HEAD"), "resolve HEAD")
    var walk: OpaquePointer?
    try LibGit2.check(git_revwalk_new(&walk, pointer), "git_revwalk_new")
    defer { git_revwalk_free(walk) }
    try LibGit2.check(git_revwalk_sorting(walk, GIT_SORT_NONE.rawValue), "git_revwalk_sorting")
    try LibGit2.check(git_revwalk_push(walk, &head), "git_revwalk_push(HEAD)")

    var commits: [Commit] = []
    var oid = git_oid()
    while commits.count < limit, git_revwalk_next(&oid, walk) == 0 {
      guard let commit = try? commit(oid) else { break }
      commits.append(commit)
    }
    return commits
  }

  /// The commit with the 40-hex id `hex`.
  func commit(hex: String) throws -> Commit {
    var oid = git_oid()
    try LibGit2.check(git_oid_fromstr(&oid, hex), "git_oid_fromstr(\(hex))")
    return try commit(oid)
  }

  private func commit(_ oid: git_oid) throws -> Commit {
    var oid = oid
    var raw: OpaquePointer?
    try LibGit2.check(git_commit_lookup(&raw, pointer, &oid), "git_commit_lookup")
    guard let raw else {
      throw LibGit2.Failure(operation: "git_commit_lookup", code: -1, reason: nil)
    }
    defer { git_commit_free(raw) }

    let author = git_commit_author(raw).pointee
    let id = LibGit2.hexString(git_commit_id(raw))
    return Commit(
      id: id,
      shortID: String(id.prefix(8)),
      authorName: author.name.map { String(cString: $0) } ?? "",
      authorEmail: author.email.map { String(cString: $0) } ?? "",
      summary: git_commit_summary(raw).map { String(cString: $0) } ?? "",
      message: git_commit_message(raw).map { String(cString: $0) } ?? "",
      date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(raw))),
      treeID: git_commit_tree_id(raw).pointee,
      parentIDs: Self.parentIDs(of: raw))
  }

  /// Each parent's id, `nil` if any parent object is missing. Looked up rather than read from the
  /// commit's header, so a shallow boundary reads as parentless rather than naming absent commits.
  private static func parentIDs(of commit: OpaquePointer) -> [String]? {
    var ids: [String] = []
    for index in 0..<git_commit_parentcount(commit) {
      var parent: OpaquePointer?
      guard git_commit_parent(&parent, commit, index) == 0, let parent else { return nil }
      ids.append(LibGit2.hexString(git_commit_id(parent)))
      git_commit_free(parent)
    }
    return ids
  }

  // MARK: - Refs

  /// Every local branch's name and the commit it points at. A branch whose target can't be resolved
  /// is left out, and the rest still are listed.
  func localBranches() -> [(name: String, target: String)] {
    var iterator: OpaquePointer?
    guard git_branch_iterator_new(&iterator, pointer, GIT_BRANCH_LOCAL) == 0 else { return [] }
    defer { git_branch_iterator_free(iterator) }
    var branches: [(name: String, target: String)] = []
    var reference: OpaquePointer?
    var type = GIT_BRANCH_LOCAL
    while git_branch_next(&reference, &type, iterator) == 0, let ref = reference {
      defer { git_reference_free(ref) }
      var oid = git_oid()
      guard let name = git_reference_shorthand(ref), let fullName = git_reference_name(ref),
        git_reference_name_to_id(&oid, pointer, fullName) == 0
      else { continue }
      branches.append((String(cString: name), LibGit2.hexString(&oid)))
    }
    return branches
  }

  /// Every tag's name and the id of the object it finally names, following annotated tags (and
  /// tags of tags) to the first object that is not a tag. An unreadable tag is left out, and the
  /// rest still are listed.
  func tags() -> [(name: String, target: String)] {
    var names = git_strarray()
    guard git_tag_list(&names, pointer) == 0 else { return [] }
    defer { git_strarray_dispose(&names) }
    var tags: [(name: String, target: String)] = []
    for index in 0..<names.count {
      guard let raw = names.strings[index] else { continue }
      let name = String(cString: raw)
      var reference: OpaquePointer?
      guard git_reference_lookup(&reference, pointer, "refs/tags/\(name)") == 0, let reference
      else { continue }
      defer { git_reference_free(reference) }
      var object: OpaquePointer?
      guard git_reference_peel(&object, reference, GIT_OBJECT_ANY) == 0, let object else {
        continue
      }
      defer { git_object_free(object) }
      tags.append((name, LibGit2.hexString(git_object_id(object))))
    }
    return tags
  }

  // MARK: - Working tree

  /// The working directory, with a trailing slash.
  func workingDirectory() throws -> URL {
    guard let raw = git_repository_workdir(pointer) else {
      throw LibGit2.Failure(
        operation: "git_repository_workdir", code: -1, reason: "bare repository")
    }
    return URL(fileURLWithPath: String(cString: raw), isDirectory: true)
  }

  /// `git_status_list_new` with exactly `flags` (`GIT_STATUS_OPT_*`), one entry per path.
  func status(flags: [git_status_opt_t]) throws -> [StatusEntry] {
    var options = git_status_options()
    try LibGit2.check(
      git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)),
      "git_status_options_init")
    options.flags = flags.reduce(0) { $0 | $1.rawValue }
    var list: OpaquePointer?
    try LibGit2.check(git_status_list_new(&list, pointer, &options), "git_status_list_new")
    defer { git_status_list_free(list) }
    return (0..<git_status_list_entrycount(list)).compactMap { index in
      guard let entry = git_status_byindex(list, index)?.pointee else { return nil }
      return StatusEntry(
        flags: entry.status.rawValue,
        index: entry.head_to_index.map { Delta($0.pointee) },
        workingTree: entry.index_to_workdir.map { Delta($0.pointee) })
    }
  }

  // MARK: - Objects

  /// The bytes of the blob `id`. Throws when `id` is missing or not a blob.
  func blobContent(_ id: git_oid) throws -> Data {
    try withBlob(id) { blob in
      guard let bytes = git_blob_rawcontent(blob) else { return Data() }
      return Data(bytes: bytes, count: Int(git_blob_rawsize(blob)))
    }
  }

  /// The blob at `path` in `commit`'s tree, or `nil` when the path is absent or not a blob. Throws
  /// when a tree on the way can't be read (a missing or corrupt object), rather than reading as absent.
  func blobID(at path: String, in commit: Commit) throws -> git_oid? {
    var treeID = commit.treeID
    var tree: OpaquePointer?
    try LibGit2.check(git_tree_lookup(&tree, pointer, &treeID), "git_tree_lookup")
    defer { git_tree_free(tree) }
    var entry: OpaquePointer?
    let code = git_tree_entry_bypath(&entry, tree, path)
    if code == GIT_ENOTFOUND.rawValue { return nil }
    try LibGit2.check(code, "git_tree_entry_bypath(\(path))")
    guard let entry else { return nil }
    defer { git_tree_entry_free(entry) }
    guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return nil }
    return git_tree_entry_id(entry).pointee
  }

  // MARK: - Patches

  /// The patch from blob `old` to blob `new`, either side `nil` for none (an add or a delete).
  /// Throws when a given id is missing or not a blob.
  func patch(fromBlob old: git_oid?, toBlob new: git_oid?) throws -> Patch {
    try withOptionalBlob(old) { oldBlob in
      try withOptionalBlob(new) { newBlob in
        var patch: OpaquePointer?
        try LibGit2.check(
          git_patch_from_blobs(&patch, oldBlob, nil, newBlob, nil, nil), "git_patch_from_blobs")
        defer { git_patch_free(patch) }
        return Self.patch(patch)
      }
    }
  }

  /// The patch from blob `old` (`nil` for none) to the bytes of `file` on disk now. Throws when
  /// `file` can't be read, or `old` is missing or not a blob.
  func patch(fromBlob old: git_oid?, toFile file: URL) throws -> Patch {
    let content = try Data(contentsOf: file)
    return try withOptionalBlob(old) { oldBlob in
      try content.withUnsafeBytes { bytes in
        var patch: OpaquePointer?
        try LibGit2.check(
          git_patch_from_blob_and_buffer(
            &patch, oldBlob, nil, bytes.baseAddress, bytes.count, nil, nil),
          "git_patch_from_blob_and_buffer(\(file.path))")
        defer { git_patch_free(patch) }
        return Self.patch(patch)
      }
    }
  }

  private static func patch(_ patch: OpaquePointer?) -> Patch {
    let delta = Delta(git_patch_get_delta(patch).pointee)
    var hunks: [Patch.Hunk] = []
    for hunkIndex in 0..<git_patch_num_hunks(patch) {
      var hunk: UnsafePointer<git_diff_hunk>?
      var lineCount = 0
      guard git_patch_get_hunk(&hunk, &lineCount, patch, hunkIndex) == 0, let hunk else {
        continue
      }
      var lines: [(origin: CChar, content: String)] = []
      for lineIndex in 0..<lineCount {
        var line: UnsafePointer<git_diff_line>?
        guard git_patch_get_line_in_hunk(&line, patch, hunkIndex, lineIndex) == 0,
          let line = line?.pointee
        else { continue }
        let content = UnsafeRawBufferPointer(start: line.content, count: line.content_len)
        lines.append((line.origin, String(decoding: content, as: UTF8.self)))
      }
      let header = withUnsafeBytes(of: hunk.pointee.header) { bytes in
        String(decoding: bytes.prefix(hunk.pointee.header_len), as: UTF8.self)
      }
      hunks.append(Patch.Hunk(header: header, lines: lines))
    }
    return Patch(delta: delta, hunks: hunks)
  }

  private func withBlob<T>(_ id: git_oid, _ body: (OpaquePointer) throws -> T) throws -> T {
    var id = id
    var blob: OpaquePointer?
    try LibGit2.check(git_blob_lookup(&blob, pointer, &id), "git_blob_lookup")
    guard let blob else {
      throw LibGit2.Failure(operation: "git_blob_lookup", code: -1, reason: nil)
    }
    defer { git_blob_free(blob) }
    return try body(blob)
  }

  private func withOptionalBlob<T>(_ id: git_oid?, _ body: (OpaquePointer?) throws -> T) throws
    -> T
  {
    guard let id else { return try body(nil) }
    return try withBlob(id) { try body($0) }
  }
}
