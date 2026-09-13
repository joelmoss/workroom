import Foundation

/// Which working-copy revision a `workingFileDiff` is against — backend-neutral so `DiffResolver`
/// maps its UI `DiffSource` onto it without knowing the backend:
///   - `.workingCopy` — the uncommitted changes: git = worktree/index vs `HEAD`; jj = `@` (vs `@-`).
///   - `.parent`      — jj only: the working copy's parent (`@-`) own changes (vs `@--`). Git has no
///     equivalent surface (git repos never request it) and reports it unsupported.
enum VCSWorkingDiffBase: Sendable, Equatable {
  case workingCopy
  case parent
}

/// The single seam the app reads VCS data through. Two implementations — `RustJJProvider` (jj, over
/// the Rust/UniFFI core) and `GitProvider` (git, over SwiftGitX) — both return the app-native models
/// in `VCSModels.swift`. Views/models depend on this protocol, not on either backend.
///
/// `workingStatus` was for a long time the one VCS read NOT on here, because the two backends
/// returned differently-shaped concrete types and `WorkroomStatusResolver` bridged each by hand. It
/// is on here now: a protocol whose shape depends on which backend implements it is one a third
/// implementation cannot satisfy, and a remote backend is exactly that third implementation
/// (issue #154, Phase 2).
protocol VCSProviding: Sendable {
  /// A bounded, newest-first page of history.
  ///
  /// "Newest-first" is deliberately each backend's OWN CLI order, not a shared one — the page is what
  /// `jj log` / `git log` would print, so History never contradicts the tool the user reaches for:
  /// jj is topological (children before parents, jj-lib's descending commit position), while git is
  /// reverse-chronological (libgit2's default `GIT_SORT_NONE`, matching git's date-ordered default
  /// rather than its opt-in `--topo-order`). So a repo with out-of-order commit timestamps can page
  /// differently on the two backends by design; don't "unify" it without changing both CLIs' truth.
  func log(root: URL, limit: Int) throws -> VCSHistoryPage
  /// A single changeset: metadata + full message + changed-file list.
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset
  /// The per-file diff for one path within a changeset, as git-format unified-diff text (fed to the
  /// existing `UnifiedDiff` parser / `DiffViewer`). Lazy — the detail view fetches it on selection.
  func fileDiff(root: URL, commitID: String, path: String) async throws -> String
  /// The per-file diff for one path in the working copy (or its parent), as git-format unified-diff
  /// text — the working-copy counterpart of `fileDiff`. Lazy, per-file (never a whole-tree diff).
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String
  /// The full content of `path` at revision `rev` (a git commit id, or a jj revset like `@-`), for
  /// syntax-highlighting a diff's new side. `nil` ⇒ absent at that rev / binary / over the highlight
  /// cap → the caller renders plain. Read-only; must not take the jj working-copy lock (jj uses
  /// `--ignore-working-copy`).
  func fileContent(root: URL, rev: String, path: String) async throws -> String?
  /// The pre-image (old side) content of `path` for a commit's file diff — the file at the commit's
  /// first parent — for syntax-highlighting the diff's DELETED lines. The backend resolves its own
  /// parent (git `^` / jj `-`). `nil` ⇒ added at this commit (no parent version) / root commit /
  /// merge / binary / over cap → deletions render plain. Read-only; must not lock the jj working copy.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String?
  /// The pre-image content of `path` for a working-copy file diff's base (git `HEAD`; jj `@-` for
  /// `.workingCopy`, `@--` for `.parent`), for highlighting the diff's deleted lines. `nil` ⇒
  /// absent / unsupported base / binary / over cap → deletions render plain.
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  /// The working copy's status: dirty flag, changed files, ± line counts, and the branch CI should
  /// be looked up for. Synchronous and throwing, with no timeout of its own — callers that need one
  /// wrap it (`WorkroomStatusResolver` bounds it with `withTimeout` and, for jj, serialises it
  /// through `JJSnapshotGate`).
  ///
  /// **The one read that mutates, on jj.** jj's working copy is itself a commit, so on-disk edits do
  /// not exist to jj-lib until snapshotted — this takes the working-copy lock and rewrites `@`.
  /// Every other method on this protocol is read-only. That asymmetry is why the resolver gates this
  /// one per project root and none of the others.
  ///
  /// Returns a `WorkroomStatus` with `ci`, `failure` and `localReadAt` unset: those are the
  /// resolver's to fill, not a backend's.
  func workingStatus(root: URL) throws -> WorkroomStatus

  /// The repo's current ref for the sidebar root-row label — the `@` bookmark / nearest ancestor
  /// bookmark (jj) or current branch / short SHA (git). Read-only; must not take the jj working-copy
  /// lock (backs `BranchResolver`).
  func currentRef(root: URL) async throws -> VCSRef
}

extension VCSProviding {
  /// Default: **throws**, rather than reporting a clean working copy.
  ///
  /// The two real backends both implement this; the default exists for conformers that are not a
  /// VCS at all — the test stubs that drive History and diff resolution, which never ask for
  /// status. It throws rather than returning an empty `WorkroomStatus` on purpose: a backend that
  /// silently reported every workroom clean would look like a working app with a broken badge,
  /// which is the kind of failure that survives a whole release. A throw surfaces as
  /// `.notRepository` on the row instead.
  func workingStatus(root: URL) throws -> WorkroomStatus {
    throw VCSError.unsupportedRepo("\(Self.self) does not implement workingStatus")
  }

  /// Default: no pre-image source, so deletions render plain. `GitProvider`/`RustJJProvider` override
  /// these; other conformers (tests, fixtures) inherit the no-op.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String? {
    nil
  }
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  { nil }
}

/// Backend selection + routing.
enum VCS {
  /// Classify a repo by pure filesystem inspection (no VCS call, so it can't take the jj
  /// working-copy lock). Colocated jj+git prefers jj (matches how Workroom's own repos are set up).
  static func repoKind(at root: URL) -> VCSRepoKind {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let hasJJ =
      fm.fileExists(atPath: root.appendingPathComponent(".jj").path, isDirectory: &isDir)
      && isDir.boolValue
    // `.git` is a dir for a normal repo, a file for a worktree/submodule — either counts.
    let hasGit = fm.fileExists(atPath: root.appendingPathComponent(".git").path)
    switch (hasJJ, hasGit) {
    case (true, true): return .jjColocated
    case (true, false): return .jjNonColocated
    case (false, true): return .plainGit
    case (false, false): return .unsupported("no .jj or .git at \(root.path)")
    }
  }

  /// The provider for a repo, or a typed error for an unsupported path.
  ///
  /// **The registry is consulted first, and the filesystem probe is the fallback.** `repoKind(at:)`
  /// answers by looking for `.jj`/`.git` on THIS Mac, so it returns `.unsupported` for any path
  /// that is not local — which is every path in a remote workroom (issue #154, Phase 2). Routing
  /// therefore cannot stay a property of the filesystem; it has to be something a workroom
  /// declares. `VCSProviderRegistry` is where it declares it.
  ///
  /// Nothing is registered for a purely local session today, so today every call still reaches the
  /// probe and behaves exactly as it did. That is deliberate: this is the seam, not the feature.
  static func provider(for root: URL) throws -> VCSProviding {
    if let registered = VCSProviderRegistry.shared.provider(for: root) { return registered }
    switch repoKind(at: root) {
    case .jjColocated, .jjNonColocated: return RustJJProvider()
    case .plainGit: return GitProvider()
    case .unsupported(let reason): throw VCSError.unsupportedRepo(reason)
    }
  }
}

/// What each known repo root's provider is, so routing does not have to be inferred from the
/// local filesystem.
///
/// **Why this exists.** `VCS.repoKind(at:)` classifies a repo by looking for `.jj`/`.git` under the
/// path. That is correct and cheap for a local workroom and structurally impossible for a remote
/// one: the directory is on another machine, so the probe sees nothing and reports `.unsupported`.
/// Threading a host parameter through `VCSProviding`'s eight methods and their call sites would
/// answer it too, at the cost of every local caller carrying a machine identifier forever. Keying
/// on the workroom instead keeps the call sites exactly as they are — they already pass a `root:
/// URL`, and that URL is the key.
///
/// **Keyed on the path, not on a `Workroom`.** Every call site has a URL in hand and none of them
/// has a `Workroom`; passing one through would be the host-threading cost wearing this design's
/// name. Paths are standardised on both write and read so `/tmp/x` and `/private/tmp/x/` agree.
///
/// **Factories, not instances.** Both current providers are stateless structs, so it makes no
/// difference today — but a remote provider will close over a connection, and a stored instance
/// would fix its lifetime to the registry's rather than the workroom's.
final class VCSProviderRegistry: @unchecked Sendable {
  static let shared = VCSProviderRegistry()

  /// `provider(for:)` is called from `@Sendable` closures on arbitrary threads while `replace` runs
  /// on the main actor, so the map is lock-guarded — the same shape as `SessionBackendProbe`'s
  /// `Atomic`.
  private let lock = NSLock()
  private var factories: [String: @Sendable () -> VCSProviding] = [:]

  /// Replaces the whole map. Rebuilt wholesale on every `list --json` rather than diffed: the
  /// projects payload is the complete truth about what exists, and a diff would have to invent a
  /// removal rule to match it.
  func replace(with entries: [String: @Sendable () -> VCSProviding]) {
    let keyed = Dictionary(
      entries.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
    lock.withLock { factories = keyed }
  }

  func provider(for root: URL) -> VCSProviding? {
    let key = Self.key(root.path)
    guard let make = lock.withLock({ factories[key] }) else { return nil }
    return make()
  }

  /// Test seam: drop everything, so a test that registered a stub cannot leak into the next one.
  func removeAll() {
    lock.withLock { factories.removeAll() }
  }

  /// `/tmp` is a symlink to `/private/tmp` on macOS and a registered path may or may not have a
  /// trailing slash, so both sides of the lookup are normalised through here rather than compared
  /// raw.
  private static func key(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// What every repo in `projects` resolves to: the project root and each of its workrooms, all
  /// under the PROJECT's vcs.
  ///
  /// Pure and separate from `AppStore` so it can be tested as itself — the rule it encodes is the
  /// one that has already been got wrong once (see `factory(forVCS:)`), and a test that only
  /// exercised `factory(forVCS:)` would stay green if this loop read `workroom.vcsName` instead.
  ///
  /// Both roots are included because both are asked for a provider: the sidebar's root row resolves
  /// through `BranchResolver` exactly as a workroom does. A project whose vcs is unrecognised
  /// contributes nothing, so its paths keep falling through to the filesystem probe rather than
  /// resolving to a confidently wrong backend.
  static func entries(for projects: [Project]) -> [String: @Sendable () -> VCSProviding] {
    var entries: [String: @Sendable () -> VCSProviding] = [:]
    for project in projects {
      guard let factory = factory(forVCS: project.vcs) else { continue }
      entries[project.path] = factory
      for workroom in project.workrooms {
        entries[workroom.path] = factory
      }
    }
    return entries
  }

  /// The provider a `Project.vcs` string names. `"git"` and `"jj"` are the only values the CLI
  /// emits (`WorkroomStatusResolver.resolveLocal` switches on the same two).
  ///
  /// Note this takes the PROJECT's vcs even for a workroom: a git project's workrooms are git
  /// worktrees and a jj project's are jj workspaces. `Workroom.vcsName` is the branch/workspace
  /// name, not a type, and reading it as one has already caused one bug — see the comment in
  /// `AppStore+WorkroomStatus.statusWorkItems`.
  static func factory(forVCS vcs: String) -> (@Sendable () -> VCSProviding)? {
    switch vcs {
    case "jj": return { RustJJProvider() }
    case "git": return { GitProvider() }
    default: return nil
    }
  }
}
