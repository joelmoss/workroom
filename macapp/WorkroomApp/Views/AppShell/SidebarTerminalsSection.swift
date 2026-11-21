import DesignSystem
import SwiftUI
import WorkroomDomain

/// The Terminals section at the top of the sidebar (ADR 0077): a heading that folds as a project
/// does, with New Standalone Terminal beside it, and one row per terminal with no project. The rows
/// are the app's `TerminalsSection`, so every window lists the same ones.
struct SidebarTerminalsSection: View {
  let store: AppStore
  let actions: SidebarActions
  let headingInsets: EdgeInsets
  let rowInsets: EdgeInsets

  private var section: TerminalsSection { store.terminalsSection }

  var body: some View {
    SidebarTerminalsHeading(section: section, newTerminal: { store.newStandaloneTerminal() })
      .listRowInsets(headingInsets)
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
    if !section.isFolded {
      ForEach(section.entries, id: \.self) { entry in
        let sid = entry.sidebarID
        SidebarStandaloneRow(store: store, sid: sid, actions: actions)
          .listRowInsets(rowInsets)
          .listRowSeparator(.hidden)
          .listRowBackground(SidebarRowBackground(store: store, id: sid, hovered: false))
      }
    }
  }
}

/// "Terminals", its fold chevron and its New Standalone Terminal button.
private struct SidebarTerminalsHeading: View {
  let section: TerminalsSection
  let newTerminal: () -> Void

  var body: some View {
    HStack(spacing: Spacing.s) {
      Button {
        section.isFolded.toggle()
      } label: {
        HStack(spacing: Spacing.s) {
          Text("Terminals").font(.callout).fontWeight(.medium)
            .foregroundStyle(.secondary)
          Image(systemName: section.isFolded ? "chevron.right" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(section.isFolded ? "Show terminals with no project" : "Hide terminals with no project")
      .accessibilityHint(section.isFolded ? "Expand terminals" : "Collapse terminals")
      .accessibilityIdentifier("sidebar.terminals")

      Button(action: newTerminal) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowMetrics.caretWidth, height: SidebarRowMetrics.rowHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(
        "New Standalone Terminal" + Shortcuts.shared.table.hint(for: .newStandaloneTerminal)
      )
      .accessibilityLabel("New Standalone Terminal")
      .accessibilityIdentifier("sidebar.terminals.new")
    }
    .padding(.trailing, Spacing.s)
    .frame(height: SidebarRowMetrics.rowHeight)
  }
}

/// A standalone terminal's row: a terminal glyph and its terminal's name. Selecting it shows the
/// terminal in this window.
private struct SidebarStandaloneRow: View {
  let store: AppStore
  let sid: SidebarID
  let actions: SidebarActions

  private var title: String { store.target(for: sid)?.title ?? TerminalsSection.untitled }
  /// What its terminal reports, as a workroom's row shows it (#358): waiting, then a stopped
  /// error, then running.
  private var activity: SidebarTargetActivity {
    sid.targetID.map(store.sidebarActivity(of:)) ?? SidebarTargetActivity()
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "terminal")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
      Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
      if let id = sid.targetID {
        SidebarUnreadDot(source: .target(id))
        if activity.waiting > 0 {
          NeedsYouButton(count: activity.waiting, stale: activity.waitingStale) {
            actions.showWaiting([id])
          }
        } else if activity.failed || activity.running {
          RunningSpinner(failed: activity.failed)
        }
      }
    }
    .frame(height: SidebarRowMetrics.rowHeight)
    .contentShape(Rectangle())
    .onTapGesture { actions.select(sid) }
    .help(title)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.standalone.\(sid.targetID?.encoded ?? "")")
  }
}
