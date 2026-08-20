import AppKit
import Defaults
import SwiftUI

/// The wizard's four fixed steps (issue #151).
///
/// ```
///                     ┌─────────┐   Next    ┌──────┐   Next    ┌─────────────┐
///         launch ───► │ welcome │ ────────► │ tour │ ────────► │ addProject  │
///      (gate check)   └─────────┘           └──────┘           └─────────────┘
///                          ▲                    │ Back              │      │
///                          └────────────────────┘                   │      │ Skip
///                                                           success │      │
///                                                      (sets flag)  ▼      ▼
///                                                                 ┌──────────┐
///                                                                 │   done   │──► flag set
///                                                                 └──────────┘    (.onChange)
///                                                                      │
///                                                                 Get Started
///                                                                      ▼
///                                                             dismissWindow(sceneID)
///
///   Any step: ⌘W / red button closes the window without advancing — the completion flag
///   stays whatever it already was (false until `.done` is reached by any path above).
/// ```
enum OnboardingStep: Int, CaseIterable {
  case welcome, tour, addProject, done
}

/// Pure decision logic for whether the wizard should open, extracted so it's unit-testable without a
/// window (mirrors `AddProjectSheetModel`). Trigger: first launch ever, only while no project is
/// registered. `override` lets a UI test force either outcome deterministically — see
/// `UITestFixture.onboardingOverride`; defaults to that real flag in production, injected explicitly
/// in tests.
enum OnboardingGate {
  static func shouldShow(
    hasCompleted: Bool, projectsEmpty: Bool, override: Bool? = UITestFixture.onboardingOverride
  ) -> Bool {
    if let override { return override }
    return !hasCompleted && projectsEmpty
  }

  /// A synchronous, pre-bootstrap approximation of `shouldShow` — `projectsEmpty` isn't known yet at
  /// the point the launch window decides whether to hide itself (that needs the async project-list
  /// load), so this is what drives that earlier decision instead. Consults the same override
  /// `shouldShow` does, so a UI test forcing "show"/"hide" gets consistent hide-the-launch-window
  /// behavior instead of disagreeing with the real gate once bootstrap completes.
  static func mightShow(hasCompleted: Bool, override: Bool? = UITestFixture.onboardingOverride)
    -> Bool
  {
    if let override { return override }
    return !hasCompleted
  }
}

/// One feature-tour highlight card (the wizard's `.tour` step).
struct OnboardingFeature: Identifiable {
  let id: String
  let icon: String
  let title: String
  let subtitle: String

  static let all: [OnboardingFeature] = [
    OnboardingFeature(
      id: "workrooms",
      icon: "square.stack.3d.up",
      title: "Parallel development across projects",
      subtitle: "Git and JJ worktrees for every project, each in its own workroom."),
    OnboardingFeature(
      id: "terminal",
      icon: "terminal",
      title: "Full-featured, GPU-accelerated terminal",
      subtitle: "Fast, smooth, tabbable, and splittable."),
    OnboardingFeature(
      id: "versionControl",
      icon: "arrow.triangle.branch",
      title: "Version Control Built in",
      subtitle: "See branch status, diffs, and history for every project and workroom."),
    OnboardingFeature(
      id: "runCommand",
      icon: "play.circle",
      title: "Your dev server, supervised",
      subtitle: "Per-project run commands. Quick and easy start, stop, and restart."),
    OnboardingFeature(
      id: "activity",
      icon: "bell.badge",
      title: "Live activity + notifications",
      subtitle: "System and in-app notifications"),
  ]
}

/// The dedicated first-run onboarding window (issue #151) — a `Window` scene (`WorkroomApp.swift`),
/// not a sheet over `RootWindow`. Deliberately carries no `WindowRegistry.register`/
/// `store.attachWindow` call: staying unregistered is what makes it fall through the same "no
/// AppStore" paths Settings/About already use — the ⌘W fallback (`AppDelegate`'s key monitor), the
/// shortcut/switcher no-ops (`AppDelegate.shortcutStore`/`switcherGate`), the quit/window-count logic
/// (`WindowRegistry.allStores`), and the ⌘` cycle exclusion (`isCycleableWindow`) all come out right
/// for free. It DOES still need `isRestorable = false` (no store/registry involved) — macOS's own
/// Cocoa window-state restoration would otherwise be free to reopen this window independently of
/// `OnboardingGate`'s own one-shot check, exactly the reason the main window sets the same flag
/// (`AppStore.swift`).
struct OnboardingWindow: View {
  static let sceneID = "onboarding"

  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow
  @State private var step: OnboardingStep = .welcome

  // Add-Project form state lives here, not in the step view, because the wizard's shared footer
  // needs to read it to enable/disable its own Add button.
  @State private var addProjectMode: AddProjectMode = .existing
  @State private var addProjectPath: String = ""
  @State private var showChooser = false
  @FocusState private var pathFieldFocused: Bool
  @State private var isAdding = false
  @State private var addProjectError: String?

  private let theme = ThemeService.shared
  @Default(.theme) private var themePreference

  var body: some View {
    VStack(spacing: 0) {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .frame(width: 560, height: 480)
    .background(theme.tokens.panel)
    .background(
      WindowAccessor { window in
        // See the type doc comment — deliberately NOT `WindowRegistry.shared.register`.
        window.isRestorable = false
        // A SwiftUI `.accessibilityIdentifier` on the content sets the identifier on that content
        // element, not on the window chrome — `XCUIApplication.windows[identifier]` matches against
        // the NSWindow's OWN accessibility identifier, so it has to be set here directly for UI tests
        // to find this specific window among any others open.
        window.setAccessibilityIdentifier("onboarding.window")
        // The main `WindowGroup` is launch-suppressed whenever onboarding might be needed (see
        // `WorkroomApp.body`), so it may not even exist yet — the main window has to be opened (or,
        // if it already exists, just brought forward) once this window closes, by ANY path (Get
        // Started, ⌘W, the red button): the user asked for the main window to open only once the
        // wizard is closed or finished, not underneath it the whole time. One-shot: this window only
        // ever closes once, so the observer removes itself right after firing.
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
          forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [openWindow] _ in
          MainActor.assumeIsolated {
            if let hostWindow = WindowRegistry.shared.lastActiveStore?.hostWindow {
              hostWindow.makeKeyAndOrderFront(nil)
            } else {
              openWindow(value: WindowSeed.launch)
            }
          }
          if let token { NotificationCenter.default.removeObserver(token) }
        }
      }
    )
    .onAppear {
      // This window can render before `RootView` ever has (the main `WindowGroup` is
      // launch-suppressed while onboarding might be needed — see `WorkroomApp.body`), so
      // `RootView.applyAppearance()`'s `NSApp.appearance` sync — the only other place that runs —
      // may never have happened yet. Without it, `NSApp.appearance` stays at the system default,
      // so any text left to SwiftUI's own `.primary` (every heading here) resolves against the OS's
      // light/dark setting while this window's background is already painted in the user's chosen
      // theme (`theme.tokens.panel`, resolved independently) — on a light-system/dark-theme machine
      // that's black text on a dark panel. `NSApp.appearance` is app-wide, so setting it here fixes
      // this window and costs nothing once `RootView` later re-applies the same value.
      NSApp.appearance = themePreference.nsAppearance
    }
    .onChange(of: step) {
      // The ONE place the completion flag is set — firing on entry to `.done` by any path (skip or a
      // successful add), not gated behind which button later closes the window (issue #151: a user who
      // reaches Done and then closes via ⌘W instead of "Get Started" still finished the flow).
      if step == .done {
        Defaults[.hasCompletedOnboarding] = true
      }
    }
    .task {
      guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
        return
      }
      // This window only auto-opens at launch when `OnboardingGate.mightShow` was true (see
      // `WorkroomApp.body`'s `.defaultLaunchBehavior`) — a synchronous approximation made before the
      // real project list could be loaded, since the main `WindowGroup` was suppressed and nobody
      // else is going to bootstrap it. If it's no longer true (e.g. a UI test's override), nothing
      // to correct — the normal `.onChange`/close-handler flow already covers this window's own
      // lifecycle.
      guard OnboardingGate.mightShow(hasCompleted: Defaults[.hasCompletedOnboarding]) else {
        return
      }
      // A throwaway store purely to trigger the same project-list bootstrap `RootWindow` would have
      // — this window owns no `AppStore` of its own by design (see the type doc comment).
      // `restore: false` so it does NOT consume `ProjectStore.consumeInitialRestore()`'s one-shot
      // flag; the real main window (opened below, or later via the close-handler) still needs that.
      let probe = AppStore(projectStore: .shared)
      await probe.bootstrap(restore: false)
      if !OnboardingGate.shouldShow(
        hasCompleted: Defaults[.hasCompletedOnboarding], projectsEmpty: probe.projects.isEmpty
      ) {
        // The real gate disagrees — an existing install with projects that just never completed
        // onboarding. This window shouldn't have opened; hand off to the real main window instead.
        openWindow(value: WindowSeed.launch)
        dismissWindow(id: Self.sceneID)
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch step {
    case .welcome:
      OnboardingWelcomeStep()
    case .tour:
      OnboardingTourStep()
    case .addProject:
      OnboardingAddProjectStep(
        mode: $addProjectMode, path: $addProjectPath, showChooser: $showChooser,
        pathFieldFocused: $pathFieldFocused, errorText: addProjectError)
    case .done:
      OnboardingDoneStep(onFinish: { dismissWindow(id: Self.sceneID) })
    }
  }

  private var footer: some View {
    HStack {
      if step != .welcome {
        Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
          .disabled(isAdding)
      }
      Spacer()
      switch step {
      case .welcome, .tour:
        Button("Next") { step = OnboardingStep(rawValue: step.rawValue + 1) ?? .done }
          .buttonStyle(.borderedProminent)
      case .addProject:
        Button("Skip") { step = .done }
          .disabled(isAdding)
        Button("Add Project") {
          Task { await handleAdd() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          isAdding || !AddProjectSheetModel.isValid(mode: addProjectMode, path: addProjectPath))
      case .done:
        EmptyView()
      }
    }
    .padding(16)
    // Overlaid, not sandwiched between two `Spacer()`s: the Back button and the trailing button
    // group are different widths on every step (no Back on Welcome; Next vs Skip+Add Project vs
    // nothing on Done), so two Spacers splitting the REMAINING space evenly still lands the dots
    // off-center. Centering on the footer's own full bounds instead keeps them fixed regardless of
    // what's on either side.
    .overlay(alignment: .center) { stepDots }
  }

  private var stepDots: some View {
    HStack(spacing: 6) {
      ForEach(OnboardingStep.allCases, id: \.self) { s in
        Circle().fill(s == step ? theme.tokens.accent : theme.tokens.fgDim)
          .frame(width: 6, height: 6)
      }
    }
  }

  /// Routes through the existing launch window's store rather than a throwaway one, so a successful
  /// add lands the user on the new project's root exactly as it does from the sidebar
  /// (`AppStore.addProject`'s post-`reload()` selection, issue #104) instead of a silent no-op.
  private func handleAdd() async {
    isAdding = true
    defer { isAdding = false }
    // No launch window may exist yet at all now (issue #151: the main `WindowGroup` is
    // launch-suppressed while onboarding might be needed — see `WorkroomApp.body` — so this is the
    // COMMON case for a genuinely fresh install, not an edge case). Falling back to a throwaway store
    // still correctly registers the project (it mutates the same shared `ProjectStore.shared`), so
    // the real main window picks it up once it opens — just without landing directly on its
    // terminal the way `AppStore.addProject`'s issue #104 behavior does when a window already
    // exists, since that selection lives on a per-window `AppStore` this throwaway one doesn't share
    // with whatever window opens next. Accepted minor gap: one extra sidebar click, not a redo.
    let store = WindowRegistry.shared.lastActiveStore ?? AppStore(projectStore: .shared)
    let normalized = AddProjectSheetModel.normalize(addProjectPath)
    switch await store.addProject(normalized, create: addProjectMode == .createNew) {
    case .success:
      addProjectError = nil
      step = .done
    case .failure(let error):
      // Shown inline here (not read from `store.errorMessage`) so the failure is visible on THIS
      // window even if the main window's own alert for the same error is behind it.
      addProjectError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }
}

private struct OnboardingWelcomeStep: View {
  private let theme = ThemeService.shared

  var body: some View {
    VStack(spacing: 16) {
      Spacer()
      // `AppMarkColor`, not `NSApp.applicationIconImage`: the same brand mark in colour but with no
      // rounded-tile plate behind it — the running app's actual icon bitmap always has that baked
      // in, since it's the real macOS icon artwork (`Scripts/make-icon.swift`'s `render`).
      Image("AppMarkColor")
        .resizable().scaledToFit().frame(width: 144, height: 144)
        .accessibilityHidden(true)
      Text("Welcome to Workroom").font(.largeTitle.bold())
      Spacer()
    }
    .padding(32)
    .frame(maxWidth: .infinity)
  }
}

private struct OnboardingTourStep: View {
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("What you can do").font(.title2.bold())
      // Scrollable, not a plain VStack: the window is fixed-size (no `.windowResizability` fallback
      // grows it), so a card list long enough to fill it would otherwise clip silently instead of
      // scrolling — a risk from day one, not just at today's card count.
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(OnboardingFeature.all) { feature in
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: feature.icon)
                .font(.system(size: 20))
                .foregroundStyle(theme.tokens.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.headline)
                Text(feature.subtitle).font(.callout).foregroundStyle(theme.tokens.fgMuted)
              }
            }
          }
        }
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct OnboardingAddProjectStep: View {
  @Binding var mode: AddProjectMode
  @Binding var path: String
  @Binding var showChooser: Bool
  var pathFieldFocused: FocusState<Bool>.Binding
  let errorText: String?

  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add your first project").font(.title2.bold())
      Text("Add an existing repository, or create a new project directory.")
        .font(.callout)
        .foregroundStyle(theme.tokens.fgMuted)
      AddProjectFields(
        mode: $mode, path: $path, showChooser: $showChooser, pathFieldFocused: pathFieldFocused)
      if let errorText {
        Text(errorText)
          .font(.callout)
          .foregroundStyle(theme.tokens.failure)
          .accessibilityIdentifier("onboarding.addProjectError")
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear { pathFieldFocused.wrappedValue = true }
  }
}

private struct OnboardingDoneStep: View {
  let onFinish: () -> Void
  private let theme = ThemeService.shared

  var body: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 48))
        .foregroundStyle(theme.tokens.accent)
        .accessibilityHidden(true)
      Text("You're all set").font(.largeTitle.bold())
      Text("Open a project from the sidebar whenever you're ready.")
        .font(.callout)
        .foregroundStyle(theme.tokens.fgMuted)
      Spacer()
      Button("Get Started", action: onFinish)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("onboarding.getStartedButton")
    }
    .padding(32)
    .frame(maxWidth: .infinity)
  }
}
