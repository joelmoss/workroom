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
  let onDismiss: () -> Void

  @State private var showDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 30))
          .foregroundStyle(.orange)
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
      if let log {
        // Pinned to the bottom: a script's last lines are usually where it says what went wrong.
        textBox(log, maxHeight: 240, id: "error.log")
          .defaultScrollAnchor(.bottom)
      }
      if let details {
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
        if details != nil || log != nil {
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
          Button(action.label, role: .destructive) {
            onDismiss()
            action.run()
          }
          .accessibilityIdentifier("error.action")
        }
        Button("OK") { onDismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("error.ok")
      }
    }
    .padding(20)
    .frame(width: 460)
    .onExitCommand { onDismiss() }
    // `.contain`, so the title, message and buttons stay findable inside the identified sheet
    // (see `VCSFailureSheet`).
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("error.sheet")
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
