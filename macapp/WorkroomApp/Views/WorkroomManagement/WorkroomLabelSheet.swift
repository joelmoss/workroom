import DesignSystem
import SwiftUI
import WorkroomDomain

/// Set/edit a workroom's display label (issue #41). Opened from the sidebar row's or the tab chip's
/// "Set Label…"/"Edit Label…" context-menu item via `ModalState.pendingWorkroomLabel`. A label is a
/// display-only alias — the real workroom name and its git worktree are unchanged, so this sheet
/// is intentionally light (a single field), unlike the type-to-confirm `DeleteProjectSheet`.
///
/// Submit is disabled until the trimmed input is a real change to a non-empty, non-colliding label
/// (validation lives in the pure `WorkroomLabelSheetModel`). *Removing* a label is a separate
/// context-menu action, so this sheet never submits a blank value.
///
/// `onSet(label)` passes the normalized label up; the parent owns clearing the pending state and
/// calling the store. `id`-keyed `.sheet(item:)` rebuilds this view per target, resetting `@State`.
struct WorkroomLabelSheet: View {
  let workroom: Workroom
  let project: Project
  let onSet: (_ label: String) -> Void
  let onCancel: () -> Void

  @State private var typedLabel: String
  @FocusState private var fieldFocused: Bool

  init(
    workroom: Workroom, project: Project, onSet: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.workroom = workroom
    self.project = project
    self.onSet = onSet
    self.onCancel = onCancel
    _typedLabel = State(initialValue: workroom.label ?? "")
  }

  /// Every other workroom in the project, resolved to its display name — what an entered label must
  /// not duplicate (else two rows would read identically).
  private var siblingDisplayNames: [String] {
    project.workrooms.filter { $0.id != workroom.id }.map(\.displayName)
  }

  private var validation: WorkroomLabelSheetModel.Validation {
    WorkroomLabelSheetModel.validate(
      input: typedLabel, current: workroom.label, siblingDisplayNames: siblingDisplayNames)
  }

  private var submit: () -> Void {
    {
      if validation.canSubmit { onSet(typedLabel) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(workroom.label == nil ? "Set label for “\(workroom.name)”" : "Edit label")
          .font(FontRole.title)
        Text(
          "A label is shown in place of the workroom name. The workroom and its branch are unchanged."
        )
        .font(FontRole.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 6) {
        TextField("Label", text: $typedLabel, prompt: Text(workroom.name))
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .focused($fieldFocused)
          .lineLimit(1)
          .onSubmit(submit)
          .accessibilityIdentifier("workroomLabel.field")
        // Explain a disabled button when the reason isn't obvious (a collision); blank/unchanged are
        // self-evident, so they get no warning.
        if validation.collides {
          WarningLabel("Another workroom in this project already shows that name.")
            .font(.caption)
        }
      }

      Divider()
      SheetFooter(onCancel: onCancel) {
        Button("Save", action: submit)
          .sheetDefaultAction()
          .disabled(!validation.canSubmit)
          .accessibilityIdentifier("workroomLabel.saveButton")
      }
    }
    .padding(Spacing.xxl)
    .frame(width: 380)
    .onAppear { fieldFocused = true }
  }
}
