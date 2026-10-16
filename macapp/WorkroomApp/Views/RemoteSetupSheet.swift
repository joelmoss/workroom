import SwiftUI

/// The sheet a remote provider's first-time setup is shown in (`ExeDevSetupSheet`,
/// `BoxdSetupSheet`): a title and what the provider is, the provider's steps (`SetupStep`), and
/// Cancel / Create Workroom, which carries on with the create the sheet interrupted once the setup
/// is ready. Closing the sheet cancels the setup, so nothing it started outlives it.
struct RemoteSetupSheet<Steps: View>: View {
  let title: String
  /// Markdown, so it can link to the provider's site.
  let intro: String
  let setup: any RemoteSetup
  /// Prefixes the buttons' accessibility identifiers, such as `exeDevSetup`.
  let identifier: String
  let onCreate: () -> Void
  let onCancel: () -> Void
  @ViewBuilder var steps: Steps

  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.title2.bold())
        Text(LocalizedStringKey(intro))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.bottom, 20)

      VStack(alignment: .leading, spacing: 18) { steps }

      Spacer(minLength: 20)

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("\(identifier).cancel")
        Button("Create Workroom", action: onCreate)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!setup.isReady)
          .accessibilityIdentifier("\(identifier).create")
      }
    }
    .padding(24)
    .frame(width: 520)
    .frame(minHeight: 460)
    .background(theme.tokens.panel)
    .onDisappear { setup.cancel() }
  }
}

/// Where a setup step stands, as its indicator shows it.
enum SetupStepState {
  case locked, current, waiting, done
}

/// One step of a setup sheet: its indicator, title and content.
struct SetupStep<Content: View>: View {
  let title: String
  let state: SetupStepState
  @ViewBuilder var content: Content

  private let theme = ThemeService.shared

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      indicator
        .frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
          .foregroundStyle(state == .locked ? .secondary : .primary)
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(title) step")
  }

  @ViewBuilder private var indicator: some View {
    switch state {
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.tokens.success)
        .font(.system(size: 17))
        .accessibilityLabel("Done")
    case .waiting:
      ProgressView().controlSize(.small)
        .accessibilityLabel("Waiting")
    case .current:
      Image(systemName: "circle.fill").foregroundStyle(theme.tokens.accent)
        .font(.system(size: 9))
        .frame(width: 17, height: 17)
        .accessibilityLabel("To do")
    case .locked:
      Image(systemName: "circle").foregroundStyle(theme.tokens.fgDim)
        .font(.system(size: 9))
        .frame(width: 17, height: 17)
        .accessibilityLabel("Not yet")
    }
  }
}

/// A step's explanation.
struct SetupDetail: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(LocalizedStringKey(text))
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// What went wrong with a step.
struct SetupProblem: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.callout)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
  }
}
