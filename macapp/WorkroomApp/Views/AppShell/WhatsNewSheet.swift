import AppKit
import SwiftUI

/// The release notes the `WhatsNewSheet` shows. Wraps them in an `Identifiable` so a single
/// `.sheet(item:)` drives presentation; the stable `id` keeps it one sheet. The auto
/// (post-update) launch check is the only producer.
struct WhatsNewSheetContent: Identifiable {
  let notes: [ReleaseNote]
  var id: String { "whatsNew" }
}

/// The "What's New" dialog: a scrollable list of release notes, shown automatically on the first
/// launch after an update.
struct WhatsNewSheet: View {
  let content: WhatsNewSheetContent
  let onClose: () -> Void

  @Environment(\.openURL) private var openURL
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      notesList
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .frame(width: 520, height: 600)
    .accessibilityIdentifier("whatsNew.sheet")
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable().scaledToFit().frame(width: 40, height: 40)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("What’s New in Workroom").font(.headline)
        Text("Recent updates").font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(16)
  }

  private var notesList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(content.notes) { note in releaseSection(note) }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func releaseSection(_ note: ReleaseNote) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(note.title).font(.title3.bold())
        Spacer()
        if let date = note.date {
          Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
        }
      }
      ReleaseNotesMarkdown(markdown: note.bodyMarkdown)
      if let url = note.url {
        Button("View on GitHub ↗") { openURL(url) }
          .buttonStyle(.link)
          .font(.callout)
      }
    }
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Done") { onClose() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(16)
  }
}
