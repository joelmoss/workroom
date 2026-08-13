import SwiftUI
import WorkroomSessionProtocol

/// Status-bar control listing background sessions that no tab in this workroom currently owns.
struct DetachedSessionsButton: View {
  let target: TerminalTarget
  @EnvironmentObject var store: AppStore
  @ObservedObject private var sessionsStore = TerminalSessionsStore.shared
  @State private var showing = false

  var body: some View {
    // The refresh task must run UNCONDITIONALLY, not just when `detached` is already non-empty:
    // it's the only thing that ever populates `detached` in the first place. Nesting it inside
    // the `if` below (as this used to) makes the button structurally unable to ever appear from a
    // cold state — `detached` starts empty, so the branch that would refresh it never mounts.
    Group {
      if !sessionsStore.detached(for: target.id).isEmpty {
        Button {
          showing.toggle()
        } label: {
          Image(systemName: "rectangle.stack")
          Text("\(sessionsStore.detached(for: target.id).count)")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("terminal.detachedSessions")
        .accessibilityLabel(
          "\(sessionsStore.detached(for: target.id).count) detached background terminals"
        )
        .popover(isPresented: $showing, arrowEdge: .top) {
          popover
            .frame(minWidth: 280, maxWidth: 360)
            .padding(12)
        }
      }
    }
    .task(id: target.id) { await refresh() }
  }

  private var popover: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Detached terminals").font(.headline)
      ForEach(sessionsStore.detached(for: target.id), id: \.identifier.uuidString) { session in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(session.value(forMetadataKey: SessionMetadataKey.title) ?? "Terminal")
              .lineLimit(1)
            Text(session.workingDirectory)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
          Spacer(minLength: 8)
          Button("Active tab") { attachToActive(session) }
            .disabled(store.terminals.focusedTab(for: target)?.surface == nil)
          Button("New tab") { openNew(session) }
          Button("Stop", role: .destructive) { stop(session) }
        }
      }
    }
  }

  private func refresh() async {
    await sessionsStore.refresh(
      workroomID: target.id, ownedSessionIDs: store.terminals.ownedSessionIDs(for: target))
  }

  private func attachToActive(_ session: SessionDescriptor) {
    guard let id = session.identifier.uuid else { return }
    guard
      TerminalSessionAttachment.attachToActivePane(
        sessionID: id, target: target, sessions: store.terminals)
    else { return }
    showing = false
    Task { await refresh() }
  }

  private func openNew(_ session: SessionDescriptor) {
    guard let id = session.identifier.uuid else { return }
    _ = store.terminals.addTab(for: target, sessionID: id)
    showing = false
    Task { await refresh() }
  }

  private func stop(_ session: SessionDescriptor) {
    guard let id = session.identifier.uuid else { return }
    Task {
      await PersistentSessionService.shared.endSession(sessionID: id)
      await refresh()
    }
  }
}
