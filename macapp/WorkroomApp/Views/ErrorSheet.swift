import AppKit
import SwiftUI

/// The app's error dialog: what went wrong in words a person can act on, a failed script's output
/// open beneath it, and the codes and raw text behind it under Details, collapsed. Laid out like
/// `VCSFailureSheet`, without its recovery actions.
struct ErrorSheet: View {
  let title: String
  let message: String
  var log: String? = nil
  let details: String?
  var action: ErrorAction? = nil
  /// Approve (#363): `log` is then the script to read first, shown from its top, and OK reads
  /// Cancel. The primary button, but never the default (Return): it runs code.
  var approval: ErrorAction? = nil
  /// With `approval`, the file name of the script `log` holds: it is then drawn as that file, as the
  /// creation pane draws a setup script, with a button in its top right corner to open it in a
  /// window of its own, and no Copy or Details.
  var scriptName: String? = nil
  /// With `approval`, what Cancel and Escape also do, under its label (Cancel Creation).
  var cancel: ErrorAction? = nil
  let onDismiss: () -> Void

  @State private var showDetails = false
  /// `action`'s confirmation is up.
  @State private var confirming = false

  /// The script to approve, when this sheet asks for one: drawn as its file, with no Copy.
  private var script: (text: String, name: String)? {
    guard approval != nil, let log, let scriptName else { return nil }
    return (log, scriptName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 30))
          .foregroundStyle(ThemeService.shared.tokens.warning)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text(title)
            .font(.headline)
            .accessibilityIdentifier("error.title")
          Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("error.message")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let script {
        ScriptBox(text: script.text, name: script.name, id: "error.log")
      } else if let log {
        // Pinned to the bottom: a script's last lines are usually where it says what went wrong.
        textBox(log, maxHeight: 240, id: "error.log")
          .defaultScrollAnchor(approval == nil ? .bottom : .top)
      }
      // Not for a script to approve: nothing failed, so there are no codes worth reading.
      if let details, script == nil {
        DisclosureGroup(isExpanded: $showDetails) {
          textBox(details, maxHeight: 160, id: "error.details")
        } label: {
          DisclosureLabel(isExpanded: $showDetails) {
            Text("Details").font(.subheadline.weight(.semibold))
          }
        }
        .accessibilityIdentifier("error.detailsToggle")
      }
      HStack(spacing: 8) {
        // A script to approve has no Copy: it pops out from its own box instead.
        if script == nil, details != nil || log != nil {
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
              [title, message, log, details].compactMap { $0 }.joined(separator: "\n\n"),
              forType: .string)
          }
          .help("Copy the message, its output and its details to the clipboard")
          .accessibilityIdentifier("error.copy")
        }
        Spacer()
        if let action {
          Button(action.label, role: action.destructive ? .destructive : nil) {
            if action.confirmation != nil {
              confirming = true
            } else {
              onDismiss()
              action.run()
            }
          }
          .accessibilityIdentifier("error.action")
        }
        if let approval {
          Button(cancel?.label ?? "Cancel", action: dismissCancelling)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("error.ok")
          // The primary, last and prominent, as the creation pane's Approve; but Return never
          // answers it, since it runs code.
          Button(approval.label) {
            onDismiss()
            approval.run()
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("error.approve")
        } else {
          Button("OK") { onDismiss() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("error.ok")
        }
      }
    }
    .padding(20)
    // Wider for a script to read before approving it.
    .frame(width: script == nil ? 460 : 640)
    .onExitCommand(perform: dismissCancelling)
    .confirmationDialog(
      action?.confirmation?.title ?? "", isPresented: $confirming, titleVisibility: .visible
    ) {
      if let action, let confirmation = action.confirmation {
        Button(confirmation.button) {
          onDismiss()
          action.run()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(action?.confirmation?.message ?? "")
    }
    // `.contain`, so the title, message and buttons stay findable inside the identified sheet
    // (see `VCSFailureSheet`).
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("error.sheet")
  }

  /// Cancel, or Escape: the sheet goes, and with it whatever `cancel` does.
  private func dismissCancelling() {
    onDismiss()
    cancel?.run()
  }

  private func textBox(_ text: String, maxHeight: CGFloat, id: String) -> some View {
    ScrollView {
      Text(text)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .accessibilityIdentifier(id)
    }
    .frame(maxHeight: maxHeight)
    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
  }
}

/// A `DisclosureGroup` label that toggles it when clicked: on macOS only the chevron does.
struct DisclosureLabel<Content: View>: View {
  @Binding var isExpanded: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    Button {
      withAnimation { isExpanded.toggle() }
    } label: {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
