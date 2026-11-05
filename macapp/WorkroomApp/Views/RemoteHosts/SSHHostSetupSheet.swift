import SwiftUI

struct SSHHostSetupSheet: View {
  @ObservedObject var setup: SSHHostSetup
  let onCreate: () -> Void
  let onCancel: () -> Void

  var body: some View {
    RemoteSetupSheet(
      title: "Create on an SSH host",
      intro: "Use a Linux server you already have. Each workroom gets its own folder. "
        + "The server stays yours.",
      setup: setup, identifier: "sshHostSetup",
      onCreate: create, onCancel: onCancel
    ) {
      SetupStep(title: "Host", state: setup.driver == nil ? .current : .done) {
        TextField("SSH alias or user@host", text: $setup.destination)
          .textFieldStyle(.roundedBorder)
          .disabled(setup.checking)
          .accessibilityIdentifier("sshHostSetup.destination")
        if !setup.recentHosts.isEmpty {
          Menu("Recent hosts") {
            ForEach(setup.recentHosts, id: \.self) { host in
              Button(host) { setup.destination = host }
            }
          }
          .disabled(setup.checking)
        }
        SetupDetail(
          "Uses your SSH config and keys. Add a locked key to ssh-agent or the Keychain first.")
        HStack {
          Button("Check Host") { setup.check() }
            .disabled(setup.destination.isEmpty || setup.checking)
            .accessibilityIdentifier("sshHostSetup.check")
          if setup.checking { ProgressView().controlSize(.small) }
        }
        if let key = setup.hostKey {
          Text("Trust this host key?").font(.headline)
          Text(setup.destination).textSelection(.enabled)
          Text(key.fingerprint).font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
          SetupDetail("Compare this fingerprint with the server's key before trusting it.")
          Button("Trust") { setup.trust() }
            .accessibilityIdentifier("sshHostSetup.trust")
        }
        if let problem = setup.problem { SetupProblem(problem) }
      }
      SetupStep(title: "Parent folder", state: setup.driver == nil ? .locked : .current) {
        TextField("~/workrooms", text: $setup.parent)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("sshHostSetup.parent")
        SetupDetail(
          "Inside your home on the server. Workroom adds a folder named for the workroom here.")
      }
    }
  }

  private func create() {
    setup.remember()
    onCreate()
  }
}
