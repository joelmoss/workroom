import AppKit
import SwiftUI

/// The VCS failure dialog: what failed, the whole message, the tool's own output, and every action that
/// can be taken about it.
///
/// **Why a dialog at all.** The toolbar's sync segment is a 114pt cell holding one line, so a failure
/// could only ever render as a truncated notice — "Describe the change bef…" was the report that prompted
/// this. The rest lived in a tooltip, which is a hover away, can't be copied, can't be clicked, and
/// vanishes the moment you move the pointer toward the thing it told you to fix. The bar keeps the
/// notice; this carries the message.
///
/// Presented by `VCSFailurePresenter` on the app's root, NOT on the inspector: an action can be started
/// from the Source Control menu with the inspector hidden, and a dialog that only appears when a
/// particular pane happens to be open is worse than no dialog.
struct VCSFailureSheet: View {
  let dialog: VCSFailureDialog
  /// Runs the recovery. Routed back through `AppStore.performRemoteAction` by the caller so a Pull
  /// recovery still meets the dirty-tree confirmation — a gate only some entry points honour isn't one.
  let onRecover: (VCSRemoteAction) -> Void
  let onDismiss: () -> Void

  /// Collapsed by default: the tool's output is evidence for when the written remedy isn't enough, and
  /// expanding it by default would bury the remedy under a wall of stderr.
  @State private var showDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      // Selectable, because half of these messages contain a path or a command the user needs to get
      // into a terminal. `fixedSize(vertical:)` is what lets it wrap to its full height instead of
      // truncating to one line inside the sheet's fixed width — the very failure mode this replaces.
      Text(dialog.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("vcs.failure.message")
      if let details = dialog.details {
        detailsSection(details)
      }
      Divider()
      buttons
    }
    .padding(20)
    .frame(width: 460)
    // `children: .contain` is load-bearing, not decoration. An `.accessibilityIdentifier` on a plain
    // container makes SwiftUI treat that container as ONE element and absorb everything inside it: the
    // sheet was findable and its title, message and buttons were not — including by XCUITest, which
    // caught exactly this.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("vcs.failure.sheet")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 30))
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(dialog.title)
          .font(.headline)
          .accessibilityIdentifier("vcs.failure.title")
        // Present only when the failure belongs to a workroom that is no longer selected. Without it the
        // dialog would describe the action but not its subject, which over a different workroom reads as
        // a failure of the one on screen.
        if let subtitle = dialog.subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("vcs.failure.subtitle")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// The tool's own output, monospaced and scrolled rather than truncated — a rejected push's stderr
  /// runs to a dozen lines and the useful one is rarely the first.
  private func detailsSection(_ details: String) -> some View {
    DisclosureGroup(isExpanded: $showDetails) {
      ScrollView {
        Text(details)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .accessibilityIdentifier("vcs.failure.details")
      }
      .frame(maxHeight: 160)
      .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    } label: {
      Text("Details").font(.subheadline.weight(.semibold))
    }
    .accessibilityIdentifier("vcs.failure.detailsToggle")
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      Button("Copy") { copyReport() }
        .help("Copy the message and the tool's output to the clipboard")
        .accessibilityIdentifier("vcs.failure.copy")
      // Only for a located lock file: the fix is a file operation Workroom deliberately won't perform
      // (see `VCSRemoteFailure.locked`), so the least it can do is hand over the file.
      if let lockPath = dialog.lockPath {
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lockPath)])
        }
        .accessibilityIdentifier("vcs.failure.revealLock")
      }
      Spacer()
      Button("Dismiss") { onDismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("vcs.failure.dismiss")
      // Absent whenever `retryAction` says the same command would fail identically — a doomed default
      // button is the defect the failure tier already exists to prevent, and a dialog makes it worse by
      // putting it under the return key.
      if let recovery = dialog.recovery {
        Button(recovery.label) {
          onDismiss()
          onRecover(recovery)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("vcs.failure.recover")
      }
    }
  }

  /// Title, message and output as one block — what you'd paste into an issue or a chat.
  ///
  /// The subtitle is part of it: it names the workroom the failure belongs to, which is the one fact a
  /// pasted report from a background workroom would otherwise lose — exactly what the subtitle exists for.
  private func copyReport() {
    let heading = [dialog.title, dialog.subtitle].compactMap { $0 }.joined(separator: " ")
    let text = [heading, dialog.message, dialog.details].compactMap { $0 }
      .joined(separator: "\n\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// Bridges `RemoteStateModel.failureReport` to the sheet.
///
/// A `ViewModifier` with its own `@ObservedObject` for the reason `VCSToolbar` documents: `AppStore`
/// holds `RemoteStateModel` but does not forward its `objectWillChange`, so a view that reaches it
/// through the store alone never repaints when a failure lands — and a sheet that never repaints never
/// presents.
struct VCSFailurePresenter: ViewModifier {
  @ObservedObject var model: RemoteStateModel
  let onRecover: (VCSRemoteAction) -> Void

  func body(content: Content) -> some View {
    content.sheet(
      item: Binding(
        get: { model.failureReport },
        // Only the nil direction is honoured: the sheet is presented by the model raising a report, never
        // by SwiftUI writing one back.
        set: { if $0 == nil { model.dismissFailureReport() } })
    ) { report in
      VCSFailureSheet(
        dialog: VCSSyncPresenter.failureDialog(
          report.failure, action: report.action, workroom: report.workroom, isRead: report.isRead,
          now: Date()),
        onRecover: onRecover,
        onDismiss: { model.dismissFailureReport() })
    }
  }
}
