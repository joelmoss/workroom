import SwiftUI

/// A create's pane (#483): its steps, and on failure what to do next. A plain stand-in for the
/// designed checklist (spec section 5), which replaces it.
struct CreationPane: View {
  @ObservedObject var run: CreationRun
  @EnvironmentObject var store: AppStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(run.name ?? "New workroom").font(.title3.weight(.semibold))
      Text("\(run.project.displayName) · \(run.kind.destination)").foregroundStyle(.secondary)
      ForEach(run.steps) { step in
        Text("\(step.title): \(String(describing: step.state))")
      }
      footer
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityIdentifier("CreationPane")
  }

  @ViewBuilder
  private var footer: some View {
    switch run.outcome {
    case .failedBeforeWorkroom(let message), .remoteFailed(let message, leftBehind: false):
      Text(message)
      HStack {
        Button("Try Again") { Task { await store.retryCreation(run) } }
        Button("Close") { store.closeCreation(run) }
      }
    case .setupScriptFailed(let message):
      Text(message)
      HStack {
        Button("Open Anyway") { store.openCreatedWorkroomAnyway(run) }
        Button("Delete Workroom", action: deleteWorkroom)
      }
    case .remoteFailed(let message, leftBehind: true):
      Text(message)
      HStack {
        Button("Delete Workroom", action: deleteWorkroom)
        Button("Close") { store.closeCreation(run) }
      }
    case .running, .succeeded, .cancelled:
      EmptyView()
    }
  }

  /// The existing delete confirmation, for the workroom this create made.
  private func deleteWorkroom() {
    guard let project = store.projects.first(where: { $0.path == run.project.path }),
      let workroom = project.workrooms.first(where: { $0.name == run.name })
    else { return }
    store.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
  }
}
