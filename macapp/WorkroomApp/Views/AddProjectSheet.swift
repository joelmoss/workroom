import SwiftUI
import UniformTypeIdentifiers

/// The two ways "New Project" can resolve a path (issue #103):
/// - `existing`: the path must already be a Git/JJ repo (the historical behaviour).
/// - `createNew`: a missing path is created and git-initialized by the CLI.
enum AddProjectMode: CaseIterable, Identifiable {
  case existing
  case createNew
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
  /// return NotADirectory — fail fast before the round-trip).
  static func isValid(mode: AddProjectMode, path: String) -> Bool {
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

  static func footer(mode: AddProjectMode) -> String {
    switch mode {
    case .existing:
      return "Choose or type the full path to an existing Git or Jujutsu repository."
    case .createNew:
      return
        "Type the full path for the new project. If the folder doesn't exist it's created and "
        + "initialized as a Git repository."
    }
  }
}

/// The `Picker`/path-`TextField`/"Choose…" row shared by `AddProjectSheet` (which wraps it in its
/// own header + Cancel/Add footer) and the onboarding wizard's Add-Project step (issue #151, which
/// wraps it in a step header + the wizard's own footer buttons instead) — one tested core, two
/// differently-chromed shells, so neither has to duplicate path validation/normalization or the
/// folder-picker wiring.
struct AddProjectFields: View {
  @Binding var mode: AddProjectMode
  @Binding var path: String
  @Binding var showChooser: Bool
  var pathFieldFocused: FocusState<Bool>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("Source", selection: $mode) {
        Text("From existing path…").tag(AddProjectMode.existing)
        Text("Create new directory…").tag(AddProjectMode.createNew)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .accessibilityIdentifier("addProject.modePicker")

      VStack(alignment: .leading, spacing: 6) {
        Text(mode == .existing ? "Repository path" : "New project path")
          .font(.subheadline.weight(.semibold))
        HStack(spacing: 8) {
          TextField("/path/to/project", text: $path)
            .textFieldStyle(.roundedBorder)
            .focused(pathFieldFocused)
            .lineLimit(1)
            .accessibilityIdentifier("addProject.pathField")
          Button("Choose…") { showChooser = true }
            .accessibilityIdentifier("addProject.chooseButton")
        }
        Text(AddProjectSheetModel.footer(mode: mode))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .fileImporter(isPresented: $showChooser, allowedContentTypes: [.folder]) { result in
      // Existing mode: the picked folder IS the project. Create mode: it's a base
      // directory the user extends with a new folder name in the field.
      if case .success(let url) = result {
        path = url.path
      }
    }
  }
}

/// The "New Project" dialog (issue #103). Two modes share one editable path field:
/// "From existing path…" adds an existing repo (the prior folder-picker behaviour),
/// and "Create new directory…" lets the user type a path that the CLI creates and
/// git-initializes if it doesn't exist. "Choose…" opens a folder picker that fills
/// the field (the project itself in existing mode, or a base to extend in create mode).
///
/// `onAdd(path, create)` passes the normalized path and whether create-mode is on;
/// the parent owns dismissing the sheet and calling the store.
struct AddProjectSheet: View {
  let onAdd: (_ path: String, _ create: Bool) -> Void
  let onCancel: () -> Void

  @State private var mode: AddProjectMode = .existing
  @State private var path: String = ""
  @State private var showChooser = false
  @FocusState private var pathFieldFocused: Bool

  private var normalized: String { AddProjectSheetModel.normalize(path) }
  private var isValid: Bool { AddProjectSheetModel.isValid(mode: mode, path: path) }

  private func submit() {
    guard isValid else { return }
    onAdd(normalized, mode == .createNew)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 30))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("New Project")
            .font(.headline)
          Text("Add an existing repository, or create a new project directory.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      AddProjectFields(
        mode: $mode, path: $path, showChooser: $showChooser, pathFieldFocused: $pathFieldFocused
      )
      .onSubmit(submit)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Add Project", action: submit)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!isValid)
          .accessibilityIdentifier("addProject.confirmButton")
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { pathFieldFocused = true }
  }
}
