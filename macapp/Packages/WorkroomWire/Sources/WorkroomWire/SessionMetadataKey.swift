public enum SessionMetadataKey {
  public static let project = "project"
  public static let workroom = "workroom"
  public static let tab = "tab"
  public static let title = "title"
  /// A run session's command, as the app that started it asked for it (#836). The daemon lists it
  /// from the `WORKROOM_SESSION_COMMAND` a run's attach already carries, so it has no variable of its
  /// own here; absent for a shell, a command over the daemon's bound, or an older daemon's run.
  /// Not `command`, which the list gives a session's foreground program.
  public static let runCommand = "run_command"
  /// When the daemon made the session, in milliseconds since the epoch. The daemon adds it itself, so
  /// it has no environment variable (#255).
  public static let created = "created"
  /// The app's "Resume programs after a restart" for a session it creates (#827), set only to
  /// `programResumeOff` when it's off: that session gets no resume token, and so accepts no
  /// reports. The daemon reads it as it creates the session and keeps none of it; absent is on.
  public static let programResume = "programResume"
  /// `programResume`'s value for off (`resume::OFF` in the daemon).
  public static let programResumeOff = "off"

  /// The canonical key <-> environment-variable-name association for this metadata bag, crossing
  /// the process boundary in both directions: the app's PersistentSessionService writes these
  /// vars into a spawned session's environment from its metadata, and the workroom-session CLI
  /// helper (main.swift) reads them back out of its own environment on reattach to rebuild the
  /// metadata bag. One shared table instead of two independently hand-maintained copies, which
  /// had already silently drifted (the `tab` entry is carried here but has no populating call
  /// site anywhere in the app today — dead, but kept rather than dropped silently).
  public static let environmentVariables: [(key: String, variable: String)] = [
    (project, "WORKROOM_SESSION_PROJECT"),
    (workroom, "WORKROOM_SESSION_WORKROOM"),
    (tab, "WORKROOM_SESSION_TAB"),
    (title, "WORKROOM_SESSION_TITLE"),
    (programResume, "WORKROOM_SESSION_PROGRAM_RESUME"),
  ]
}
