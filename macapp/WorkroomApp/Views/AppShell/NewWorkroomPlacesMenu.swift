import SwiftUI
import WorkroomDomain

/// Where a new workroom of `project` can go (#309), for both doors to it: the project row's "+" and
/// its context menu's New Workroom. A view of its own, so what it reads of the creates in flight is
/// read here, not in the project row.
struct NewWorkroomPlacesMenu: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var lifecycle: WorkroomLifecycle
  let project: Project

  var body: some View {
    if let blocked = lifecycle.createBlockedReason(in: project) {
      // Said once for every entry, rather than after each.
      Text(blocked.prefix(1).uppercased() + blocked.dropFirst())
      Divider()
    }
    newLocalWorkroomButton(Text("This Mac"))
    Section("Local containers") {
      ForEach(ContainerRuntime.allCases, id: \.self) { runtime in
        newRemoteWorkroomButton(at: .container(runtime))
      }
    }
    Section("Remote") {
      ForEach(HostKind.remoteProviders, id: \.self) { place in
        if place.takesHostOptions {
          hostOptionsPlaceMenu(at: place)
        } else {
          newRemoteWorkroomButton(at: place)
        }
      }
    }
  }

  /// boxd or exe.dev (#575): a submenu with Create, at once with the resolved host options, and
  /// Configure…, which opens one create's host options first.
  private func hostOptionsPlaceMenu(at place: HostKind) -> some View {
    let entry = availability(of: place)
    return Menu(entry.title) {
      newRemoteWorkroomButton(at: place, title: "Create")
      Button("Configure…") {
        store.modals.requestNewWorkroomConfigure = ConfigureRequest(
          project: project, place: place)
      }
      .help("Choose the image and size for this \(place.displayName) workroom first")
    }
    .help(entry.help)
    .disabled(entry.disabled)
  }

  /// How a place's entry reads and whether it can be chosen now.
  private struct PlaceAvailability {
    /// The place's name, and why it can't be used when it can't.
    let title: String
    let help: String
    let disabled: Bool
  }

  private func availability(of place: HostKind) -> PlaceAvailability {
    // The place's own reason only: one that holds the whole project (a create in flight) is said
    // once, above the entries.
    let reason = RemoteWorkrooms.unavailability(of: place)
    return PlaceAvailability(
      title: reason.map { "\(place.displayName) — \($0)" } ?? place.displayName,
      help: reason.map { "\(place.displayName) can't be used: \($0)" }
        ?? "A workroom of \(project.displayName) in \(place.hostPhrase)",
      disabled: reason != nil || !lifecycle.canCreateRemoteWorkroom(in: project))
  }

  /// New Workroom on this Mac. Creates in one project may overlap, each in its own pane (#483).
  private func newLocalWorkroomButton(_ label: some View) -> some View {
    Button {
      Task { await lifecycle.createWorkroom(in: project, from: store) }
    } label: {
      label
    }
    .help("A workroom of \(project.displayName) on this Mac")
    .disabled(lifecycle.createBlockedReason(in: project) != nil)
  }

  /// New Workroom at `place` (#309, #356): a local container, or a boxd machine, cloned from the
  /// project's GitHub origin. One that can't be used now says why in its title. `title` replaces
  /// the place's name, as Create does inside a place's own submenu.
  private func newRemoteWorkroomButton(at place: HostKind, title: String? = nil) -> some View {
    #if DEBUG
      ProjectSidebar.menuEvaluations += 1
    #endif
    let entry = availability(of: place)
    return Button {
      Task { await lifecycle.createRemoteWorkroom(in: project, place: place, from: store) }
    } label: {
      Text(title ?? entry.title)
    }
    .help(entry.help)
    .disabled(entry.disabled)
  }
}
