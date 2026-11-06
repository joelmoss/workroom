import AppKit
import Defaults
import SwiftUI
import WorkroomDomain

/// The app's Settings window (⌘,). A source-list sidebar (`SettingsPane` rows) on the left, the
/// selected group's grouped `Form` on the right — the modern macOS System Settings layout, themed to
/// match the rest of the app. NavigationSplitView is deliberately avoided (it injects a titlebar
/// collapse-toggle and fights the fixed prefs-window sizing); `RootView` already sidesteps the native
/// sidebar the same way. Rows are `Button`s (immediate on click — a `List`-row `.onTapGesture` only
/// updates after the next event, e.g. a cursor move), and selection is a persisted `@Default` with a
/// hand-rolled highlight rather than `List(selection:)`, whose built-in bar fights the custom fill.
///
/// Theming mirrors the main window but via `SettingsWindowThemer` (themed window background +
/// transparent full-size-content title bar showing a "Settings" title) plus a panel fill that
/// `.ignoresSafeArea()` so SwiftUI paints the strip *behind* the title bar too — otherwise
/// `window.backgroundColor` alone gets reset to white by AppKit on some events and the bar flickers.
///
/// Each control binds the *same* `Defaults` key it did as a flat row, so stored values — and
/// everything observing them (appearance in `RootView`, copy-on-select, ⌘-click file opening) — are
/// unchanged; only the surface moves. The selected pane persists via `Defaults[.settingsSelectedPane]`.
struct SettingsView: View {
  /// The Settings window's title, which `SettingsWindowThemer` keeps it at, for the Window menu,
  /// VoiceOver and anything that has to tell this window from the others.
  static let windowTitle = "Settings"

  // Selection is `@State`, NOT `@Default`: the `Defaults` SwiftUI wrapper invalidates the view
  // asynchronously (its `objectWillChange` fires from a detached `Defaults.updates` task), so a
  // `@Default`-driven click only repainted on the *next* runloop tick — i.e. after a cursor move.
  // `@State` invalidates synchronously, so the detail switches on the click. We write through to
  // `Defaults[.settingsSelectedPane]` for persistence and restore from it in `.onAppear`.
  @State private var selection: SettingsPane = Defaults[.settingsSelectedPane]
  @State private var hovered: SettingsPane?
  @State private var history = SettingsHistory()
  // Bumped on `.themeDidChange` so the themed background/highlights repaint live when the user
  // switches theme in the Appearance pane (the tokens are read from the `ThemeService` singleton,
  // which SwiftUI doesn't observe on its own here).
  @State private var themeTick = 0

  /// The header strip's height, level with the window's traffic lights, as System Settings' is.
  private static let headerHeight: CGFloat = 52

  var body: some View {
    // Under the transparent title bar, as System Settings is: the sidebar runs the full height with
    // the traffic lights over its top, and the pane's header sits level with them.
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(spacing: 0) {
        header
        pane
      }
      .frame(minWidth: 440, maxWidth: .infinity)
    }
    // Opens at its smallest, and the panes grow with the window.
    .frame(minWidth: 621, maxWidth: .infinity, minHeight: 432, maxHeight: .infinity)
    .ignoresSafeArea(.container, edges: .top)
    .background(ThemeService.shared.tokens.panel.ignoresSafeArea())
    .background(SettingsWindowThemer())
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
    .onAppear {
      selection = Defaults[.settingsSelectedPane]
      // Fresh host option reads each time Settings opens, so a snapshot saved meanwhile shows.
      HostOptionsCatalog.shared.markStale()
      if let project = SettingsRoute.shared.takeRequest() { SettingsRoute.shared.project = project }
    }
    // A main window asked for a project's settings while this window was open.
    .onChange(of: SettingsRoute.shared.requests) {
      if let project = SettingsRoute.shared.takeRequest() {
        go(to: SettingsLocation(pane: .projects, project: project))
      }
    }
  }

  /// Where the window is now.
  private var location: SettingsLocation {
    SettingsLocation(
      pane: selection, project: selection == .projects ? SettingsRoute.shared.project : nil)
  }

  /// The open project's name in Projects, else the pane's.
  private var title: String {
    if let path = location.project,
      let project = ProjectStore.shared.projects.first(where: { $0.path == path })
    {
      return project.displayName
    }
    return selection.label
  }

  /// Goes to `next` as a step back can undo.
  private func go(to next: SettingsLocation) {
    history.leave(location, for: next)
    show(next)
  }

  /// Back and forward through the places visited, then where the window is.
  private var header: some View {
    HStack(spacing: 4) {
      Button {
        if let previous = history.goBack(from: location) { show(previous) }
      } label: {
        Image(systemName: "chevron.left").frame(width: 22, height: 22)
      }
      .disabled(!history.canGoBack)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back")
      .accessibilityLabel("Back")
      Button {
        if let next = history.goForward(from: location) { show(next) }
      } label: {
        Image(systemName: "chevron.right").frame(width: 22, height: 22)
      }
      .disabled(!history.canGoForward)
      .keyboardShortcut("]", modifiers: .command)
      .help("Forward")
      .accessibilityLabel("Forward")
      Text(title)
        .lineLimit(1)
        .font(.title3.weight(.semibold))
        .padding(.leading, 6)
        .accessibilityAddTraits(.isHeader)
      Spacer()
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 14)
    .frame(height: Self.headerHeight)
  }

  /// Shows `location`, and keeps its pane for the next time the window opens.
  private func show(_ location: SettingsLocation) {
    selection = location.pane
    Defaults[.settingsSelectedPane] = location.pane
    if location.pane == .projects { SettingsRoute.shared.project = location.project }
  }

  private var sidebar: some View {
    List {
      ForEach(SettingsPane.allCases) { pane in
        Button {
          // Projects opens on its list, as a System Settings pane opens on its top page.
          go(to: SettingsLocation(pane: pane))
        } label: {
          Label {
            Text(pane.label)
          } icon: {
            SettingsPaneIcon(pane: pane)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsPane.\(pane.rawValue)")
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(rowHighlight(pane))
        .onHover { inside in
          if inside {
            hovered = pane
          } else if hovered == pane {
            hovered = nil
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    // Clear of the traffic lights, which sit over the sidebar's top.
    .safeAreaPadding(.top, Self.headerHeight - 8)
    .frame(width: 180)
  }

  @ViewBuilder private var pane: some View {
    switch selection {
    case .general: GeneralSettingsPane()
    case .notifications: NotificationsSettingsPane()
    case .appearance: AppearanceSettingsPane()
    case .terminal: TerminalSettingsPane()
    case .agent: CodingAgentSettingsPane()
    case .projects:
      ProjectsSettingsPane(open: { go(to: SettingsLocation(pane: .projects, project: $0)) })
    case .remoteHosts: RemoteHostsSettingsPane()
    case .about: AboutSettingsPane()
    }
  }

  // Shared row highlight (see `RowHighlight`): a stronger fill for the selected pane, a subtle one on
  // hover. Drawn ourselves so it uses the theme tokens and doesn't depend on `List`'s built-in
  // selection. Settings rows inset by 6 (vs the project sidebar's 8).
  @ViewBuilder private func rowHighlight(_ pane: SettingsPane) -> some View {
    RowHighlight(selected: selection == pane, hovered: hovered == pane, horizontalPadding: 6)
  }
}

/// A pane's sidebar icon: its symbol, white, on a rounded tile of its own colour, as System
/// Settings draws them.
private struct SettingsPaneIcon: View {
  let pane: SettingsPane

  var body: some View {
    Image(systemName: pane.systemImage)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 20, height: 20)
      .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

extension SettingsPane {
  /// The colour of the pane's icon tile, after System Settings' own where it has the same pane.
  var tint: Color {
    switch self {
    case .general: .gray
    case .notifications: .red
    case .appearance: .indigo
    case .terminal: Color(white: 0.25)
    case .agent: .purple
    case .projects: .orange
    case .remoteHosts: .blue
    case .about: .teal
    }
  }
}

/// Themes the Settings window to match the app. Unlike the main window's `WindowBackgroundThemer`
/// (which stays themed because `RootView` re-renders constantly, re-running `updateNSView`), the
/// Settings view is static — so `updateNSView` rarely fires and AppKit's occasional reset of the
/// titlebar/background (on focus changes etc.) would stick, flashing the title bar white. This
/// themer instead re-applies on the window's own `didUpdate`/main/key notifications, and guards each
/// set so it only writes when something actually reset (no relayout churn). Combined with the
/// caller's `.background(tokens.panel.ignoresSafeArea())`, SwiftUI also paints behind the (transparent,
/// full-size-content) title bar, so the themed colour holds even between notifications.
private struct SettingsWindowThemer: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    context.coordinator.attach(to: probe)
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    Self.apply(to: nsView.window)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    // `nonisolated(unsafe)`: appended on the main actor, and read again only in `deinit`, which runs
    // once nothing else holds the coordinator.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private weak var probe: NSView?

    func attach(to probe: NSView) {
      self.probe = probe
      DispatchQueue.main.async { [weak self] in Self.applyToProbe(self?.probe) }

      let center = NotificationCenter.default
      // Theme switch: re-apply regardless of which window posted it.
      observers.append(
        center.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { Self.applyToProbe(self?.probe) }
        })
      // Window lifecycle events that reset the titlebar/background on a static view. Filtered to our
      // own window in the handler.
      for name: NSNotification.Name in [
        NSWindow.didUpdateNotification,
        NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didResizeNotification,
      ] {
        observers.append(
          center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue (`queue: .main`), so the note never crosses threads.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
              guard let window = self?.probe?.window,
                (note.object as? NSWindow) === window
              else { return }
              SettingsWindowThemer.apply(to: window)
            }
          })
      }
    }

    @MainActor private static func applyToProbe(_ probe: NSView?) {
      SettingsWindowThemer.apply(to: probe?.window)
    }

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }
  }

  // Guarded so each notification only writes when something actually reset — no relayout churn.
  @MainActor static func apply(to window: NSWindow?) {
    guard let window else { return }
    if !window.styleMask.contains(.fullSizeContentView) {
      window.styleMask.insert(.fullSizeContentView)
    }
    // A `Settings` scene's window is fixed-size by its type; this one resizes, as System Settings'.
    if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
    if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
    // No title in the bar: the pane's own header names it, as System Settings does. The title is
    // still "Settings", for the Window menu and VoiceOver; the `Settings` scene otherwise titles the
    // window "<App> Settings" ("Workroom Dev Settings" in Debug), so it is re-set on each
    // notification so SwiftUI's default doesn't win.
    if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
    if window.title != SettingsView.windowTitle { window.title = SettingsView.windowTitle }
    if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
    let panel = ThemeService.shared.tokens.nsPanel
    if window.backgroundColor != panel { window.backgroundColor = panel }
  }
}

// MARK: - Panes

private struct GeneralSettingsPane: View {
  @Default(.confirmOnQuit) private var confirmOnQuit
  @Default(.quitWithRunningServers) private var quitWithRunningServers
  @Default(.globalHotkey) private var globalHotkey

  var body: some View {
    Form {
      Toggle("Confirm before quitting", isOn: $confirmOnQuit)
        .help("Ask for confirmation before quitting. Terminals keep running after you quit.")
        .accessibilityIdentifier("settings.control.confirmQuit")

      Picker("When quitting with dev servers running", selection: $quitWithRunningServers) {
        ForEach(QuitWithRunningServers.allCases, id: \.self) { choice in
          Text(choice.title).tag(choice)
        }
      }
      .help(
        "What quitting Workroom does to run commands that are still going. Kept runs pick up "
          + "again in their tabs when you reopen Workroom. Updates always keep them running."
      )
      .accessibilityIdentifier("settings.control.quitWithRunningServers")

      Toggle("Global show/hide hotkey (⌘§)", isOn: $globalHotkey)
        .help("Register the system-wide ⌘§ shortcut to show or hide Workroom.")

      NewWorkroomsSection()
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

private struct NotificationsSettingsPane: View {
  @Default(.showMenuBarItem) private var showMenuBarItem
  @Default(.showMenuBarCount) private var showMenuBarCount
  @Default(.notifyWhenTerminalNeedsMe) private var notifyWhenTerminalNeedsMe
  @Default(.notifyWhenTurnFinishes) private var notifyWhenTurnFinishes

  var body: some View {
    Form {
      Toggle("Show notifications in the menu bar", isOn: $showMenuBarItem)
        .help("Show the Workroom notifications item in the menu bar.")

      Toggle("Show unread count in the menu bar", isOn: $showMenuBarCount)
        .help("Show how many notifications and requests are pending beside the menu bar logo.")
        .disabled(!showMenuBarItem)

      Toggle(isOn: $notifyWhenTerminalNeedsMe) {
        Text("Notify when a terminal needs me")
        Text(
          "Off: no Workroom alerts or Dock badge for terminals waiting on you. Programs' own "
            + "notifications still arrive as before.")
      }
      .help(
        "Alert you, and count it in the Dock badge, when a program in a terminal waits on you."
      )
      .accessibilityIdentifier("settings.control.notifyWhenTerminalNeedsMe")
      .onChange(of: notifyWhenTerminalNeedsMe) { WindowRegistry.shared.recomputeBadge() }

      Toggle(isOn: $notifyWhenTurnFinishes) {
        Text("Notify when a terminal finishes")
        Text(
          "When a program finishes its turn in a terminal you are not looking at. Replaces the "
            + "program's own notification after its turn.")
      }
      .help("Alert you when a program in a terminal you are not looking at finishes its turn.")
      .accessibilityIdentifier("settings.control.notifyWhenTurnFinishes")
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

/// The app-wide base branch: where new workrooms start in a project that names none of its own. It
/// lives in the CLI's config (`workroom base set --global`), so a terminal create agrees, and is
/// saved on Return or when the field loses focus, not per keystroke.
private struct NewWorkroomsSection: View {
  @Default(.closeCreationPaneWhenDone) private var closeCreationPaneWhenDone
  @State private var branch = ""
  @State private var saved = ""
  @State private var failure: String?
  @FocusState private var focused: Bool

  var body: some View {
    Section {
      TextField("Base branch", text: $branch, prompt: Text("origin's default branch"))
        .focused($focused)
        .onSubmit(save)
        .onChange(of: focused) { _, now in if !now { save() } }
        // Closing Settings mid-edit takes no Return and may not end focus first.
        .onDisappear(perform: save)
        .accessibilityIdentifier("settings.control.baseBranch")
      if let failure {
        Text(failure).font(.footnote).foregroundStyle(ThemeService.shared.tokens.failure)
      }
      Toggle("Close the checklist automatically when done", isOn: $closeCreationPaneWhenDone)
        .help(
          "Close a new workroom's checklist a few seconds after it is ready, instead of waiting "
            + "for Done.")
    } header: {
      Text("New Workrooms")
    } footer: {
      Text(
        "New workrooms start from origin's copy of this branch, else the local branch. Write "
          + "upstream/main for another remote's branch, such as a fork's upstream. A project's own "
          + "base branch in Projects wins.")
    }
    .task {
      let current = (try? await WorkroomCLI.shared.list(warnings: "none", project: nil))?.baseBranch
      branch = current ?? ""
      saved = branch
    }
  }

  private func save() {
    let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value != saved else { return }
    Task {
      do {
        try await WorkroomCLI.shared.setGlobalBaseBranch(value.isEmpty ? nil : value)
        // Every window's store reads it from here; otherwise a remote create before the next
        // reload would still use the old default.
        ProjectStore.shared.globalBaseBranch = value.isEmpty ? nil : value
        saved = value
        failure = nil
      } catch {
        failure = error.localizedDescription
      }
    }
  }
}

/// The host options every boxd and exe.dev workroom is created with (#575, ADR 0065): one group per
/// provider, shown whether or not it is set up, saving as they change. Settings ▸ Projects and
/// the New Workroom dialog's Configure… panel choose over them.
private struct RemoteHostsSettingsPane: View {
  @Default(.hostOptions) private var hostOptions
  @ObservedObject private var catalog = HostOptionsCatalog.shared

  var body: some View {
    Form {
      ForEach(HostKind.remoteProviders.filter(\.takesHostOptions), id: \.self) { provider in
        HostOptionsSection(
          provider: provider, options: binding(provider), inherited: nil, catalog: catalog)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private func binding(_ provider: HostKind) -> Binding<HostOptions> {
    let key = provider.hostOptionsKey
    return Binding(
      get: { key.flatMap { hostOptions[$0] } ?? HostOptions() },
      set: { options in key.map { hostOptions[$0] = options.isEmpty ? nil : options } })
  }
}

/// About + updates (issue #91): the app version, links out to the repo and release notes, and the
/// update controls (Check for Updates…, auto-check, and the Stable/Pre release-channel picker) —
/// moved here from General so everything update-related lives in one place.
private struct AboutSettingsPane: View {
  @Default(.releaseChannel) private var releaseChannel
  @EnvironmentObject private var updater: Updater

  private static let repoURL = URL(
    string: "https://github.com/\(GitHubReleasesClient.owner)/\(GitHubReleasesClient.repo)")!
  private static let releasesURL = repoURL.appendingPathComponent("releases")

  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: AppVersion.current ?? "unknown")
          .accessibilityIdentifier("about.version")
        Link("View release notes", destination: Self.releasesURL)
          .help("Open the GitHub Releases page in your browser.")
          .accessibilityIdentifier("about.releaseNotes")
        Link("Repository on GitHub", destination: Self.repoURL)
          .help("Open the workroom repository in your browser.")
          .accessibilityIdentifier("about.repo")
      }

      Section {
        Button("Check for Updates…") { updater.checkForUpdates() }
          .disabled(!updater.canCheckForUpdates)
          .help("Check GitHub for a newer version now.")
          .accessibilityIdentifier("about.checkForUpdates")

        // Drives Sparkle's scheduled background checks (persisted as SUEnableAutomaticChecks).
        Toggle(
          "Automatically check for updates",
          isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 })
        )
        .help("Let Workroom check for new versions automatically in the background.")
        .accessibilityIdentifier("about.autoUpdate")

        // Release channel (issue #91): Stable ⟷ Pre only. Nightly is a separate side-by-side
        // download (its own app), not a runtime switch, so it's not offered here and the picker is
        // hidden entirely on the nightly build (whose channel is fixed). Persist-only: the next
        // update check honors the choice; we don't force a check here (that would pop Sparkle's
        // dialog from inside Settings).
        if !ReleaseChannel.isNightlyBuild {
          Picker("Release channel", selection: $releaseChannel) {
            ForEach(ReleaseChannel.pickerCases, id: \.self) { channel in
              Text(channel.label).tag(channel)
            }
          }
          .help(
            "Which builds Workroom offers as updates: Stable (default) or Pre-release (betas and "
              + "release candidates, plus stable). Applies to the next update check. Nightly builds "
              + "are a separate download that runs alongside this app."
          )
          .accessibilityIdentifier("settings.control.releaseChannel")
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

private struct AppearanceSettingsPane: View {
  @Default(.theme) private var theme
  @Default(.themeFamily) private var themeFamily
  @Default(.diffViewMode) private var diffViewMode
  @Default(.loadRemoteAvatars) private var loadRemoteAvatars
  @Default(.dimUnfocusedPanes) private var dimUnfocusedPanes
  @Default(.autoResizeSplitsEvenly) private var autoResizeSplitsEvenly
  @State private var showThemePopover = false

  var body: some View {
    Form {
      Picker("Appearance", selection: $theme) {
        ForEach(ThemePreference.allCases, id: \.self) { pref in
          Text(pref.label).tag(pref)
        }
      }
      .help("Match the system appearance, or force Light or Dark.")

      // Theme family (issue #36): a family bundles a light + dark variant; the active one follows
      // Appearance above. The button opens the swatch picker (also reachable via ⌘⇧K).
      LabeledContent("Theme") {
        Button {
          showThemePopover = true
        } label: {
          HStack(spacing: 6) {
            Text(themeFamily).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
          }
          // Fixed width so the button (and the popover anchored to it) doesn't shift left/right as
          // the selected family name changes length.
          .frame(width: 160, alignment: .trailing)
        }
        .popover(isPresented: $showThemePopover, arrowEdge: .bottom) {
          ThemePicker()
        }
      }
      .help("Choose the color theme family (its light or dark variant follows Appearance).")

      // Diff viewer layout (issue #66): unified (default) or side-by-side. Applies to newly opened
      // diff tabs; a narrow diff pane falls back to unified regardless.
      Picker("Diff view", selection: $diffViewMode) {
        ForEach(DiffViewMode.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .help("Layout for newly opened diff tabs. A narrow pane falls back to unified.")
      .accessibilityIdentifier("settings.control.diffView")

      // Pane dimming (issue #162): the scrim over every non-focused pane. On by default — it's what
      // makes the active terminal read instantly in a split. See `PaneTreeView.shouldDim`.
      Toggle("Dim unfocused panes", isOn: $dimUnfocusedPanes)
        .help(
          "Shade every pane except the focused one, so the active terminal stands out in a split. "
            + "Off keeps every pane at full contrast."
        )
        .accessibilityIdentifier("settings.control.dimUnfocusedPanes")

      // Auto-even splits (issue #126): a third pane otherwise lands at a quarter width, and removing
      // one leaves the survivors budgeted for a pane that's gone. Only the dividers running the same
      // way as that pane move, and workrooms side by side are weighted by their terminals. Off keeps
      // every divider put.
      Toggle("Automatically resize splits evenly", isOn: $autoResizeSplitsEvenly)
        .help(
          "When you add or close a pane, the panes in its row or column resize to match. With "
            + "workrooms side by side, every terminal in the window ends up the same size. Off "
            + "leaves the dividers where you put them."
        )
        .accessibilityIdentifier("settings.control.autoResizeSplitsEvenly")

      // Privacy: author/reviewer avatars are fetched from Gravatar (by email hash) and GitHub. Off ⇒
      // only the coloured initials chip shows and nothing is requested, so viewing an untrusted
      // repo's history can't beacon your IP + author-email hashes to those services.
      Toggle("Load author avatars", isOn: $loadRemoteAvatars)
        .help(
          "Fetch author and reviewer avatars from Gravatar and GitHub. Off shows coloured initials "
            + "only and makes no network request — so opening an untrusted repo's history can't "
            + "beacon your IP to those services."
        )
        .accessibilityIdentifier("settings.control.loadRemoteAvatars")
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

private struct TerminalSettingsPane: View {
  /// Sessions any window has open or will reattach to: stopping "detached" terminals must never end
  /// one someone is looking at or that a restore is about to bring back.
  @MainActor private static func heldSessionIDs() -> Set<UUID> {
    WindowRegistry.shared.allStores.reduce(into: Set<UUID>()) { $0.formUnion($1.heldSessionIDs) }
  }

  @Default(.copyOnSelect) private var copyOnSelect
  @Default(.confirmOnCloseTerminal) private var confirmOnCloseTerminal
  // Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  @Default(.filePathEditor) private var pathEditor
  // The detached sessions "Stop Detached Terminals" found; non-nil presents its alert.
  @State private var detachedToStop: [UUID]?

  var body: some View {
    Form {
      Toggle("Copy on select", isOn: $copyOnSelect)
        .help("Automatically copy the terminal selection to the clipboard.")
        .accessibilityIdentifier("settings.control.copyOnSelect")

      Toggle("Confirm before closing a terminal", isOn: $confirmOnCloseTerminal)
        .help("Ask before closing a terminal (kills its shell and any running process, no undo).")

      VStack(alignment: .leading, spacing: 4) {
        Button("Stop Detached Terminals…") {
          Task {
            let held = Self.heldSessionIDs()
            detachedToStop = PersistentSessionService.detachedSessionIDs(
              await PersistentSessionService.shared.liveSessions(), held: held)
          }
        }
        .accessibilityIdentifier("settings.control.stopDetachedTerminals")
        .alert(
          detachedToStop?.isEmpty == true ? "No detached terminals" : "Stop detached terminals?",
          isPresented: Binding(
            get: { detachedToStop != nil }, set: { if !$0 { detachedToStop = nil } })
        ) {
          if let ids = detachedToStop, !ids.isEmpty {
            Button("Stop \(ids.count)", role: .destructive) {
              // Only the sessions counted, each re-checked just before it is ended: one a tab or
              // client took over since the count (or while an earlier kill was awaited) must not
              // lose its shell, and one created since was never offered. The helper's kill does
              // not check attachment itself, so a client attaching between this check and the kill
              // can still lose it; the window is one list round trip.
              Task {
                let service = PersistentSessionService.shared
                for id in ids {
                  let stillDetached = PersistentSessionService.detachedSessionIDs(
                    await service.liveSessions(), held: Self.heldSessionIDs())
                  guard stillDetached.contains(id) else { continue }
                  await service.endSession(sessionID: id)
                }
              }
            }
            Button("Cancel", role: .cancel) {}
          } else {
            Button("OK", role: .cancel) {}
          }
        } message: {
          if let ids = detachedToStop, !ids.isEmpty {
            Text(
              "\(ids.count) background terminal(s) with no open tab will be stopped, "
                + "along with anything running in them.")
          }
        }
        Text(
          "Terminals keep running in the background after you quit, and reattach when you "
            + "relaunch Workroom. Closing a terminal ends it. Run commands keep running too, "
            + "unless you choose to stop them when you quit, and the Quick Terminal is never "
            + "kept. Stopping detached terminals ends every one no open tab is attached to."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Picker("Open file paths in", selection: $pathEditor) {
        Text("Default App").tag("")
        ForEach(ExternalEditor.installed) { editor in
          Text(editor.name).tag(editor.id)
        }
      }
      .help("The app used to open ⌘-clicked file paths.")

      QuickTerminalSection()
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

/// Where the Quick Terminal slides in from, the folder its new shells start in, and its shortcut.
private struct QuickTerminalSection: View {
  @Default(.quickTerminalEdge) private var edge
  @Default(.quickTerminalHidesWhenUnfocused) private var hidesWhenUnfocused
  // "" = the home folder.
  @Default(.quickTerminalDirectory) private var directory
  @Default(.quickTerminalShortcut) private var shortcut

  var body: some View {
    Section {
      Picker("Slides in from", selection: $edge) {
        ForEach(QuickTerminalEdge.allCases, id: \.self) { edge in
          Text(edge.label).tag(edge)
        }
      }
      .help("The screen edge the Quick Terminal slides in from, centred along it.")
      .accessibilityIdentifier("settings.control.quickTerminalEdge")

      Toggle("Slide away when it loses focus", isOn: $hidesWhenUnfocused)
        .help("Hide the Quick Terminal when you click another window or switch apps.")
        .accessibilityIdentifier("settings.control.quickTerminalHidesWhenUnfocused")

      LabeledContent("Opens in") {
        HStack {
          Text(directory.isEmpty ? NSHomeDirectory() : directory)
            .monospaced()
            .lineLimit(1)
            .truncationMode(.middle)
          if !directory.isEmpty {
            Button("Use Home") { directory = "" }
              .accessibilityIdentifier("settings.control.quickTerminalDirectoryReset")
          }
          Button("Choose…", action: choose)
            .accessibilityIdentifier("settings.control.quickTerminalDirectory")
        }
      }
      .help(
        "The folder a new Quick Terminal shell starts in. A hidden Quick Terminal keeps its own "
          + "shell, and a folder that is gone opens your home folder.")

      LabeledContent("Keyboard shortcut") {
        ShortcutRecorder(shortcut: $shortcut)
      }
      .help(
        "The global shortcut that shows and hides the Quick Terminal from any app. It works while "
          + "Global show/hide hotkey is on in General.")
    } header: {
      Text("Quick Terminal")
    }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(
      fileURLWithPath: QuickTerminalController.workingDirectory(for: directory))
    guard panel.runModal() == .OK, let url = panel.url else { return }
    directory = url.path == NSHomeDirectory() ? "" : url.path
  }
}

private struct CodingAgentSettingsPane: View {
  @Default(.terminalCodingAgentBackend) private var codingAgentBackend
  @Default(.terminalCodingAgentAutoDiagnose) private var codingAgentAutoDiagnose
  @Default(.terminalCodingAgentRedactSecrets) private var codingAgentRedactSecrets
  @Default(.usageInWindowFooter) private var usageInWindowFooter
  @Default(.usageInPaneFooter) private var usageInPaneFooter
  @Default(.claudeUsageDeclined) private var claudeUsageDeclined
  @EnvironmentObject private var claudeUsageBridge: ClaudeUsageBridge
  @EnvironmentObject private var codingAgentUsage: CodingAgentUsageMonitor
  @State private var confirmingClaudeUsage = false
  @State private var bridgeError: String?

  var body: some View {
    Form {
      // Inline terminal agent (issue #49): always on — a failed command is diagnosed by the local
      // CLI and a fix suggested in the pane's status bar (+ a ✦ badge on the tab).
      Section {
        Picker("Investigate with", selection: $codingAgentBackend) {
          Text("Auto (Claude, else Codex)").tag("auto")
          Text("Claude").tag("claude")
          Text("Codex").tag("codex")
        }
        .help("Which local agent CLI the Investigate button opens.")

        Toggle("Diagnose automatically", isOn: $codingAgentAutoDiagnose)
          .help("Run the diagnosis as soon as a command fails, instead of waiting for a click.")
          .accessibilityIdentifier("settings.control.autoDiagnose")

        VStack(alignment: .leading, spacing: 4) {
          Toggle("Redact obvious secrets before sending", isOn: $codingAgentRedactSecrets)
            .help("Mask obvious secrets in the command output before sending it to the agent.")

          Text(
            "A failed command's text and output are sent to the local claude CLI for a "
              + "suggested fix, with its tools turned off. Codex has no such mode, so it only "
              + "runs when you choose “Investigate”. Secret redaction is best-effort, not a "
              + "guarantee."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section {
        Toggle("Show in the window footer", isOn: $usageInWindowFooter)
          .accessibilityIdentifier("settings.control.usageInWindowFooter")
        Toggle("Show in the pane footer", isOn: $usageInPaneFooter)
          .help("Only while a coding agent runs in that pane.")
          .accessibilityIdentifier("settings.control.usageInPaneFooter")
        // Only after "Don't Ask Again" in the footer: the one place left to change one's mind. Never
        // while cswap supplies Claude usage, which would ignore the bridge.
        if claudeUsageDeclined, claudeUsageBridge.state == .disabled,
          codingAgentUsage.claudeUsesBridge
        {
          LabeledContent("Claude usage") {
            Button("Enable…") { confirmingClaudeUsage = true }
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Usage")
          Text(
            "Claude usage comes from cswap when it is installed, one reading per account; otherwise "
              + "from Claude's status line, once you enable it from the footer. Codex usage comes "
              + "from the Codex app server, or its local session files."
          )
          .font(.caption)
          .fontWeight(.regular)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear { claudeUsageBridge.refreshState() }
    .alert("Enable Claude usage?", isPresented: $confirmingClaudeUsage) {
      Button("Cancel", role: .cancel) {}
      Button("Enable") {
        do {
          try claudeUsageBridge.enable()
          claudeUsageDeclined = false
          codingAgentUsage.refresh()
        } catch {
          bridgeError = error.localizedDescription
        }
      }
    } message: {
      Text(
        "Workroom will update ~/.claude/settings.json to run its status-line wrapper. It stores "
          + "only rate_limits and forwards the original input unchanged to your current command."
      )
    }
    .alert(
      "Claude usage wasn’t enabled",
      isPresented: Binding(get: { bridgeError != nil }, set: { if !$0 { bridgeError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(bridgeError ?? "")
    }
  }
}
