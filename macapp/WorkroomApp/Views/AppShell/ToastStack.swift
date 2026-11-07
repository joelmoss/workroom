import DesignSystem
import SwiftUI

/// The bottom-right toast surface for foreground notifications that arrive while the inspector is
/// closed (issue #31). Overlaid on the window in `RootView`; renders nothing when there are no
/// toasts. Each toast mirrors a live `WorkroomNotification`: tapping it routes through the same
/// `AppStore.openTerminal` the inspector rows and native banners use (which also dismisses the
/// notification), then drops the toast.
///
/// Toasts stack newest-at-bottom and auto-dismiss after 5s, with the countdown paused while hovered.
/// If a toast's notification is dismissed elsewhere (Clear, app refocus, workroom delete), the toast
/// is pruned so it can't outlive what it represents (`ToastStackAdapter` does that, since it is the
/// one that sees the notification list).
///
/// Store-free: it renders `model` and forwards taps to `actions`. `ToastStackAdapter` builds both
/// from the window's `AppStore`.
struct ToastStack: View {
  #if DEBUG
    /// How many times the stack's body has run, read by `AdapterGateInvalidationTests`.
    static var bodyPasses = 0
  #endif
  let model: ToastStackModel
  let actions: ToastStackActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    // ONE container (issue #67): live run toasts ride above the transient notification toasts, so the
    // two never overlap in the bottom-right corner (they'd collide as separate overlays).
    return VStack(alignment: .trailing, spacing: 8) {
      // Tool-version warnings ride at the top: unlike the two below, these describe a STANDING
      // condition (an old `git` doesn't fix itself), so they never auto-dismiss and stay until the
      // user closes them. See `VCSToolVersions`.
      ForEach(model.toolWarnings) { warning in
        ToolWarningToastView(
          warning: warning,
          onDismiss: {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
              actions.dismissToolWarning(warning.tool)
            }
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
      ForEach(model.runToasts) { run in
        RunToastView(
          item: run.item,
          source: run.source,
          onTap: {
            // Tap anywhere on the card → open the run terminal AND dismiss the toast (it won't
            // reappear; you're now looking at the run). Mirrors the notification toast's tap.
            actions.openRunToast(run.item.targetID)
          },
          onDismiss: {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
              actions.dismissRunToast(run.item.targetID)
            }
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
      ForEach(model.toasts) { toast in
        ToastView(
          item: toast.item,
          source: toast.source,
          onTap: { actions.openToast(toast.item) },
          onDismiss: {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
              actions.dismissToast(toast.item.id)
            }
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .animation(
      reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82),
      value: model.toasts.map(\.id)
    )
    .animation(
      reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82),
      value: model.runToasts.map(\.item)
    )
    .animation(
      reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82),
      value: model.toolWarnings
    )
    // An empty stack must not eat clicks meant for the content beneath it.
    .allowsHitTesting(!model.isEmpty)
  }
}

/// What `ToastStack` shows, with each toast's origin label already resolved.
struct ToastStackModel: Equatable {
  /// A notification toast and its origin label.
  struct Toast: Identifiable, Equatable {
    let item: WorkroomNotification
    /// Resolved from the live model so a workroom's display label (issue #41) shows and tracks
    /// renames; the snapshot when the target is gone.
    let source: String
    var id: WorkroomNotification.ID { item.id }
  }

  /// A live run toast and its origin label.
  struct RunToast: Identifiable, Equatable {
    let item: RunCommandController.RunToastItem
    /// Resolved as `Toast.source` is.
    let source: String
    var id: TerminalTarget.ID { item.id }
  }

  var toolWarnings: [VCSToolVersions.ToolWarning] = []
  var runToasts: [RunToast] = []
  /// Notifications no longer live in the right inspector (moved to the left sidebar, issue #118),
  /// so the previous `previewingRight` suppression — which withheld toasts while the right inspector
  /// was edge-revealed because that panel WAS the notifications surface — is gone; a focused arrival
  /// always toasts now (see `recordNotification`).
  var toasts: [Toast] = []

  var isEmpty: Bool { toolWarnings.isEmpty && runToasts.isEmpty && toasts.isEmpty }
}

/// What a toast's controls do. Animation stays with `ToastStack`; these only change the model.
struct ToastStackActions {
  /// Close a standing tool warning, by its tool.
  var dismissToolWarning: (String) -> Void
  /// Open a run toast's terminal and dismiss the toast.
  var openRunToast: (TerminalTarget.ID) -> Void
  /// Dismiss a run toast without opening it.
  var dismissRunToast: (TerminalTarget.ID) -> Void
  /// Open a notification toast's terminal (which also dismisses the notification) and drop it.
  var openToast: (WorkroomNotification) -> Void
  /// Drop a notification toast, leaving its notification in place.
  var dismissToast: (WorkroomNotification.ID) -> Void
}

/// Builds `ToastStack`'s model and actions from the window's `AppStore`.
///
/// A view of its own, not a computation in `RootView`: its body is where the toast lists are read,
/// so a toast arriving re-evaluates this and the stack, and not the window around them. This body
/// also runs on every `NotificationCenterStore` publish (an `ObservableObject`, so any change to
/// the notification list); the stack, measured, does not (`AdapterGateInvalidationTests`), so it
/// needs no equality gate.
struct ToastStackAdapter: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var runCommand: RunCommandController
  @EnvironmentObject var notifications: NotificationCenterStore

  var body: some View {
    ToastStack(model: model, actions: actions)
      // Keep toasts honest with the spine: drop any whose notification was dismissed elsewhere.
      .onChange(of: notifications.items) { _, items in
        let live = Set(items.map(\.id))
        for toast in store.toasts where !live.contains(toast.id) { store.dismissToast(toast.id) }
      }
  }

  private var model: ToastStackModel {
    ToastStackModel(
      toolWarnings: store.vcsToolWarnings,
      runToasts: store.runToastItems.map { item in
        .init(item: item, source: resolvedSource(forTargetID: item.targetID, fallback: item.source))
      },
      toasts: store.toasts.map { .init(item: $0, source: resolvedNotificationSource(store, $0)) }
    )
  }

  /// Origin label for a run toast, resolved from the live model so a workroom's display label
  /// (issue #41) shows and tracks renames; falls back to the snapshot when the target is gone.
  private func resolvedSource(forTargetID id: TerminalTarget.ID, fallback: String) -> String {
    let live = store.notificationSource(forTargetID: id)
    return live.isEmpty ? fallback : live
  }

  private var actions: ToastStackActions {
    ToastStackActions(
      dismissToolWarning: { [store] tool in store.dismissToolWarning(tool: tool) },
      openRunToast: { [store, runCommand] targetID in
        store.openRunToast(for: targetID)
        runCommand.dismissRunToast(for: targetID)
      },
      dismissRunToast: { [runCommand] targetID in runCommand.dismissRunToast(for: targetID) },
      openToast: { [store] toast in
        store.dismissToast(toast.id)
        WindowRegistry.shared.open(toast)
      },
      dismissToast: { [store] id in store.dismissToast(id) }
    )
  }
}

/// A standing warning that `git` on PATH is missing or too old for the VCS remote actions
/// (`VCSToolVersions`). Deliberately NOT routed through `NotificationCenterStore`: every entry there
/// is identified by `(targetID, tabID)` and a click routes back to a live terminal, which a
/// machine-wide tool problem has none of.
///
/// Styled as `RunToastView` but with no tap action and no auto-dismiss — there is nowhere useful to
/// navigate, and the condition persists until the user upgrades the tool.
private struct ToolWarningToastView: View {
  let warning: VCSToolVersions.ToolWarning
  let onDismiss: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      WarningGlyph()
      VStack(alignment: .leading, spacing: 2) {
        Text(warning.title).font(.callout).fontWeight(.semibold).lineLimit(2)
        Text(warning.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 300, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.l))
    .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(tokens.border, lineWidth: 0.5))
    .overlay(alignment: .topLeading) { closeButton }
    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(warning.title). \(warning.detail)")
    .accessibilityAction(named: "Dismiss") { onDismiss() }
  }

  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(tokens.border, lineWidth: 0.5))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .padding(6)
    .opacity(hovering ? 1 : 0)
    .allowsHitTesting(hovering)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    .help("Dismiss")
    .accessibilityHidden(true)
  }
}

/// One floating toast card. Styled to read as a lifted version of the inspector's `NotificationRow`
/// (source · title · body), on a material card with a shadow. Tapping the card opens its terminal
/// (and deletes the notification); hovering lifts the card, pauses the auto-dismiss, and reveals a
/// close button that dismisses just the toast (leaving the notification in the inspector). It
/// auto-dismisses after 5s unless the pointer is over it.
private struct ToastView: View {
  let item: WorkroomNotification
  /// Origin label, resolved by the parent so it reflects a workroom's display label (issue #41).
  let source: String
  let onTap: () -> Void
  let onDismiss: () -> Void

  @State private var hovering = false
  @State private var dismissTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    content
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(width: 300, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.l))
      // Faint fill + a touch more border on hover so the card reads as the clickable target it is.
      .overlay(
        RoundedRectangle(cornerRadius: Radius.l).fill(tokens.hover.opacity(hovering ? 1 : 0))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.l)
          .strokeBorder(tokens.border, lineWidth: 0.5)
      )
      .overlay(alignment: .topTrailing) { closeButton }
      // Lift on hover: a deeper, wider shadow.
      .shadow(
        color: .black.opacity(hovering ? 0.34 : 0.28), radius: hovering ? 22 : 18,
        y: hovering ? 10 : 8
      )
      .contentShape(RoundedRectangle(cornerRadius: Radius.l))
      .onTapGesture { onTap() }
      .onHover { hovering = $0 }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
      // Pause the countdown while hovered; restart a full 5s once the pointer leaves.
      .onChange(of: hovering) { _, isHovering in
        if isHovering {
          dismissTask?.cancel()
        } else {
          armDismiss()
        }
      }
      .onAppear { armDismiss() }
      .onDisappear { dismissTask?.cancel() }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityText)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint("Opens the terminal this notification came from")
      // Expose dismiss to VoiceOver too — the visual close button is hover-only and a11y-hidden.
      .accessibilityAction { onTap() }
      .accessibilityAction(named: "Dismiss") { onDismiss() }
  }

  /// A small close ✕ at the top-trailing corner, revealed on hover. Dismisses only the toast (not
  /// the notification) — distinct from tapping the card, which navigates and deletes. Hidden from
  /// hit-testing and VoiceOver while not hovering, so a corner tap falls through to the card and the
  /// rotor uses the "Dismiss" custom action instead.
  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(tokens.border, lineWidth: 0.5))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .padding(6)
    .opacity(hovering ? 1 : 0)
    .allowsHitTesting(hovering)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    .help("Dismiss")
    .accessibilityHidden(true)
  }

  // Mirrors NotificationRow: lead with the body when there's no title; show the source + relative
  // time beneath. No read/unread affordance — a toast is inherently the unseen, just-arrived case.
  private var content: some View {
    let headline = item.title.isEmpty ? (item.body ?? "") : item.title
    let subtext = item.title.isEmpty ? nil : item.body
    return VStack(alignment: .leading, spacing: 2) {
      if !headline.isEmpty {
        Text(headline).font(.body).fontWeight(.semibold).lineLimit(1)
      }
      if let subtext, !subtext.isEmpty {
        Text(subtext).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
      }
      HStack(spacing: 4) {
        if !source.isEmpty {
          Text(source).lineLimit(1)
          Text("·")
        }
        Text(item.date, style: .relative)
      }
      .font(.caption)
      // `.secondary`, not `.tertiary` (the inspector row's choice): on the toast's translucent
      // material `.tertiary` washes out — barely legible in dark mode.
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var accessibilityText: String {
    let headline = item.title.isEmpty ? (item.body ?? "") : item.title
    let parts = [source, headline].filter { !$0.isEmpty }
    return parts.isEmpty ? "Notification" : "Notification: \(parts.joined(separator: ", "))"
  }

  /// (Re)start the 5s auto-dismiss. Cancelled on hover/disappear; the hover guard inside covers the
  /// race where the pointer enters just as the timer fires.
  private func armDismiss() {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
      if Task.isCancelled || hovering { return }
      onDismiss()
    }
  }
}

/// One live run-status toast (issue #67). Mirrors `ToastView`'s lifted-card styling, bound to a
/// DERIVED `RunToastItem`: a spinner while the run is alive, a final status when it ends. Tapping
/// anywhere on the card opens the run terminal AND dismisses the toast; the ✕ (top-left, on hover)
/// dismisses without opening. Persistence, the foreground-hide rule, and auto-dismiss live on the
/// store (the source of truth); this view only renders + forwards the two actions.
private struct RunToastView: View {
  let item: RunCommandController.RunToastItem
  /// Origin label, resolved by the parent so it reflects a workroom's display label (issue #41).
  let source: String
  let onTap: () -> Void
  let onDismiss: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    HStack(spacing: 10) {
      statusIcon
      VStack(alignment: .leading, spacing: 2) {
        Text(statusText).font(.callout).fontWeight(.semibold).lineLimit(1)
        if !item.command.isEmpty {
          Text(item.command).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if !source.isEmpty {
          Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 300, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.l))
    .overlay(RoundedRectangle(cornerRadius: Radius.l).fill(tokens.hover.opacity(hovering ? 1 : 0)))
    .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(tokens.border, lineWidth: 0.5))
    .overlay(alignment: .topLeading) { closeButton }
    .shadow(
      color: .black.opacity(hovering ? 0.34 : 0.28), radius: hovering ? 22 : 18,
      y: hovering ? 10 : 8
    )
    .contentShape(RoundedRectangle(cornerRadius: Radius.l))
    .onTapGesture { onTap() }
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Opens the run terminal")
    .accessibilityAction { onTap() }
    .accessibilityAction(named: "Dismiss") { onDismiss() }
  }

  // Spinner while alive; a neutral check for a clean exit (not triumphant — a launcher exiting 0
  // isn't necessarily a "success" given session reaping); the failure-token octagon for a real
  // failure. A user-initiated stop produces no toast, so there's no neutral "stopped" glyph.
  @ViewBuilder private var statusIcon: some View {
    switch item.status {
    case .running, .stopping, .restarting:
      ProgressView().controlSize(.small)
    case .exited:
      Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
    case .failed, .failedToStart:
      Image(systemName: "xmark.octagon.fill").foregroundStyle(tokens.failure)
    }
  }

  private var statusText: String {
    switch item.status {
    case .running: return "Running"
    case .stopping: return "Stopping…"
    case .restarting: return "Restarting…"
    case .exited: return "Exited"
    case .failed(let code): return "Failed (exit \(code))"
    case .failedToStart: return "Failed to start"
    }
  }

  private var accessibilityText: String {
    let parts = [source, statusText, item.command].filter { !$0.isEmpty }
    return "Run: " + parts.joined(separator: ", ")
  }

  /// A small ✕ at the top-left, revealed on hover — dismisses this run's toast WITHOUT opening it
  /// (a card tap opens + dismisses). Its own `Button` hit area sits above the card's tap gesture.
  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(tokens.border, lineWidth: 0.5))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .padding(6)
    .opacity(hovering ? 1 : 0)
    .allowsHitTesting(hovering)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    .help("Dismiss")
    .accessibilityHidden(true)
  }
}

#if DEBUG
  #Preview("Toasts") {
    let target = TerminalTarget.ID.workroom(project: "platform", name: "fix-auth")
    ToastStack(
      model: ToastStackModel(
        toolWarnings: [
          .init(
            tool: "git", title: "git is too old",
            detail: "Push, pull and fetch need git 2.30 or newer.")
        ],
        runToasts: [
          .init(
            item: .init(
              targetID: target, tabID: UUID(), source: "platform / fix-auth",
              command: "npm run dev", status: .failed(code: 1)),
            source: "platform / fix-auth")
        ],
        toasts: [
          .init(
            item: WorkroomNotification(
              id: UUID(), targetID: target, tabID: UUID(), source: "platform / fix-auth",
              title: "Build finished", body: "All 212 tests passed.", date: .now, count: 1),
            source: "platform / fix-auth")
        ]
      ),
      actions: ToastStackActions(
        dismissToolWarning: { _ in }, openRunToast: { _ in }, dismissRunToast: { _ in },
        openToast: { _ in }, dismissToast: { _ in })
    )
    .frame(width: 360, height: 360)
  }
#endif
