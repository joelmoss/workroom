import SwiftUI

/// The menu bar item's popover (issue #33): requests waiting on the user, app-wide (#358), then the
/// shared `NotificationsList`. The `MenuBarController` only opens this when there is something to
/// list (an empty click focuses the app instead), but it still falls back to a "No notifications"
/// state for the brief window where the list drains while the popover is open. No header or Clear
/// button (clearing lives in the in-app inspector); tapping a row opens its terminal (which
/// activates the app) and then closes the popover via `onClose` — passed in by the controller,
/// since `@Environment(\.dismiss)` is inert in a hand-hosted `NSPopover`.
struct MenuBarNotificationsView: View {
  /// The app-level registry (issue #70). The unread list is the active window's notifications and
  /// routes taps within that window; the menu-bar/Dock *count* aggregates across all windows.
  @ObservedObject var registry: WindowRegistry
  @ObservedObject var alerts: ProgramStatusAlerts = .shared
  /// Closes the hosting popover (wired to `NSPopover.performClose` by `MenuBarController`).
  let onClose: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if !alerts.waiting.isEmpty {
          WaitingSectionHeader(title: "Waiting for you")
          ForEach(alerts.waiting) { request in
            WaitingRow(request: request, place: alerts.place(of: request)) {
              alerts.open(request)
              onClose()
            }
          }
          WaitingSectionHeader(title: "Unread notifications")
        }
        if let store = registry.lastActiveStore {
          NotificationsList(hidesRequests: true, onActivate: onClose)
            .environmentObject(store)
            .environmentObject(store.notifications)
        } else {
          HStack(spacing: 6) {
            Image(systemName: "bell.slash").font(.callout).foregroundStyle(.tertiary)
            Text("No notifications").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(width: 320, height: 360, alignment: .top)
  }
}

private struct WaitingSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 2)
      .accessibilityAddTraits(.isHeader)
  }
}

/// One request a program waits on the user for: the terminal, its workroom, what it waits for.
private struct WaitingRow: View {
  let request: WaitingRequest
  let place: String?
  let onOpen: () -> Void

  var body: some View {
    let kind = ProgramStatusPresentation.sentence(request.record.kind)
    let title = place ?? "Terminal"
    Button(action: onOpen) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "hand.raised.fill").foregroundStyle(ThemeService.shared.tokens.warning)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.callout).lineLimit(1)
          Text(kind).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          if request.stale {
            Text("Connection lost: status may be out of date")
              .font(.caption2).foregroundStyle(.tertiary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Go to \(title): \(kind)")
    .accessibilityLabel(
      "\(title), \(kind)\(request.stale ? ", may be out of date" : "")")
  }
}
