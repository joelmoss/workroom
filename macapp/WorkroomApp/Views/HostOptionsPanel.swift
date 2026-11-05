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
  @StateObject private var catalog = HostOptionsCatalog()

  var body: some View {
    if let provider = pending.place.hostProvider {
      VStack(spacing: 0) {
        Form {
          Section {
            HostOptionsFields(
              provider: provider, options: $options,
              inherited: store.hostOptionResolution(
                for: pending.place, in: pending.project, create: nil),
              catalog: catalog)
          } header: {
            Text("\(provider.displayName) Host for \(pending.project.displayName)")
          } footer: {
            if let failure = catalog.failure[provider] { Text(failure) }
          }
          Section {
            Toggle("Remember for this project", isOn: $remember)
              .accessibilityIdentifier("hostOptions.remember")
          } footer: {
            Text("Saves only the fields set here to Project Settings; the rest follow Settings.")
          }
        }
        .formStyle(.grouped)
        Divider()
        HStack {
          Spacer()
          Button("Cancel") { store.pendingHostOptions = nil }
            .keyboardShortcut(.cancelAction)
          Button("Create Workroom") { create(provider) }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("hostOptions.create")
        }
        .padding()
      }
      .frame(width: 460)
      .task { await catalog.load(provider) }
    }
  }

  private func create(_ provider: HostProvider) {
    let pending = pending
    let options = options
    if remember, !options.isEmpty {
      var saved = Defaults[.projectHostOptions][pending.project.path] ?? [:]
      saved[provider.rawValue] = options.overlaid(on: saved[provider.rawValue] ?? HostOptions())
      Defaults[.projectHostOptions][pending.project.path] = saved
    }
    store.pendingHostOptions = nil
    Task {
      await store.createRemoteWorkroom(
        in: pending.project, place: pending.place, splitAnchor: pending.splitAnchor,
        hostOptions: options.isEmpty ? nil : options)
    }
  }
}
