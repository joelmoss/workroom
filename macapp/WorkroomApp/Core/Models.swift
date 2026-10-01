import Foundation

// Mirrors the `workroom --json` public API (schema_version 1). Decoders are lenient:
// unknown fields are ignored so a newer bundled/standalone CLI won't break the app.

struct Warning: Codable, Hashable {
  let kind: String
  let message: String
  let path: String?
  let vcs: String?
}

/// A workroom's host descriptor from `list --json` (#249): present means the workroom lives on
/// another host, and its `path` is a path there. The app owns the schema (the `HostDriver` is Swift,
/// OQ21); the CLI reads only presence and `state`. Decoded as leniently as the CLI reads it: any
/// non-null value counts as present, so a malformed descriptor still keeps a remote workroom away
/// from every local action instead of failing the whole listing.
struct HostDescriptor: Codable, Hashable {
  var state: String? = nil

  var isDestroyed: Bool { state == "destroyed" }

  init(state: String? = nil) { self.state = state }

  init(from decoder: Decoder) throws {
    let container = try? decoder.container(keyedBy: CodingKeys.self)
    state = try? container?.decodeIfPresent(String.self, forKey: .state)
  }
}

struct Workroom: Codable, Identifiable, Hashable {
  let name: String
  let path: String
  let vcsName: String
  let warnings: [Warning]
  /// nil for a workroom on this Mac.
  var host: HostDescriptor? = nil
  /// GUI-only display alias (issue #41). NOT part of the `--json` contract — the CLI never sends
  /// it; it's injected post-decode in `AppStore.apply` from `Defaults[.workroomLabels]`. Absent
  /// from `CodingKeys` (with a default) so the synthesised decoder skips it. Intentionally a
  /// stored property, so synthesised `Equatable`/`Hashable` include it: a label change must make
  /// the value compare unequal for SwiftUI to re-render. Identity stays `id == name` (the
  /// immutable workspace name), so routing/selection/terminal-keying are unaffected, and nothing
  /// keys a dict/set on a whole `Workroom`, so the hash change is harmless.
  var label: String? = nil

  var id: String { name }
  var hasBlockingWarning: Bool { warnings.contains { $0.kind == "DirectoryMissing" } }
  var isRemote: Bool { host != nil }

  /// The name to show in the UI: the label when one is set, else the real workspace name. The
  /// single place the label-vs-name choice is made; every display site routes through this.
  var displayName: String { Workroom.normalizedLabel(label) ?? name }

  /// Canonical label normaliser (issue #41): trim surrounding whitespace; treat empty/whitespace-only
  /// as "no label" (nil). The one definition reused by `displayName`, `AppStore.setWorkroomLabel`'s
  /// write boundary, and `WorkroomLabelSheetModel`'s validation — so the "is this blank?" rule can't
  /// drift between them.
  static func normalizedLabel(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  enum CodingKeys: String, CodingKey {
    case name, path, warnings, host
    case vcsName = "vcs_name"
    // `label` is deliberately omitted — it's a GUI-only field, not part of the CLI JSON contract.
  }
}

struct Project: Codable, Identifiable, Hashable {
  let path: String
  let vcs: String
  let workrooms: [Workroom]

  var id: String { path }
  var displayName: String { (path as NSString).lastPathComponent }
}

// MARK: - Project root (sidebar root row)
//
// The root is the project directory itself — always selectable, always the first child in
// the sidebar, never deletable. Its branch/bookmark label is a GUI-only concern (the
// `workroom` CLI never shows it), so it is resolved app-side by BranchResolver, NOT carried
// in the `list --json` contract.

/// What kind of reference the working copy is on. Drives the root row's label treatment
/// (see RootPresentation). `ref_kind`-style, self-describing — the renderer needs no
/// `project.vcs` cross-reference.
enum RefKind: Hashable {
  case branch  // git: on a branch · jj: bookmark(s) on @
  case ancestor  // jj: no bookmark on @ — showing the nearest ancestor bookmark (the jj norm)
  case detached  // git: detached HEAD — showing a short SHA
  case none  // no branch/bookmark resolvable, or not yet resolved
}

/// A project root's resolved label. `branch` is normalized to nil (never "") so an empty
/// result is unambiguously `.none`.
struct RootRef: Hashable {
  let branch: String?
  let kind: RefKind

  static let unresolved = RootRef(branch: nil, kind: .none)
}

/// A place a terminal can be opened: a workroom or a project root. The id is
/// project-scoped, so same-named workrooms in different projects (and roots) never share a
/// terminal or setup log.
struct TerminalTarget: Identifiable, Hashable {
  let id: String
  let title: String
  let path: String
  /// Why this target cannot be opened on this Mac, or nil when it can. Every local action (terminal,
  /// editor, run command, status) guards on `isMissing`; only the rendering sites tell the reasons
  /// apart.
  let unavailability: Unavailability?

  var isMissing: Bool { unavailability != nil }

  enum Unavailability: Hashable {
    /// A local directory that no longer exists.
    case directoryMissing
    /// A workroom on another host. Its path is not a path on this Mac, and nothing opens a remote
    /// workroom yet (#253).
    case remote
    /// A remote workroom whose host its provider destroyed. Not a missing directory.
    case hostDestroyed

    var title: String {
      switch self {
      case .directoryMissing: return "Directory not found"
      case .remote: return "Remote workroom"
      case .hostDestroyed: return "Host destroyed"
      }
    }

    var systemImage: String {
      switch self {
      case .directoryMissing: return "questionmark.folder"
      case .remote: return "network"
      case .hostDestroyed: return "xmark.icloud"
      }
    }

    func detail(for target: TerminalTarget) -> String {
      switch self {
      case .directoryMissing:
        return "\(target.title) points at a path that no longer exists.\n\(target.path)"
      case .remote:
        return "\(target.title) is on another host, and this build cannot open it.\n\(target.path)"
      case .hostDestroyed:
        return "\(target.title)'s host was destroyed by its provider.\n\(target.path)"
      }
    }
  }

  // The id format lives ONLY here (and in the two builders below). Anything that needs a
  // target id — terminal/log keying, reaping — goes through these, so the project-scoping
  // that fixes the same-name collision can't drift.
  static func workroomID(project: String, name: String) -> String { "wr|\(project)|\(name)" }
  static func rootID(project: String) -> String { "root|\(project)" }
}

extension TerminalTarget {
  /// A local target: missing means its directory is gone.
  init(id: String, title: String, path: String, isMissing: Bool) {
    self.init(
      id: id, title: title, path: path, unavailability: isMissing ? .directoryMissing : nil)
  }
}

extension Workroom {
  /// The terminal target for this workroom within `projectPath`. `title` is the `displayName`
  /// (label when set, else name), so every consumer that reads `target.title` off a resolved target
  /// — missing-directory messages, split accessibility — shows the label automatically (issue #41).
  /// The id stays keyed on the immutable `name`.
  func target(inProject projectPath: String) -> TerminalTarget {
    TerminalTarget(
      id: TerminalTarget.workroomID(project: projectPath, name: name),
      title: displayName, path: path, unavailability: unavailability)
  }

  private var unavailability: TerminalTarget.Unavailability? {
    if let host { return host.isDestroyed ? .hostDestroyed : .remote }
    return hasBlockingWarning ? .directoryMissing : nil
  }
}

extension Project {
  /// The always-present project-root target. The project directory can disappear like a
  /// workroom directory, so `isMissing` is checked against the filesystem.
  var rootTarget: TerminalTarget {
    TerminalTarget(
      id: TerminalTarget.rootID(project: path), title: displayName, path: path,
      isMissing: !FileManager.default.fileExists(atPath: path))
  }
}

/// Pure mapping from a resolved `RootRef` to the root row's visual treatment. Extracted
/// from the view so it is unit-testable. `dim` means "unusual" (detached / no branch); the
/// jj-common `ancestor` state reads healthy (full strength + an `ahead` marker).
enum RootPresentation {
  struct Style: Equatable {
    let label: String
    let tooltip: String
    let accessibility: String
    let ahead: Bool  // trailing "↑" marker (jj ancestor)
    let dim: Bool  // de-emphasize (detached / none)
  }

  static func make(_ ref: RootRef) -> Style {
    switch ref.kind {
    case .branch:
      let name = normalized(ref.branch) ?? "root"
      return Style(
        label: name, tooltip: "Project root · on \(name)",
        accessibility: "Project root, on \(name)", ahead: false, dim: false)
    case .ancestor:
      let name = normalized(ref.branch) ?? "root"
      return Style(
        label: name, tooltip: "Project root · ahead of \(name)",
        accessibility: "Project root, ahead of \(name)", ahead: true, dim: false)
    case .detached:
      let name = normalized(ref.branch) ?? "detached"
      return Style(
        label: name, tooltip: "Project root · detached HEAD",
        accessibility: "Project root, detached at \(name)", ahead: false, dim: true)
    case .none:
      return Style(
        label: "root", tooltip: "Project root",
        accessibility: "Project root", ahead: false, dim: true)
    }
  }

  /// Treats "" / whitespace like nil (the Go side may emit "" rather than null).
  private static func normalized(_ s: String?) -> String? {
    guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
  }
}

// MARK: - Envelopes

/// Common envelope header present on every response; used to detect error responses
/// before decoding a command-specific payload.
struct Envelope: Codable {
  let ok: Bool
  let schemaVersion: Int?
  let error: CLIErrorBody?

  enum CodingKeys: String, CodingKey {
    case ok, error
    case schemaVersion = "schema_version"
  }
}

struct CLIErrorBody: Codable {
  let kind: String
  let message: String
}

struct ListResponse: Codable {
  let projects: [Project]
  let workroomsDir: String?
  let configPath: String?

  enum CodingKeys: String, CodingKey {
    case projects
    case workroomsDir = "workrooms_dir"
    case configPath = "config_path"
  }
}

struct CreateResponse: Codable {
  let name: String
  let path: String
  let vcs: String
  let project: String
}

/// `add-project` success payload. `path` is the canonical (symlink-resolved,
/// ~-expanded) project path the CLI registered — the app selects the project by
/// it after a reload. `vcs` is "git" or "jj".
struct AddProjectResponse: Codable {
  let path: String
  let vcs: String
}

/// `delete-project --from-disk` success payload. The CLI runs teardowns + drops the project
/// from config, then returns the directories (project root first, then workrooms) for the app
/// to move to the Bin — the CLI never deletes them itself (issue #108).
struct DeleteProjectResponse: Codable {
  let trashPaths: [String]?

  enum CodingKeys: String, CodingKey {
    case trashPaths = "trash_paths"
  }
}

/// A streamed event from the CLI's stderr in --json mode (one NDJSON object per line)
/// while the result envelope stays on stdout. `type` discriminates:
///  - "log": a line of setup/teardown output (`text`, `phase`).
///  - "created": the new workroom exists (`name`, `path`) but setup is still running;
///    `setup` reports whether a setup script will run, so the GUI can block on its log.
struct StreamEvent: Decodable {
  let type: String
  let phase: String?
  let text: String?
  let name: String?
  let path: String?
  let setup: Bool?
}
