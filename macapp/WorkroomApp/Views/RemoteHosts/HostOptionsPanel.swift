import Defaults
import SwiftUI
import WorkroomDomain

/// One boxd or exe.dev create's host options (#575): opened by a place's Configure… button or ⌘⏎
/// in the New Workroom dialog, or the sidebar's "boxd ▸ Configure…" and "exe.dev ▸ Configure…". Each field
/// shows what the create gets without it and where that comes from; Remember for this project
/// saves only the fields set here, so the rest keep following Settings.
struct HostOptionsPanel: View {
  let pending: PendingHostOptions
  @EnvironmentObject private var store: AppStore
  @State private var options = HostOptions()
  @State private var remember = false
  @ObservedObject private var catalog = HostOptionsCatalog.shared
  // Read only so the panel redraws when Settings or Settings ▸ Projects change them while it's
  // open: what it shows inheriting is what the create gets (`hostOptionResolution` reads them).
  @Default(.hostOptions) private var hostOptions
  @Default(.projectHostOptions) private var projectHostOptions

  var body: some View {
    if pending.place.takesHostOptions {
      let provider = pending.place
      VStack(spacing: 0) {
        Form {
          HostOptionsSection(
            provider: provider, options: $options,
            inherited: store.services.remoteCreate.hostOptionResolution(
              for: pending.place, in: pending.project, create: nil),
            catalog: catalog,
            title: "\(provider.displayName) Host for \(pending.project.displayName)")
          Section {
            Toggle("Remember for this project", isOn: $remember)
              .accessibilityIdentifier("hostOptions.remember")
          } footer: {
            Text(
              "Saves only the fields set here to Settings ▸ Projects; the rest follow Settings.")
          }
        }
        .formStyle(.grouped)
        Divider()
        HStack {
          Spacer()
          Button("Cancel") { store.modals.pendingHostOptions = nil }
            .keyboardShortcut(.cancelAction)
          Button("Create Workroom") { create(provider) }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("hostOptions.create")
        }
        .padding()
      }
      .frame(width: 460)
    }
  }

  private func create(_ provider: HostKind) {
    let pending = pending
    let options = options
    if remember, !options.isEmpty {
      let path = pending.project.path
      let saved = Defaults[.projectHostOptions][project: path, provider: provider] ?? HostOptions()
      Defaults[.projectHostOptions][project: path, provider: provider] = options.overlaid(on: saved)
    }
    store.modals.pendingHostOptions = nil
    Task {
      await store.lifecycle.createRemoteWorkroom(
        in: pending.project, place: pending.place, splitAnchor: pending.splitAnchor,
        hostOptions: options.isEmpty ? nil : options, from: store)
    }
  }
}
