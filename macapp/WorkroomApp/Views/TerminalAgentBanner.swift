import SwiftUI

/// The inline-agent banner shown below a failed terminal pane (issue #49, T8). A dumb renderer over
/// `AgentBannerViewModel`; all behaviour is closures the host wires to `TerminalAgentManager`.
struct TerminalAgentBanner: View {
  let state: AgentBannerState
  var onDiagnose: () -> Void
  var onInsertFix: (String) -> Void
  var onInvestigate: () -> Void
  var onDismiss: () -> Void

  @State private var confirmingDestructiveFix = false

  private var model: AgentBannerViewModel { AgentBannerViewModel(state: state) }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      leadingIcon
        .frame(width: 18)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 6) {
        Text(model.headline)
          .font(.callout)
          .fontWeight(.medium)
          .fixedSize(horizontal: false, vertical: true)

        if let detail = model.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
        }

        if let fix = model.fixCommand {
          fixChip(fix)
        }

        actions
      }

      Spacer(minLength: 0)
    }
    .padding(10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 1))
    .padding(8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal.agentBanner")
  }

  @ViewBuilder private var leadingIcon: some View {
    switch model.style {
    case .loading:
      ProgressView().controlSize(.small)
    case .ready:
      Image(systemName: "sparkles").foregroundStyle(.tint)
    case .failure:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .awaiting:
      Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
    case .remote:
      Image(systemName: "network").foregroundStyle(.secondary)
    }
  }

  private func fixChip(_ fix: String) -> some View {
    HStack(spacing: 6) {
      if model.fixIsDestructive {
        Image(systemName: "exclamationmark.octagon.fill")
          .foregroundStyle(.red)
          .help("This command is destructive — review it carefully before running.")
      }
      Text(fix)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .lineLimit(2)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 8) {
      if model.showsDiagnoseButton {
        Button("Diagnose", action: onDiagnose)
          .help("Ask the agent to diagnose this failure and suggest a fix.")
      }
      if model.showsInsertFix, let fix = model.fixCommand {
        Button("Insert fix") {
          if model.fixIsDestructive {
            confirmingDestructiveFix = true
          } else {
            onInsertFix(fix)
          }
        }
        .help(
          "Type the suggested command into the terminal (without running it — press Return yourself)."
        )
        .confirmationDialog(
          "Insert a destructive command?", isPresented: $confirmingDestructiveFix,
          titleVisibility: .visible
        ) {
          Button("Insert (don't run)", role: .destructive) { onInsertFix(fix) }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(fix)
        }
      }
      if model.showsInvestigate {
        Button("Investigate", action: onInvestigate)
          .help("Open an interactive agent session in this folder to dig deeper.")
      }
      Spacer(minLength: 0)
      if model.showsDismiss {
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark")
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
      }
    }
    .controlSize(.small)
    .font(.caption)
  }

  private var borderColor: Color {
    switch model.style {
    case .ready: return .accentColor.opacity(0.4)
    case .failure: return .orange.opacity(0.4)
    default: return Color.primary.opacity(0.12)
    }
  }
}
