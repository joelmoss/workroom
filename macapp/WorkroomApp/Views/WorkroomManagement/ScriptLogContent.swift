import AppKit
import SwiftUI

/// The header + scrolling body of a setup log. Shared between the blocking
/// setup view and the resizable under-terminal panel. A nil `onClose` hides the header
/// close button — the blocking view withholds it (you dismiss via its footer button,
/// and only once setup finishes).
struct ScriptLogContent: View {
  @ObservedObject var session: ScriptLogSession
  var onClose: (() -> Void)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      logBody
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      statusIcon
      Text(session.title).fontWeight(.medium).lineLimit(1)
      if let message = session.failureMessage {
        Text("— \(message)")
          .font(.callout)
          .foregroundStyle(ThemeService.shared.tokens.failure)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
      if let onClose {
        Button(action: onClose) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close log")
        .accessibilityLabel("Close log")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var statusIcon: some View {
    if !session.isFinished {
      ProgressView().controlSize(.small)
    } else if session.failureMessage != nil {
      Image(systemName: "xmark.octagon.fill").foregroundStyle(ThemeService.shared.tokens.failure)
    } else {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(
        ThemeService.shared.tokens.success)
    }
  }

  /// What an empty log says: still waiting while its run goes on, none once it has finished. Shared
  /// with a create's step logs (#483).
  static func emptyText(isFinished: Bool) -> String {
    isFinished ? "No output." : "Waiting for output…"
  }

  private var logBody: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if session.lines.isEmpty {
          Text(Self.emptyText(isFinished: session.isFinished))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } else {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(session.lines) { line in
              Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(line.id)
            }
          }
          .padding(12)
        }
      }
      .onChange(of: session.lines.count) { _ in
        if let last = session.lines.last {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }
}
