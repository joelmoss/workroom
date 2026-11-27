import Defaults
import WorkroomWire

/// "Resume programs after a restart" (ADR 0082, #827), Settings ▸ Terminal: the one place the app
/// reads whether a pane whose session is gone runs again the program its record names. Everything
/// that acts on it reads it here, as Claude Code's hook install will (#828): `isOn` now, `updates`
/// to follow it.
///
/// It reaches each daemon per session, as the session is made (`sessionMetadata`), never as a
/// daemon-wide flag: a daemon is shared by every Mac and app build that attaches to it. Off, a new
/// session gets no resume token, so its daemon accepts no reports from it, and a pane whose session
/// is gone is sent no record: a new shell on this Mac, ended on a host. A session made while it was
/// on keeps its token until it ends. Turned on again, it applies to sessions made after that.
///
/// The records a tab saved stay while it's off, so a pane whose session lives on resumes after a
/// later restart once it's on again; a pane given a new shell while it's off forgets its record
/// once the new daemon has its session, as a declined resume does, since that shell is what the
/// pane runs now (`PaneSessionAttachment.sessionHeard`).
enum ProgramResume {
  /// Whether programs resume.
  static var isOn: Bool { Defaults[.resumePrograms] }

  /// Each change of the setting, starting with its value now.
  static func updates() -> AsyncStream<Bool> { Defaults.updates(.resumePrograms) }

  /// What a session's attach says of the setting (`SessionMetadataKey.programResume`), which the
  /// daemon that creates the session reads: nothing when it's on, as an older app says.
  static func sessionMetadata(isOn: Bool) -> [(key: String, value: String)] {
    isOn ? [] : [(SessionMetadataKey.programResume, SessionMetadataKey.programResumeOff)]
  }
}
