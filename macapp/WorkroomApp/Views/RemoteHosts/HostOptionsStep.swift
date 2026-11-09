import Defaults
import DesignSystem
import SwiftUI
import WorkroomDomain

/// One boxd or exe.dev create's host options (#575), as the New Workroom dialog's last step: opened
/// by a place's Configure button or ⌘⏎, or the sidebar's "boxd ▸ Configure…" and
/// "exe.dev ▸ Configure…". Each field shows what the create gets without it and where that comes
/// from; Remember for this project saves only the fields set here, so the rest keep following
/// Settings.
///
/// It fills the dialog's fixed body in one of three states, so nothing jumps or flashes: while the
/// provider is read it shows only that it is loading, then the settings, or the provider's error.
/// Each change crossfades. A read still fresh in the catalog opens straight on the settings. The
/// dialog's Back leaves any of them for the places.
struct HostOptionsStep: View {
  @ObservedObject var store: AppStore
  let project: Project
  let provider: HostKind
  /// Creates the workroom with these options (nil: none set here), closing the dialog.
  let onCreate: (HostOptions?) -> Void
  @State private var options = HostOptions()
  @State private var remember = false
  @State private var phase: Phase?
  @ObservedObject private var catalog = HostOptionsCatalog.shared
  // Read only so the step redraws when Settings or Settings ▸ Projects change them while it's
  // open: what it shows inheriting is what the create gets (`hostOptionResolution` reads them).
  @Default(.hostOptions) private var hostOptions
  @Default(.projectHostOptions) private var projectHostOptions
  @Environment(\.themeTokens) private var tokens

  /// What the step shows.
  enum Phase: Equatable {
    case loading
    case loaded
    /// The provider's reason it couldn't be read.
    case failed(String)
  }

  /// The shortest time the loading state stays up once shown, so a quick read doesn't flash it.
  static let minimumLoading: Duration = .milliseconds(450)

  /// Where the step starts: on the settings when the catalog's read is still fresh.
  static func initialPhase(for provider: HostKind, catalog: HostOptionsCatalog) -> Phase {
    catalog.isFresh(provider) ? .loaded : .loading
  }

  /// What the step shows once `provider`'s read is over.
  static func phase(after provider: HostKind, catalog: HostOptionsCatalog) -> Phase {
    catalog.failure[provider].map(Phase.failed) ?? .loaded
  }

  static func errorTitle(for provider: HostKind) -> String {
    "Couldn't load \(provider.displayName) host options"
  }

  var body: some View {
    let shown = phase ?? Self.initialPhase(for: provider, catalog: catalog)
    VStack(spacing: 0) {
      ZStack {
        switch shown {
        case .loading: loading.transition(.opacity)
        case .loaded: settings.transition(.opacity)
        case .failed(let message): failed(message).transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      // Always laid out, so the body keeps its height whatever the state: Create Workroom shows
      // only once there are settings to create with.
      HStack {
        Spacer()
        Button("Create Workroom", action: create)
          // Not `sheetDefaultAction()`: this is the New Workroom dialog's overlay, not a sheet,
          // and its Cancel is the dialog's own. The dialog's ⏎ handler steps aside here for it.
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("hostOptions.create")
      }
      .padding(12)
      .opacity(shown == .loaded ? 1 : 0)
      .disabled(shown != .loaded)
      .accessibilityHidden(shown != .loaded)
    }
    .task { await read(from: shown) }
  }

  /// Waits on the read and moves to what it found, keeping the loading state up for
  /// `minimumLoading`.
  private func read(from start: Phase) async {
    guard start == .loading else {
      phase = start
      return
    }
    phase = .loading
    let shownAt = ContinuousClock.now
    await catalog.load(provider)
    let left = Self.minimumLoading - (ContinuousClock.now - shownAt)
    if left > .zero { try? await Task.sleep(for: left) }
    guard !Task.isCancelled else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      phase = Self.phase(after: provider, catalog: catalog)
    }
  }

  private var loading: some View {
    VStack(spacing: Spacing.m) {
      ProgressView().controlSize(.small)
      Text("Loading \(provider.displayName) host options…")
        .font(FontRole.body)
        .foregroundStyle(tokens.fgMuted)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("hostOptions.loading")
  }

  private var settings: some View {
    Form {
      HostOptionsSection(
        provider: provider, options: $options,
        inherited: store.services.remoteCreate.hostOptionResolution(
          for: provider, in: project, create: nil),
        catalog: catalog,
        title: "\(provider.displayName) Host")
      Section {
        Toggle("Remember for this project", isOn: $remember)
          .accessibilityIdentifier("hostOptions.remember")
      } footer: {
        Text("Saves only the fields set here to Settings ▸ Projects; the rest follow Settings.")
      }
    }
    .formStyle(.grouped)
  }

  /// The error sheet's header and wording, in the dialog's body: Back returns to the places.
  private func failed(_ message: String) -> some View {
    WarningHeader {
      VStack(alignment: .leading, spacing: Spacing.s) {
        Text(Self.errorTitle(for: provider))
          .font(FontRole.title)
          .accessibilityIdentifier("error.title")
        Text(message)
          .font(FontRole.body)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("error.message")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("hostOptions.error")
  }

  private func create() {
    if remember, !options.isEmpty {
      let path = project.path
      let saved = Defaults[.projectHostOptions][project: path, provider: provider] ?? HostOptions()
      Defaults[.projectHostOptions][project: path, provider: provider] = options.overlaid(on: saved)
    }
    onCreate(options.isEmpty ? nil : options)
  }
}
