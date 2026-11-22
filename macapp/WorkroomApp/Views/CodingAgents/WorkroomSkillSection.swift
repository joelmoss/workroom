import Defaults
import SwiftUI

/// Settings ▸ AI Agents ▸ Workroom skill (#697): one toggle, off by default, that installs the
/// Workroom skill for Claude Code and Codex on this Mac and each host, and removes it when turned
/// off. Its note says where it writes; a line under it says when a skill was left alone or failed.
struct WorkroomSkillSection: View {
  @Default(.installWorkroomSkill) private var installWorkroomSkill
  @ObservedObject private var workroomSkill = WorkroomSkill.shared

  var body: some View {
    Section {
      // Set through the binding, not an `onChange`: the `Defaults` wrapper invalidates the view
      // asynchronously, and the install should follow the click, not the next redraw.
      Toggle(
        isOn: Binding(
          get: { installWorkroomSkill },
          set: { on in
            installWorkroomSkill = on
            workroomSkill.settingChanged(to: on)
          })
      ) {
        Text("Install the Workroom skill for Claude Code and Codex")
        Text(
          "Adds a skill to ~/.claude and ~/.codex on this Mac and each host, and removes it "
            + "when turned off.")
      }
      .help(
        "Teaches Claude Code and Codex the workroom commands that list, read, wait on and type "
          + "into your other terminals. Workroom writes only its own skills/workroom folder, "
          + "and only where the agent is set up. A host gets the skill, or loses it, the next "
          + "time Workroom connects to it."
      )
      .accessibilityIdentifier("settings.control.workroomSkill")

      if let notice = workroomSkill.notice {
        Label {
          Text(notice)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        .help(notice)
        .accessibilityIdentifier("settings.control.workroomSkillNotice")
      }
    } header: {
      Text("Workroom skill")
    }
  }
}
