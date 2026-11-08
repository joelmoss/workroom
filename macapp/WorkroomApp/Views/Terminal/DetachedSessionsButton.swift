import SwiftUI
import WorkroomWire

/// Status-bar control listing background sessions that no tab in this workroom currently owns.
struct DetachedSessionsButton: View {
  let target: TerminalTarget
  @Environment(\.paneHost) private var host
  @ObservedObject private var sessionsStore = DetachedSessionList.shared
  @State private var showing = false
  /// Read through Observation, so "Detach" enables once the focused tab has a surface.
  private var terminals: TerminalPanes { host.terminals }

  var body: some View {
    let detached = sessionsStore.detached(for: target)
    // The refresh task must run UNCONDITIONALLY, not just when `detached` is already non-empty:
    // it's the only thing that ever populates `detached` in the first place. Nesting it inside
    // the `if` below (as this used to) makes the button structurally unable to ever appear from a
    // cold state — `detached` starts empty, so the branch that would refresh it never mounts.
    Group {
      if !detached.isEmpty {
        Button {
          showing.toggle()
        } label: {
          Image(systemName: "rectangle.stack")
          Text("\(detached.count)")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("terminal.detachedSessions")
        .accessibilityLabel("\(detached.count) detached background terminals")
        .popover(isPresented: $showing, arrowEdge: .top) {
          popover(detached)
            .frame(minWidth: 280, maxWidth: 360)
            .padding(12)
        }
      }
    }
    // A remote workroom's list is read again each time its host connects (`follow`), so a pane
    // that mounts before its host is up still shows what the host holds.
    .task(id: target.id) {
      await sessionsStore.follow(target) { [terminals, target] in
        terminals.ownedSessionIDs(for: target)
      }
    }
  }

  private func popover(_ detached: [SessionDescriptor]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Detached terminals").font(.headline)
      ForEach(detached, id: \.identifier.uuidString) { session in
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
            .disabled(terminals.focusedSurface(for: target) == nil)
          Button("New tab") { openNew(session) }
          Button("Stop", role: .destructive) { stop(session) }
        }
      }
    }
  }

  private func refresh() async {
    await sessionsStore.refresh(target, ownedSessionIDs: terminals.ownedSessionIDs(for: target))
  }

  private func attachToActive(_ session: SessionDescriptor) {
    guard let id = session.identifier.uuid else { return }
    // The session the pane lets go, which the list should offer once its old attach has gone.
    let released = terminals.focusedTab(for: target)?.terminal?.sessionID
    guard
      TerminalSessionAttachment.attachToActivePane(
        sessionID: id, target: target, sessions: terminals)
    else { return }
    showing = false
    Task { [terminals, target, sessionsStore] in
      guard let released, released != id else {
        return await sessionsStore.refresh(
          target, ownedSessionIDs: terminals.ownedSessionIDs(for: target))
      }
      await sessionsStore.refreshAfterReleasing(released, in: target) {
        terminals.ownedSessionIDs(for: target)
      }
    }
  }

  private func openNew(_ session: SessionDescriptor) {
    guard let id = session.identifier.uuid else { return }
    host.whenHostLayoutRestored(target) { [terminals = host.terminals] target in
      _ = terminals.addTab(for: target, sessionID: id)
      // The waiting list counts only sessions an open pane shows.
      WindowRegistry.shared.recomputeBadge()
    }
    showing = false
    Task { await refresh() }
  }

  private func stop(_ session: SessionDescriptor) {
    guard let id = session.identifier.uuid else { return }
    Task {
      await sessionsStore.stop(
        id, in: target, ownedSessionIDs: terminals.ownedSessionIDs(for: target))
    }
  }
}
