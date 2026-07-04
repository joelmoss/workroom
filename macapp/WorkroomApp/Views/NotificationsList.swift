import SwiftUI

/// Resolve a notification's origin label from the live model so a workroom's display label
/// (issue #41) shows and tracks renames; falls back to the snapshot captured on the record when the
/// target no longer exists (a since-deleted workroom keeps its last-known name). Shared by
/// `NotificationsList` and `SidebarNotificationStrip` so both surfaces show identical labels.
@MainActor func resolvedNotificationSource(_ store: AppStore, _ item: WorkroomNotification)
  -> String
{
  let live = store.notificationSource(forTargetID: item.targetID)
  return live.isEmpty ? item.source : live
}

/// Open a notification's terminal (`AppStore.openTerminal`, which also dismisses it) then run
/// `onActivate` so a host that needs to close itself (a popover) can. Shared row activation so the
/// sidebar strip and the popover/inspector rows can't drift in behaviour.
@MainActor func openNotification(
  _ store: AppStore, _ item: WorkroomNotification, then onActivate: (() -> Void)?
) {
  store.openTerminal(targetID: item.targetID, tabID: item.tabID, notifID: item.id)
  onActivate?()
}

/// The notifications history as a list, newest first — the shared body behind the bell popover and
/// the sidebar `+N` popover (`NotificationsPopover`), so the rows look identical everywhere. There's
/// no read state: tapping a row opens the terminal it came from (which also dismisses it), then runs
/// `onActivate` so a host that needs to close itself (the popover) can.
struct NotificationsList: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  /// When true, drop the oldest notification (`items.first`) — it's the one already shown in the
  /// sidebar strip, so the strip's `+N` popover lists everything *else* (issue #118). The bell popover
  /// leaves this false to list the full backlog. Computed live from `notifications.items` so both stay
  /// current as rows are opened or deleted while the popover is open.
  var dropFirst: Bool = false
  /// Called after a row opens its terminal — lets a popover dismiss. A host that stays open passes nil.
  var onActivate: (() -> Void)?
  /// The row currently hovered — used to hide the hairlines directly above and below it so the hovered
  /// row's rounded highlight reads as one clean chip.
  @State private var hoveredID: WorkroomNotification.ID?

  var body: some View {
    let source = dropFirst ? Array(notifications.items.dropFirst()) : notifications.items
    if source.isEmpty {
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
      // A plain `VStack`, not a `List`/`ScrollView`: the host (a popover's `ScrollView`) does the
      // scrolling and sizes to the body's natural height. A nested greedy scroll container would
      // collapse the body and clip the rows; a transparent `VStack` also lets the host background
      // show through and gives exact control over row margins.
      // Newest first; the store appends chronologically.
      let rows = Array(source.reversed())
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
          NotificationRow(
            item: item, source: resolvedNotificationSource(store, item),
            onOpen: { openNotification(store, item, then: onActivate) },
            onDelete: { notifications.dismiss(notifID: item.id) },
            onHoverChange: { hovering in
              hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
            }
          )
          // A hairline between rows (not after the last), inset to start under the row text. Hidden
          // (kept for layout, so rows don't jump) when the row on either side of it is hovered, so the
          // hovered row's rounded highlight isn't crossed by a divider above or below it.
          if index < rows.count - 1 {
            Divider()
              .padding(.horizontal, 10)
              .opacity(hoveredID == item.id || hoveredID == rows[index + 1].id ? 0 : 1)
          }
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 6)
    }
  }
}

/// The shared notifications popover body (issue #118): the scrollable `NotificationsList` with a
/// Clear-all action pinned at the bottom. Both notification popovers use it with identical
/// functionality — the title-bar bell lists the full backlog (`dropFirst: false`), the sidebar `+N`
/// badge lists everything except the oldest already shown in the strip (`dropFirst: true`). The bell
/// hand-hosts this in an `NSPopover`; the `+N` badge presents it via a SwiftUI `.popover`.
struct NotificationsPopover: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  /// Forwarded to `NotificationsList`: drop the oldest (the strip's displayed one) for the `+N` popover.
  var dropFirst: Bool = false
  /// Forwarded to `NotificationsList` so a row tap can close the hosting popover.
  var onActivate: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      // The rows stack from the top (a fixed-height frame would otherwise centre a short list) and a
      // long list scrolls instead of clipping.
      ScrollView {
        NotificationsList(dropFirst: dropFirst, onActivate: onActivate)
          .environmentObject(store)
          .environmentObject(notifications)
      }
      .frame(maxHeight: .infinity)

      // Clear-all pinned at the bottom — a full-width destructive action, disabled when empty. Clearing
      // empties the store, so the list drops to its "No notifications" state (the popover stays open).
      Divider()
      Button {
        notifications.clear()
      } label: {
        Label("Clear All", systemImage: "trash")
          .font(.caption)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .disabled(notifications.items.isEmpty)
      .help("Clear all notifications")
      .accessibilityLabel("Clear all notifications")
    }
    .frame(width: 320, height: 360, alignment: .top)
    .accessibilityIdentifier("notifications.popover")
  }
}

/// The left sidebar's bottom notification band (issue #118): shows only the **oldest** pending
/// notification to save space, with a trailing `+N` badge (when there are more) that opens a popover
/// of the rest. Tapping the row opens its terminal (dismissing it), which reveals the next oldest.
///
/// Always mounted; the row subtree is inserted only when there's an oldest to show, but the change is
/// driven by an enclosing `.animation(value: items.count)` + a `.transition`, so the band slides in
/// and out rather than snapping (SwiftUI doesn't cross-fade a bare structural insertion — learning
/// `swiftui-scrim-structural-gate-snaps`). It reuses `NotificationRow` and the shared
/// `resolvedNotificationSource`/`openNotification` helpers so it stays in lock-step with the popover.
struct SidebarNotificationStrip: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @State private var showExtras = false
  @State private var plusHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  var body: some View {
    VStack(spacing: 0) {
      if let oldest = notifications.items.first {
        // The row + a hairline separating it from the theme/add bar below. The enclosing sidebar
        // `footer` supplies the solid background and the top hairline (issue #118), so this band adds
        // none of its own — it just slides in/out above the bar. The `+N` badge rides as the row's
        // trailing accessory so hovering anywhere on the row highlights the whole thing.
        VStack(spacing: 0) {
          NotificationRow(
            item: oldest, source: resolvedNotificationSource(store, oldest),
            onOpen: { openNotification(store, oldest, then: nil) },
            onDelete: { notifications.dismiss(notifID: oldest.id) },
            trailingAccessory: notifications.items.count > 1
              ? AnyView(plusBadge(extra: notifications.items.count - 1)) : nil
          )
          Divider()
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    // The always-present container drives the inner insertion/removal transition — without this the
    // band would snap in on the first arrival and out on the last dismissal.
    // NB: no `.accessibilityIdentifier` on this container — an ancestor identifier overrides the
    // children's own (the row + the `+N` badge), so it would mask `sidebar.notifications.plus`.
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: notifications.items.count)
  }

  /// The `+N` badge: opens a popover of the notifications *other than* the displayed oldest, newest
  /// first — `dropFirst: true` computes that live so it tracks opens/deletes while the popover is open.
  private func plusBadge(extra: Int) -> some View {
    Button {
      showExtras.toggle()
    } label: {
      Text("+\(extra)")
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        // The count button carries its own hover: a base pill that intensifies when hovered, so it
        // reads as a distinct control even while the whole row is also highlighted.
        .background(Capsule().fill(theme.tokens.hover.opacity(plusHovering ? 1 : 0.5)))
    }
    .buttonStyle(.plain)
    .onHover { plusHovering = $0 }
    .padding(.trailing, 8)
    .help(extra == 1 ? "1 more notification" : "\(extra) more notifications")
    .accessibilityLabel(extra == 1 ? "1 more notification" : "\(extra) more notifications")
    .accessibilityIdentifier("sidebar.notifications.plus")
    .popover(isPresented: $showExtras, arrowEdge: .top) {
      NotificationsPopover(dropFirst: true, onActivate: { showExtras = false })
        .environmentObject(store)
        .environmentObject(notifications)
    }
  }
}

/// One notification row. Tapping opens the terminal it came from (`onOpen`). Carries a subtle
/// rounded hover fill — like the Changes panel's file rows — so it reads as the clickable target it
/// is; a plain `.buttonStyle(.plain)` row gave no hover feedback.
private struct NotificationRow: View {
  let item: WorkroomNotification
  /// The origin label to show (project, or "project / workroom") — resolved by the caller via
  /// `resolvedNotificationSource` so it reflects a workroom's display label (issue #41). Distinct
  /// from `item.source` (the snapshot captured on the record).
  let source: String
  let onOpen: () -> Void
  /// Right-click → "Delete Notification": dismisses just this notification. Optional so a host that
  /// doesn't offer per-row deletion can omit the menu.
  var onDelete: (() -> Void)?
  /// Reports hover changes to the parent list so it can hide the hairlines flanking the hovered row.
  var onHoverChange: ((Bool) -> Void)?
  /// An optional trailing control that sits inside the row's hover region but keeps its own hit target
  /// and hover state — the sidebar strip's `+N` badge. The whole row (content + accessory) shares one
  /// hover background; the accessory paints its own on top.
  var trailingAccessory: AnyView?
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onOpen) {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if let trailingAccessory {
        trailingAccessory
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The hover fill covers the ENTIRE row — content and the trailing accessory — so hovering anywhere
    // on the row (including over the `+N` badge) highlights the whole thing.
    .background(
      RoundedRectangle(cornerRadius: 5).fill(theme.tokens.hover.opacity(hovering ? 1 : 0))
    )
    .contentShape(Rectangle())
    .onHover {
      hovering = $0
      onHoverChange?($0)
    }
    .contextMenu {
      if let onDelete {
        Button("Delete Notification", role: .destructive, action: onDelete)
      }
    }
  }

  /// Shared abbreviated relative formatter ("2 min. ago", "just now").
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  /// An approximate "time ago" string for `date`. Under ~10s reads "just now" rather than a jittery
  /// "0 sec. ago".
  static func timeAgo(_ date: Date) -> String {
    if Date().timeIntervalSince(date) < 10 { return "just now" }
    return relativeFormatter.localizedString(for: date, relativeTo: Date())
  }

  // No read/unread state to indicate (read ⇒ dismissed), so there's no leading dot. A titleless
  // notification leads with its body rather than a placeholder; one with neither shows just its
  // source + time.
  private var content: some View {
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
          if !source.isEmpty {
            Text(source).lineLimit(1)
            Text("·")
          }
          // A static approximate "time ago" (e.g. "2 min. ago"), recomputed on re-render.
          Text(Self.timeAgo(item.date))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
  }
}
