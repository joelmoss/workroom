import SwiftUI

/// The three escalating destructiveness levels offered by `DeleteProjectSheet` (issue #108):
/// keep everything, hard-delete the workroom dirs (branches kept), or move the whole project +
/// its workrooms to the Bin. Drives both the CLI invocation and the sheet's copy.
enum DeleteProjectScope: CaseIterable {
  case configOnly
  case workrooms
  case fromDisk
}

/// Pure presentation rules for `DeleteProjectSheet`, extracted so the disable-until-match,
/// Delete-button label, and per-scope footer logic are unit-testable without rendering SwiftUI.
enum DeleteProjectSheetModel {
  /// Delete is enabled only on an exact (case-sensitive) match of the project's display name.
  static func nameMatches(typed: String, displayName: String) -> Bool {
    typed == displayName
  }

  static func deleteLabel(scope: DeleteProjectScope, workroomCount: Int) -> String {
    let plural = workroomCount == 1 ? "" : "s"
    switch scope {
    case .configOnly: return "Delete Project"
    case .workrooms: return "Delete Project & \(workroomCount) Workroom\(plural)"
    case .fromDisk: return "Delete Everything to Bin"
    }
  }

  /// Reflects the chosen scope. The copy must make the recoverability inversion explicit (T1):
  /// level-2 PERMANENTLY removes worktree dirs (branches kept, NOT recoverable); level-3 is the
  /// bigger blast but is RESTORABLE from the Bin. The from-disk line is also honest that a
  /// workroom's teardown side effects are not undone by a Put Back (T2).
  static func effectFooter(scope: DeleteProjectScope, workroomCount: Int) -> String {
    switch scope {
    case .configOnly:
      return "Removes the project from Workroom only. Files on disk are kept."
    case .workrooms:
      let dirs = workroomCount == 1 ? "directory" : "directories"
      return
        "⚠️ Permanently removes \(workroomCount) worktree \(dirs). This is NOT recoverable. "
        + "Branches are kept."
    case .fromDisk:
      if workroomCount > 0 {
        let plural = workroomCount == 1 ? "" : "s"
        return
          "Moves the project and \(workroomCount) workroom\(plural) to the Bin — restorable from "
          + "the Trash. Each workroom's teardown script still runs first; its side effects are "
          + "not undone."
      }
      return "Moves the project to the Bin — restorable from the Trash."
    }
  }

  /// Issue #146: every scope (even `.configOnly`, which keeps files on disk) unconditionally reaps
  /// live terminals across the project's targets before any CLI/disk work — so a live Investigate
  /// session gets silently killed unless the sheet warns about it up front.
  static func investigateWarning(hasLiveInvestigateSession: Bool) -> String? {
    guard hasLiveInvestigateSession else { return nil }
    return "⚠️ This project has an active Investigate agent session running — deleting will stop it."
  }
}

/// Type-to-confirm sheet for deleting a project (issue #61). Opened from the project row's
/// context menu. The full path is always shown (same-named projects in different parents must
/// be distinguishable), and Delete stays disabled until the typed name matches exactly.
///
/// A radio group offers three escalating levels (issue #108): config-only (keep all files),
/// hard-delete the workroom dirs (branches kept, NOT recoverable), or move the whole project +
/// its workrooms to the Bin (restorable). The footer + Delete-button label reflect the chosen
/// level; the copy makes the recoverability inversion between level-2 and level-3 explicit.
///
/// `onDelete(scope)` passes the selected level; the parent owns clearing the pending state.
struct DeleteProjectSheet: View {
  let project: Project
  /// Whether any window has a live Investigate session somewhere in this project (issue #146) —
  /// computed by the caller via `WindowRegistry.hasLiveInvestigateSession(for:)`. Defaulted so
  /// existing previews/tests that don't care about this still construct the sheet with one argument
  /// fewer.
  var hasLiveInvestigateSession: Bool = false
  let onDelete: (_ scope: DeleteProjectScope) -> Void
  let onCancel: () -> Void

  @State private var typedName = ""
  @State private var scope: DeleteProjectScope = .configOnly
  @FocusState private var nameFieldFocused: Bool

  private var hasWorkrooms: Bool { !project.workrooms.isEmpty }
  private var count: Int { project.workrooms.count }
  private var plural: String { count == 1 ? "" : "s" }
  private var nameMatches: Bool {
    DeleteProjectSheetModel.nameMatches(typed: typedName, displayName: project.displayName)
  }
  private var deleteLabel: String {
    DeleteProjectSheetModel.deleteLabel(scope: scope, workroomCount: count)
  }
  private var effectFooter: String {
    DeleteProjectSheetModel.effectFooter(scope: scope, workroomCount: count)
  }
  private var investigateWarning: String? {
    DeleteProjectSheetModel.investigateWarning(hasLiveInvestigateSession: hasLiveInvestigateSession)
  }

  var body: some View {
    // Everything is left-aligned for one consistent edge; only the action buttons keep the
    // platform-standard trailing placement. A plain (non-Form) layout is used deliberately —
    // the grouped Form right-aligned the field's value, which broke that alignment.
    VStack(alignment: .leading, spacing: 16) {
      // Title + full path, led by a prominent warning glyph.
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 30))
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Delete project “\(project.displayName)”?")
            .font(.headline)
          Text(project.path)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(project.path)
        }
      }

      if let investigateWarning {
        Text(investigateWarning)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
          .accessibilityIdentifier("deleteProject.investigateWarning")
      }

      if hasWorkrooms {
        VStack(alignment: .leading, spacing: 8) {
          Text("This project has \(count) workroom\(plural)")
            .font(.subheadline.weight(.semibold))
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(project.workrooms) { workroom in
                Label(workroom.displayName, systemImage: "folder")
                  .font(.callout)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 120)
        }
      }

      // What to delete. Config-only vs move-to-Bin are always offered; the hard-delete-workrooms
      // middle level only appears when there are workrooms to delete.
      Picker("What to delete", selection: $scope) {
        Text("Remove from Workroom only — keep all files")
          .tag(DeleteProjectScope.configOnly)
        if hasWorkrooms {
          Text("Also delete \(count) workroom\(plural) — permanently; branches kept")
            .tag(DeleteProjectScope.workrooms)
        }
        Text(
          hasWorkrooms
            ? "Delete everything → Bin (project + \(count) workroom\(plural))"
            : "Delete the project → Bin"
        )
        .tag(DeleteProjectScope.fromDisk)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .accessibilityIdentifier("deleteProject.scopePicker")

      VStack(alignment: .leading, spacing: 6) {
        Text("Type the project name to confirm")
          .font(.subheadline.weight(.semibold))
        TextField("Project name", text: $typedName, prompt: Text(project.displayName))
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .focused($nameFieldFocused)
          .lineLimit(1)
          .onSubmit { if nameMatches { onDelete(scope) } }
          .accessibilityIdentifier("deleteProject.confirmField")
        Text(effectFooter)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button(deleteLabel) { onDelete(scope) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!nameMatches)
          .accessibilityIdentifier("deleteProject.confirmButton")
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { nameFieldFocused = true }
  }
}
