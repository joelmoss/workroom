import SwiftUI

/// The notifications history as a list, newest first — the shared body behind both the right-hand
/// inspector's Notifications section (`RightInspector`) and the menu bar popover
/// (`MenuBarNotificationsView`), so the rows look identical in both. There's no read state: tapping a row opens the terminal it came
/// from (`AppStore.openTerminal`, which also dismisses it), then runs `onActivate` so a host that
/// needs to close itself (the popover) can.
struct NotificationsList: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  /// Called after a row opens its terminal — lets the menu bar popover dismiss. The inspector,
  /// which stays open, passes nil.
  var onActivate: (() -> Void)?

  var body: some View {
    if notifications.items.isEmpty {
      // Compact, left-aligned, icon-first empty state (issue #24 feedback) — not the large
      // centered ContentUnavailableView.
      HStack(spacing: 6) {
        Image(systemName: "bell.slash").font(.callout).foregroundStyle(.tertiary)
        Text("No notifications").font(.callout).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("No notifications")
    } else {
      List {
        // Newest first; the store appends chronologically.
        ForEach(notifications.items.reversed()) { item in
          Button {
            store.openTerminal(targetID: item.targetID, tabID: item.tabID, notifID: item.id)
            onActivate?()
          } label: {
            row(item)
          }
          .buttonStyle(.plain)
        }
      }
      .listStyle(.inset)
    }
  }

  private func row(_ item: WorkroomNotification) -> some View {
    // No read/unread state to indicate (read ⇒ dismissed), so there's no leading dot. A titleless
    // notification leads with its body rather than a placeholder; one with neither shows just its
    // source + time.
    let headline = item.title.isEmpty ? (item.body ?? "") : item.title
    let subtext = item.title.isEmpty ? nil : item.body
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        if !headline.isEmpty {
          HStack(spacing: 4) {
            Text(headline)
              .font(.callout)
              .fontWeight(.semibold)
              .lineLimit(1)
            if item.count > 1 {
              Text("×\(item.count)").font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        if let subtext, !subtext.isEmpty {
          Text(subtext).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        HStack(spacing: 4) {
          if !item.source.isEmpty {
            Text(item.source).lineLimit(1)
            Text("·")
          }
          Text(item.date, style: .relative)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}
