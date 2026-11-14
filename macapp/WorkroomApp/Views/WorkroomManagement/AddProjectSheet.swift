import Defaults
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// The ways "New Project" can resolve a path (issues #103, #620):
/// - `existing`: the path must already be a Git repo (the historical behaviour).
/// - `createNew`: a missing path is created and git-initialized by the CLI.
/// - `clone`: a remote repository is cloned into a new or empty folder, then registered.
enum AddProjectMode: CaseIterable, Identifiable {
  case existing
  case createNew
  case clone
  var id: Self { self }
}

/// Pure presentation rules for `AddProjectSheet`, extracted so path normalization,
/// the enable-until-valid gate, and the per-mode footer are unit-testable without
/// rendering SwiftUI (mirrors `DeleteProjectSheetModel`).
enum AddProjectSheetModel {
  /// Expand a leading "~" or "~/" to the home directory and trim surrounding
  /// whitespace. Only those two forms are expanded — matching the CLI's
  /// `config.CanonicalPath`, which also leaves "~user" untouched — so the path the
  /// dialog validates and sends lines up with what the CLI canonicalizes.
  static func normalize(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "~" || trimmed.hasPrefix("~/") {
      return (trimmed as NSString).expandingTildeInPath
    }
    return trimmed
  }

  /// Whether "Add Project" is enabled: a non-empty, absolute path. In `createNew`
  /// mode a path that already exists as a regular file is rejected (the CLI would
  /// return NotADirectory — fail fast before the round-trip). In `clone` mode `url` must be a
  /// repository URL and the path a new or empty folder (`cloneProblem`).
  static func isValid(mode: AddProjectMode, path: String, url: String = "") -> Bool {
    if mode == .clone { return isCloneURL(url) && cloneProblem(path) == nil }
    let p = normalize(path)
    guard !p.isEmpty, p.hasPrefix("/") else { return false }
    if mode == .createNew {
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue {
        return false
      }
    }
    return true
  }

  /// Whether the typed path names a location on another machine (`ssh://…`, `host:repo`): git's
  /// own test, a colon before the first slash, and the one the CLI refuses with
  /// RemoteProjectUnsupported.
  static func isRemote(_ path: String) -> Bool {
    let p = normalize(path)
    if p.contains("://") { return true }
    guard let colon = p.firstIndex(of: ":"), colon != p.startIndex else { return false }
    guard let slash = p.firstIndex(of: "/") else { return true }
    return colon < slash
  }

  // MARK: Clone a repository… (issue #620)

  /// Whether `url` is a repository the sheet will clone: what git calls remote (`https://`,
  /// `ssh://`, `git://`, scp-style `user@host:owner/repo`). Local repositories, `file://`
  /// included, are added with "From existing path…"; `owner/repo` shorthand isn't expanded.
  static func isCloneURL(_ url: String) -> Bool {
    let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
    return isRemote(u) && !u.lowercased().hasPrefix("file://")
  }

  /// The folder name git would give a clone of `url`: its last path component without `.git`.
  static func repoName(fromURL url: String) -> String? {
    var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if let scheme = u.range(of: "://") { u = String(u[scheme.upperBound...]) }
    // A host alone (`https://github.com/`) names no repository.
    let parts = u.split(whereSeparator: { $0 == "/" || $0 == ":" })
    guard parts.count >= 2, let last = parts.last.map(String.init) else { return nil }
    let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    return name.isEmpty ? nil : name
  }

  /// Where a clone of `url` goes by default: its repo name under `parent`.
  static func cloneDestination(url: String, parent: String) -> String? {
    guard let name = repoName(fromURL: url) else { return nil }
    return (normalize(parent) as NSString).appendingPathComponent(name)
  }

  /// What the path field should change to now, or nil to leave it. The field is shared by every
  /// mode and seeded for each: empty for "From existing path…", `parent/` for "Create new
  /// directory…", and `parent/<repo name>` for "Clone a repository…" (empty until the URL names a
  /// repository). It is re-seeded on a mode or URL change only while it is empty or still
  /// `lastAutoFill`, the last value the sheet wrote itself; once the user has typed their own path
  /// it stays theirs.
  static func seededPath(
    mode: AddProjectMode, current: String, lastAutoFill: String?, url: String, parent: String
  ) -> String? {
    guard current.isEmpty || current == lastAutoFill else { return nil }
    let seed: String
    switch mode {
    case .existing: seed = ""
    case .createNew: seed = parent.hasSuffix("/") ? parent : parent + "/"
    case .clone: seed = cloneDestination(url: url, parent: parent) ?? ""
    }
    return seed == current ? nil : seed
  }

  /// The folder new projects start in (Settings ▸ General ▸ Default project folder): the
  /// setting, with "~" expanded, or the home folder when it is unset.
  static func projectFolder(setting: String) -> String {
    let folder = normalize(setting)
    return folder.isEmpty ? NSHomeDirectory() : folder
  }

  /// Why `path` can't take a clone, or nil when it can: it must be absolute, and missing or an
  /// empty folder. Finder's `.DS_Store`/`.localized` don't count, as the CLI ignores them too.
  static func cloneProblem(_ path: String) -> String? {
    let p = normalize(path)
    guard p.hasPrefix("/") else { return "Type the full path to clone into." }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
    guard isDir.boolValue else { return "That's a file, not a folder." }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
    return entries.allSatisfy(finderJunk.contains) ? nil : "That folder isn't empty."
  }

  /// What Finder leaves in a folder it has shown, which doesn't make it non-empty: the CLI's own
  /// list (`finderJunk` in internal/workroom), kept the same so the sheet and the CLI agree.
  static let finderJunk: Set<String> = [".DS_Store", ".localized"]

  /// The confirm button's title and tooltip, the same in the sheet and the onboarding step.
  static func confirmTitle(mode: AddProjectMode) -> String {
    mode == .clone ? "Clone Project" : "Add Project"
  }

  static func confirmHelp(mode: AddProjectMode) -> String {
    mode == .clone
      ? "Clone the repository into the folder and add it as a project." : "Add the project."
  }

  static func footer(mode: AddProjectMode, path: String = "", url: String = "") -> String {
    if mode == .existing, isRemote(path) {
      return
        "Remote projects aren't supported. Add the project from a local repository: a remote "
        + "workroom belongs to a local project."
    }
    switch mode {
    case .existing:
      return "Choose or type the full path to an existing Git repository."
    case .clone:
      let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
      if !u.isEmpty, !isCloneURL(u) {
        return
          "Enter a repository URL, such as https://github.com/owner/repo or "
          + "git@github.com:owner/repo.git."
      }
      if !u.isEmpty, let problem = cloneProblem(path) { return problem }
      return
        "The repository is cloned into a new or empty folder. Git can't ask for a password "
        + "here, so sign in with an SSH key or a credential helper."
    case .createNew:
      return
        "Type the full path for the new project. If the folder doesn't exist it's created and "
        + "initialized as a Git repository."
    }
  }
}

/// A clone the New Project sheet or the onboarding wizard runs (#620): the latest progress line
/// while it runs, and its error after. One per form; `start` again retries.
@MainActor @Observable
final class CloneRun {
  typealias Perform = (
    _ url: String, _ path: String, _ onProgress: @escaping @Sendable (String) -> Void
  ) async -> Result<Void, Error>

  /// Where the clone is: not running, running with `task`, or cancelled and cleaning up.
  private enum Phase {
    case idle
    case running(Task<Void, Never>)
    case cancelling
  }

  private var phase = Phase.idle
  private(set) var progress: String?
  private(set) var error: String?

  var isRunning: Bool {
    if case .idle = phase { false } else { true }
  }
  var isCancelling: Bool {
    if case .cancelling = phase { true } else { false }
  }

  /// Clones with `perform`, then calls `onSuccess`. Cancelled or failed, it keeps the error to show
  /// and unlocks the form once the CLI has cleaned up.
  func start(url: String, path: String, perform: @escaping Perform, onSuccess: @escaping () -> Void)
  {
    guard !isRunning else { return }
    error = nil
    progress = "Starting the clone…"
    let onProgress: @Sendable (String) -> Void = { [weak self] line in
      guard let run = self else { return }
      Task { @MainActor in run.show(line) }
    }
    phase = .running(
      Task { [weak self] in
        let result = await perform(url, path, onProgress)
        guard let self else { return }
        let cancelled = self.isCancelling
        self.phase = .idle
        self.progress = nil
        switch result {
        case .success: onSuccess()
        case .failure(let error):
          self.error =
            cancelled
            ? "Clone cancelled."
            : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
      })
  }

  /// Cancels a running clone: the CLI kills git and puts the folder back as it found it.
  func cancel() {
    guard case .running(let task) = phase else { return }
    phase = .cancelling
    progress = "Cancelling…"
    task.cancel()
  }

  /// Shows a progress line, unless it arrives after the clone finished or was cancelled.
  private func show(_ line: String) {
    guard case .running = phase else { return }
    progress = line
  }

  /// Forgets the last error, as when the user changes what to clone.
  func clearError() { error = nil }
}

/// The `Picker`/URL/path-`TextField`/"Choose…" rows shared by `AddProjectSheet` (which wraps them in
/// its own header + Cancel/Add footer) and the onboarding wizard's Add-Project step (issue #151,
/// which wraps them in a step header + the wizard's own footer buttons instead) — one tested core,
/// two differently-chromed shells, so neither has to duplicate path validation/normalization, the
/// clone's progress and error (#620), or the folder-picker wiring.
struct AddProjectFields: View {
  @Binding var mode: AddProjectMode
  @Binding var path: String
  @Binding var url: String
  @Binding var showChooser: Bool
  var pathFieldFocused: FocusState<Bool>.Binding
  let clone: CloneRun

  // "" = the home folder.
  @Default(.defaultProjectFolder) private var projectFolderSetting
  /// What the sheet last wrote into the path field itself, so a hand-typed path isn't overwritten.
  @State private var lastAutoFill: String?
  /// The parent "Choose…" picked in clone mode, which later URL edits clone into.
  @State private var cloneParent: String?
  /// Clone mode starts at the URL: "Clone into" follows it, so it is where typing begins.
  @FocusState private var urlFieldFocused: Bool
  @Environment(\.themeTokens) private var tokens

  private var projectFolder: String {
    AddProjectSheetModel.projectFolder(setting: projectFolderSetting)
  }

  private var pathLabel: String {
    switch mode {
    case .existing: "Repository path"
    case .createNew: "New project path"
    case .clone: "Clone into"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("Source", selection: $mode) {
        Text("From existing path…").tag(AddProjectMode.existing)
        Text("Create new directory…").tag(AddProjectMode.createNew)
        Text("Clone a repository…").tag(AddProjectMode.clone)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .help("Add a repository on this Mac, create a new one, or clone one from a URL.")
      .accessibilityIdentifier("addProject.modePicker")

      if mode == .clone {
        VStack(alignment: .leading, spacing: 6) {
          Text("Repository URL")
            .font(.subheadline.weight(.semibold))
          // `verbatim`: a string literal title is a LocalizedStringKey, which SwiftUI renders as
          // Markdown, so a URL placeholder would show as a blue link.
          TextField(text: $url, prompt: Text(verbatim: "https://github.com/owner/repo")) {
            Text("Repository URL")
          }
          .textFieldStyle(.roundedBorder)
          .lineLimit(1)
          .help("The repository to clone: an https://, ssh:// or git@host:owner/repo URL.")
          .focused($urlFieldFocused)
          .accessibilityIdentifier("addProject.urlField")
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(pathLabel)
          .font(.subheadline.weight(.semibold))
        HStack(spacing: 8) {
          TextField("/path/to/project", text: $path)
            .textFieldStyle(.roundedBorder)
            .focused(pathFieldFocused)
            .lineLimit(1)
            .help(
              mode == .clone
                ? "The folder to clone into. It must be new or empty."
                : "The full path to the project."
            )
            .accessibilityIdentifier("addProject.pathField")
          Button("Choose…") { showChooser = true }
            .help(
              mode == .clone
                ? "Choose the folder to clone into: the repository gets its own folder inside it."
                : "Choose a folder."
            )
            .accessibilityIdentifier("addProject.chooseButton")
        }
        Text(AddProjectSheetModel.footer(mode: mode, path: path, url: url))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("addProject.footer")
      }

      if mode == .clone, clone.isRunning, let progress = clone.progress {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(progress)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier("addProject.cloneProgress")
        }
        .help("git's progress for this clone.")
      }
      if mode == .clone, let error = clone.error {
        Text(error)
          .font(.callout)
          .foregroundStyle(tokens.failure)
          .fixedSize(horizontal: false, vertical: true)
          .help("Why the clone didn't finish. Change the URL or folder and try again.")
          .accessibilityIdentifier("addProject.cloneError")
      }
    }
    .disabled(clone.isRunning)
    .onChange(of: url) { _, _ in
      clone.clearError()
      if mode == .clone { reseed() }
    }
    .onChange(of: path) { _, _ in clone.clearError() }
    .onChange(of: mode) { _, now in
      clone.clearError()
      reseed()
      // A turn later, not now: the URL field only appears with this mode change, and focus set
      // before it exists is dropped, leaving the cursor where it was.
      if now == .clone { Task { @MainActor in urlFieldFocused = true } }
    }
    .fileImporter(isPresented: $showChooser, allowedContentTypes: [.folder]) { result in
      // Existing mode: the picked folder IS the project. Create mode: it's a base
      // directory the user extends with a new folder name in the field. Clone mode: it's the
      // parent the repository gets its own folder in.
      guard case .success(let picked) = result else { return }
      if mode == .clone {
        cloneParent = picked.path
        write(
          AddProjectSheetModel.cloneDestination(url: url, parent: picked.path)
            ?? picked.path + "/")
      } else {
        path = picked.path
      }
    }
    .fileDialogDefaultDirectory(URL(fileURLWithPath: projectFolder))
  }

  /// Seeds the path field for the current mode and URL, unless the user has typed their own.
  private func reseed() {
    let parent = mode == .clone ? cloneParent ?? projectFolder : projectFolder
    guard
      let seed = AddProjectSheetModel.seededPath(
        mode: mode, current: path, lastAutoFill: lastAutoFill, url: url, parent: parent)
    else { return }
    write(seed)
  }

  /// Writes the path field on the user's behalf, remembering it so `reseed` may replace it.
  private func write(_ value: String) {
    path = value
    lastAutoFill = value
  }
}

/// The "New Project" dialog (issues #103, #620). Three modes share one editable path field:
/// "From existing path…" adds an existing repo (the prior folder-picker behaviour),
/// "Create new directory…" lets the user type a path that the CLI creates and
/// git-initializes if it doesn't exist, and "Clone a repository…" clones a URL into a new or empty
/// folder. "Choose…" opens a folder picker that fills the field (the project itself in existing
/// mode, or a base to extend in the other two).
///
/// `onAdd(path, create)` passes the normalized path and whether create-mode is on; the parent owns
/// dismissing the sheet and calling the store. A clone instead runs with the sheet open, through
/// `onClone`, which dismisses it on success; Cancel during a clone cancels the clone, not the sheet.
struct AddProjectSheet: View {
  let onAdd: (_ path: String, _ create: Bool) -> Void
  let onClone: CloneRun.Perform
  let onCloned: () -> Void
  let onCancel: () -> Void

  @State private var mode: AddProjectMode = .existing
  @State private var path: String = ""
  @State private var url: String = ""
  @State private var showChooser = false
  @State private var clone = CloneRun()
  @FocusState private var pathFieldFocused: Bool

  private var normalized: String { AddProjectSheetModel.normalize(path) }
  private var isValid: Bool { AddProjectSheetModel.isValid(mode: mode, path: path, url: url) }

  private func submit() {
    guard isValid, !clone.isRunning else { return }
    if mode == .clone {
      clone.start(
        url: url.trimmingCharacters(in: .whitespacesAndNewlines), path: normalized,
        perform: onClone, onSuccess: onCloned)
    } else {
      onAdd(normalized, mode == .createNew)
    }
  }

  private func cancel() {
    if clone.isRunning { clone.cancel() } else { onCancel() }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      SheetHeader(systemImage: "folder.badge.plus", glyphStyle: .tint) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("New Project")
            .font(FontRole.title)
          Text("Add an existing repository, clone one, or create a new project directory.")
            .font(FontRole.body)
            .foregroundStyle(.secondary)
        }
      }

      AddProjectFields(
        mode: $mode, path: $path, url: $url, showChooser: $showChooser,
        pathFieldFocused: $pathFieldFocused, clone: clone
      )
      .onSubmit(submit)

      Divider()
      SheetFooter(cancelIdentifier: "addProject.cancelButton", onCancel: cancel) {
        Button(AddProjectSheetModel.confirmTitle(mode: mode), action: submit)
          .sheetDefaultAction()
          .disabled(!isValid || clone.isRunning)
          .help(AddProjectSheetModel.confirmHelp(mode: mode))
          .accessibilityIdentifier("addProject.confirmButton")
      }
      .disabled(clone.isCancelling)
    }
    .padding(Spacing.xxl)
    .frame(width: 460)
    .interactiveDismissDisabled(clone.isRunning)
    .onAppear { pathFieldFocused = true }
    // The sheet can still go with its window; a clone left running would finish unseen.
    .onDisappear { clone.cancel() }
  }
}
