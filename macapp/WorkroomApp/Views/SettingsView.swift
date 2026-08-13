import AppKit
import Defaults
import SwiftUI

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
  // Selection is `@State`, NOT `@Default`: the `Defaults` SwiftUI wrapper invalidates the view
  // asynchronously (its `objectWillChange` fires from a detached `Defaults.updates` task), so a
  // `@Default`-driven click only repainted on the *next* runloop tick — i.e. after a cursor move.
  // `@State` invalidates synchronously, so the detail switches on the click. We write through to
  // `Defaults[.settingsSelectedPane]` for persistence and restore from it in `.onAppear`.
  @State private var selection: SettingsPane = Defaults[.settingsSelectedPane]
  @State private var hovered: SettingsPane?
  // Bumped on `.themeDidChange` so the themed background/highlights repaint live when the user
  // switches theme in the Appearance pane (the tokens are read from the `ThemeService` singleton,
  // which SwiftUI doesn't observe on its own here).
  @State private var themeTick = 0

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      pane.frame(width: 440)
    }
    .frame(width: 621, height: 380)
    .background(ThemeService.shared.tokens.panel.ignoresSafeArea())
    .background(SettingsWindowThemer())
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
    .onAppear { selection = Defaults[.settingsSelectedPane] }
  }

  private var sidebar: some View {
    List {
      ForEach(SettingsPane.allCases) { pane in
        Button {
          selection = pane
          Defaults[.settingsSelectedPane] = pane
        } label: {
          Label(pane.label, systemImage: pane.systemImage)
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
    .frame(width: 180)
  }

  @ViewBuilder private var pane: some View {
    switch selection {
    case .general: GeneralSettingsPane()
    case .appearance: AppearanceSettingsPane()
    case .terminal: TerminalSettingsPane()
    case .agent: AgentSettingsPane()
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

  final class Coordinator {
    private var observers: [NSObjectProtocol] = []
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
    if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
    // Show a "Settings" title in the bar. The `Settings` scene otherwise titles the window
    // "<App> Settings" ("Workroom Dev Settings" in Debug); re-set it on each notification so
    // SwiftUI's default doesn't win.
    if window.titleVisibility != .visible { window.titleVisibility = .visible }
    if window.title != "Settings" { window.title = "Settings" }
    if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
    let panel = ThemeService.shared.tokens.nsPanel
    if window.backgroundColor != panel { window.backgroundColor = panel }
  }
}

// MARK: - Panes

private struct GeneralSettingsPane: View {
  @Default(.confirmOnQuit) private var confirmOnQuit
  @Default(.globalHotkey) private var globalHotkey
  @Default(.showMenuBarItem) private var showMenuBarItem
  @Default(.persistScrollback) private var persistScrollback

  var body: some View {
    Form {
      Toggle("Confirm before quitting", isOn: $confirmOnQuit)
        .help(
          "Ask for confirmation before quitting. Background sessions keep ordinary terminals running."
        )
        .accessibilityIdentifier("settings.control.confirmQuit")

      Toggle("Restore terminal output on relaunch", isOn: $persistScrollback)
        .help(
          "Save each terminal's visible output and scrollback so it comes back after a relaunch. "
            + "Stored as plain text in Application Support, so turn this off if your terminals show "
            + "secrets. Panes, splits and windows are restored either way."
        )
        .accessibilityIdentifier("settings.control.persistScrollback")

      Toggle("Global show/hide hotkey (⌘§)", isOn: $globalHotkey)
        .help("Register the system-wide ⌘§ shortcut to show or hide Workroom.")

      Toggle("Show notifications in the menu bar", isOn: $showMenuBarItem)
        .help("Show the Workroom notifications item in the menu bar.")
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
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
  @Default(.copyOnSelect) private var copyOnSelect
  @Default(.confirmOnCloseTerminal) private var confirmOnCloseTerminal
  @Default(.backgroundSessions) private var backgroundSessions
  // Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  @Default(.filePathEditor) private var pathEditor
  @State private var pendingDisable = false
  @State private var disableTask: Task<Void, Never>?

  var body: some View {
    Form {
      Toggle("Copy on select", isOn: $copyOnSelect)
        .help("Automatically copy the terminal selection to the clipboard.")
        .accessibilityIdentifier("settings.control.copyOnSelect")

      Toggle("Confirm before closing a terminal", isOn: $confirmOnCloseTerminal)
        .help("Ask before closing a terminal (kills its shell and any running process, no undo).")

      Toggle("Background sessions", isOn: $backgroundSessions)
        .help(
          "Keep workroom terminals running after you quit Workroom, and reattach them on relaunch."
        )
        .accessibilityIdentifier("settings.control.backgroundSessions")
        .onChange(of: backgroundSessions) { _, enabled in
          disableTask?.cancel()
          guard !enabled else { return }
          disableTask = Task {
            let sessions = await PersistentSessionService.shared.liveSessions()
            guard !Task.isCancelled, !Defaults[.backgroundSessions] else { return }
            let attached = Set(
              WindowRegistry.shared.allStores.flatMap { $0.terminals.allOwnedSessionIDs })
            let willStopAny = sessions.contains {
              $0.identifier.uuid.map { !attached.contains($0) } ?? true
            }
            if !willStopAny { return }
            pendingDisable = true
          }
        }
        .alert("Stop background sessions?", isPresented: $pendingDisable) {
          Button("Stop Sessions", role: .destructive) {
            Task {
              guard !Defaults[.backgroundSessions] else { return }
              // Leave sessions still attached to an open tab in ANY window running — only the
              // truly detached/orphaned ones get killed. An attached session dies naturally when
              // its tab closes; this toggle must not yank a terminal out from under whoever is
              // looking at it right now.
              let attached = Set(
                WindowRegistry.shared.allStores.flatMap { $0.terminals.allOwnedSessionIDs })
              await PersistentSessionService.shared.endAllSessions(excluding: attached)
            }
          }
          Button("Cancel", role: .cancel) { backgroundSessions = true }
        } message: {
          Text("Terminals that are still running in the background will be stopped.")
        }

      Picker("Open file paths in", selection: $pathEditor) {
        Text("Default App").tag("")
        ForEach(ExternalEditor.installed) { editor in
          Text(editor.name).tag(editor.id)
        }
      }
      .help("The app used to open ⌘-clicked file paths.")
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

private struct AgentSettingsPane: View {
  @Default(.terminalAgentBackend) private var agentBackend
  @Default(.terminalAgentAutoDiagnose) private var agentAutoDiagnose
  @Default(.terminalAgentRedactSecrets) private var agentRedactSecrets

  var body: some View {
    Form {
      // Inline terminal agent (issue #49): always on — a failed command is diagnosed by the local
      // CLI and a fix suggested in the pane's status bar (+ a ✦ badge on the tab).
      Picker("Diagnose with", selection: $agentBackend) {
        Text("Auto (Claude, else Codex)").tag("auto")
        Text("Claude").tag("claude")
        Text("Codex").tag("codex")
      }
      .help("Which local CLI diagnoses a failed command.")

      Toggle("Diagnose automatically", isOn: $agentAutoDiagnose)
        .help("Run the diagnosis as soon as a command fails, instead of waiting for a click.")
        .accessibilityIdentifier("settings.control.autoDiagnose")

      Toggle("Redact obvious secrets before sending", isOn: $agentRedactSecrets)
        .help("Mask obvious secrets in the command output before sending it to the agent.")

      Text(
        "A failed command's text and output are sent to the local "
          + "\(agentBackend == "codex" ? "codex" : "claude") CLI for a suggested fix. "
          + "Secret redaction is best-effort, not a guarantee — Codex is used only for the "
          + "interactive “Investigate” action, never the automatic diagnosis."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}
