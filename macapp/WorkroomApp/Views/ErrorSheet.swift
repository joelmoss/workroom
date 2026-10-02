import AppKit
import SwiftUI

/// The app's error dialog: what went wrong in words a person can act on, and the codes and raw
/// text behind it under Details, collapsed. Laid out like `VCSFailureSheet`, without its recovery
/// actions.
struct ErrorSheet: View {
  let title: String
  let message: String
  let details: String?
  let link: AppStore.ErrorLink?
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
      if let details {
        DisclosureGroup(isExpanded: $showDetails) {
          ScrollView {
            Text(details)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
              .accessibilityIdentifier("error.details")
          }
          .frame(maxHeight: 160)
          .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        } label: {
          DisclosureLabel(isExpanded: $showDetails) {
            Text("Details").font(.subheadline.weight(.semibold))
          }
        }
        .accessibilityIdentifier("error.detailsToggle")
      }
      HStack(spacing: 8) {
        if details != nil {
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
              [title, message, details].compactMap { $0 }.joined(separator: "\n\n"),
              forType: .string)
          }
          .help("Copy the message and its details to the clipboard")
          .accessibilityIdentifier("error.copy")
        }
        Spacer()
        if let link {
          Button(link.title) {
            NSWorkspace.shared.open(link.url)
            onDismiss()
          }
          .accessibilityIdentifier("error.link")
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
