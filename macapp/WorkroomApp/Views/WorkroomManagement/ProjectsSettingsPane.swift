import Defaults
import SwiftUI
import WorkroomDomain

/// Settings ▸ Projects (issue #7): a list of the projects, and a click opens one's settings, as a
/// System Settings page does; the window's back button returns to the list. `SettingsRoute` opens
/// a project when a main window asks for it. Each setting saves as it changes, as the rest of
/// Settings does; a text field saves when you press Return or leave it.
struct ProjectsSettingsPane: View {
  /// Opens a project's settings, as a step the window's back button undoes.
  let open: (String) -> Void
  @ObservedObject private var catalog = HostOptionsCatalog.shared

  private var projects: [Project] { ProjectStore.shared.projects }

  /// The open project, while it still exists.
  private var opened: Project? {
    projects.first { $0.path == SettingsRoute.shared.project }
  }

  var body: some View {
    if let project = opened {
      // Keyed by path, so another project's fields start from its own values.
      ProjectSettingsForm(project: project, catalog: catalog)
        .id(project.path)
    } else if projects.isEmpty {
      Text("No projects yet. Add one from a workroom window's sidebar.")
        .foregroundStyle(ThemeService.shared.tokens.fgMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Form {
        Section {
          ForEach(projects, id: \.path) { project in
            Button {
              open(project.path)
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(project.displayName)
                  Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(ThemeService.shared.tokens.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundStyle(ThemeService.shared.tokens.fgMuted)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.projects.\(project.displayName)")
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }
  }
}

/// A project's run command and base branch as typed, over what was saved: only what you edited is
/// saved, and an untouched base branch follows a change made elsewhere (the CLI's `workroom base`).
struct ProjectSettingsDraft: Equatable {
  var command: String
  var autoRun: Bool
  var baseBranch: String
  private var savedRun: RunConfig
  private var savedBranch: String

  init(run: RunConfig, baseBranch: String?) {
    command = run.command
    autoRun = run.autoRun
    self.baseBranch = baseBranch ?? ""
    savedRun = run
    savedBranch = self.baseBranch
  }

  /// Blank with the same set `RunConfig.hasCommand` uses, so the auto-run gate and what's
  /// runnable agree (a newlines-only command reads as blank too — review #7).
  var commandIsBlank: Bool { command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// The run config to save, or nil when nothing changed. Auto-run is saved only with a command,
  /// so no dead `RunConfig(command: "", autoRun: true)` is (review #7); the switch keeps its
  /// setting while the command is cleared to be retyped.
  mutating func runToSave() -> RunConfig? {
    let run = RunConfig(command: command, autoRun: autoRun && !commandIsBlank)
    guard run != savedRun else { return nil }
    savedRun = run
    return run
  }

  /// The branch to save (blank: none), or nil when it wasn't edited.
  mutating func branchToSave() -> String? {
    let branch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    // What the project will hold once the save under way lands, else what it holds: changing
    // the field back while a save runs is an edit.
    guard branch != (savingBranch ?? savedBranch) else {
      // Back on the saved branch with nothing under way: an earlier refusal no longer applies.
      if savingBranch == nil { branchError = nil }
      return nil
    }
    savingBranch = branch
    return branch
  }

  /// What the CLI said when it last refused a base branch, until one is accepted.
  private(set) var branchError: String?
  /// The branch sent and not yet answered, which isn't sent again meanwhile.
  private var savingBranch: String?

  /// The CLI answered the save of `branch`: saved only when it took it, so a refused branch is
  /// sent again on the next Return.
  mutating func branchSaveEnded(_ branch: String, error: String?) {
    if savingBranch == branch { savingBranch = nil }
    branchError = error
    if error == nil { savedBranch = branch }
  }

  /// The project's saved branch is now `branch`, from here or elsewhere.
  mutating func branchSaved(_ branch: String?) {
    let branch = branch ?? ""
    // An untouched field follows; one with a save under way already holds what's next.
    if savingBranch == nil,
      baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) == savedBranch
    {
      baseBranch = branch
    }
    savedBranch = branch
  }
}

/// One project's settings: its run command, base branch and host options.
private struct ProjectSettingsForm: View {
  let project: Project
  @ObservedObject var catalog: HostOptionsCatalog
  @Default(.projectHostOptions) private var projectHostOptions
  @Default(.hostOptions) private var hostOptions

  // Saved on Return, on leaving a field, on the switch, and when the form goes.
  @State private var draft = ProjectSettingsDraft(run: .empty, baseBranch: nil)
  /// The base-branch save under way, which the next one waits for.
  @State private var branchSave: Task<Void, Never>?
  @FocusState private var focused: Field?

  private enum Field { case command, baseBranch }

  private var commandIsBlank: Bool { draft.commandIsBlank }

  /// False once the project is gone, so a late save never writes settings for a removed path.
  private var projectExists: Bool {
    ProjectStore.shared.projects.contains { $0.path == project.path }
  }

  var body: some View {
    Form {
      Section {
        if SettingsRoute.shared.warnedProject == project.path, commandIsBlank {
          Label(
            "No run command is defined yet — you can't run this workroom until you set one.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(ThemeService.shared.tokens.warning)
          // Stable identifier so the XCUITest doesn't match on the exact warning string.
          .accessibilityIdentifier("projectSettings.runWarning")
        }
        TextField("Run command", text: $draft.command, prompt: Text("e.g. npm run dev"))
          .lineLimit(1)
          .focused($focused, equals: .command)
          .onSubmit(saveRun)
          .accessibilityIdentifier("projectSettings.runCommand")
        Toggle("Run automatically when a workroom is created", isOn: $draft.autoRun)
          // Disabled while there's no command, keeping its setting for when one is typed again;
          // the draft saves auto-run only with a command.
          .disabled(commandIsBlank)
          .onChange(of: draft.autoRun) { saveRun() }
          .accessibilityIdentifier("projectSettings.autoRun")
      } header: {
        Text("Run Command")
      } footer: {
        Text(
          "Runs in a dedicated terminal at the workroom's directory, in your login shell. "
            + "Start it from the toolbar Run button or ⌘R.")
      }
      Section {
        HStack {
          TextField(
            "Base branch", text: $draft.baseBranch,
            prompt: Text(
              ProjectStore.shared.globalBaseBranch.map { "App default: \($0)" }
                ?? "origin's default branch")
          )
          .lineLimit(1)
          .focused($focused, equals: .baseBranch)
          .onSubmit(saveBaseBranch)
          .accessibilityIdentifier("projectSettings.baseBranch")
          // In the row, so a refusal moves nothing below it; the message is its tooltip.
          if let refused = draft.branchError {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(ThemeService.shared.tokens.warning)
              .help("Not saved: \(refused)")
              .accessibilityLabel("Base branch not saved: \(refused)")
              .accessibilityIdentifier("projectSettings.baseBranchError")
          }
        }
      } header: {
        Text("New Workrooms")
      } footer: {
        Text(
          "New workrooms start from origin's copy of this branch, fetched first, else the local "
            + "branch. Write upstream/main for another remote's branch. Remote workrooms need a "
            + "branch on origin. Leave it empty to use the app default in General.")
      }
      ForEach(HostKind.remoteProviders.filter(\.takesHostOptions), id: \.self) { provider in
        HostOptionsSection(
          provider: provider, options: hostOptionsBinding(provider),
          inherited: HostOptions.resolve(
            for: provider, create: nil, project: nil,
            settings: provider.hostOptionsKey.flatMap { hostOptions[$0] }),
          catalog: catalog)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear {
      draft = ProjectSettingsDraft(
        run: Defaults[.runCommands][project.path] ?? .empty, baseBranch: project.baseBranch)
    }
    .onChange(of: project.baseBranch) { _, branch in draft.branchSaved(branch) }
    .onChange(of: focused) { old, _ in
      if old == .command { saveRun() }
      if old == .baseBranch { saveBaseBranch() }
    }
    .onDisappear {
      saveRun()
      saveBaseBranch()
      SettingsRoute.shared.leave(project: project.path)
    }
    // Closing the Settings window may not take the form away first; save as it closes too, and
    // only then: another window closing mustn't save what is still being typed here.
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
      guard (note.object as? NSWindow)?.title == SettingsView.windowTitle else { return }
      saveRun()
      saveBaseBranch()
    }
    // A field keeps its focus when you switch windows, so leaving it never happens: save as the
    // Settings window stops being the active one too, before ⌘R or a create elsewhere reads it.
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      note in
      guard (note.object as? NSWindow)?.title == SettingsView.windowTitle else { return }
      saveRun()
      saveBaseBranch()
    }
  }

  private func saveRun() {
    guard projectExists, let config = draft.runToSave() else { return }
    ProjectStore.shared.setRunConfig(config, forProject: project.path)
  }

  private func saveBaseBranch() {
    guard projectExists, let branch = draft.branchToSave() else { return }
    // The CLI owns the branch; any window's store can ask it, and with none open a throwaway one
    // can, as onboarding's does, since every store shares `ProjectStore.shared`.
    let store = WindowRegistry.shared.lastActiveStore ?? AppStore(projectStore: .shared)
    let path = project.path
    // One at a time, in the order made: a quick second save mustn't land before the first.
    let previous = branchSave
    branchSave = Task {
      await previous?.value
      let refused = await store.setBaseBranch(branch, forProject: path, presentingError: false)
      draft.branchSaveEnded(branch, error: refused)
    }
  }

  private func hostOptionsBinding(_ provider: HostKind) -> Binding<HostOptions> {
    Binding(
      get: { projectHostOptions[project: project.path, provider: provider] ?? HostOptions() },
      set: { projectHostOptions[project: project.path, provider: provider] = $0 })
  }
}
