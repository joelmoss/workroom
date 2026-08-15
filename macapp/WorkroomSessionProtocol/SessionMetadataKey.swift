public enum SessionMetadataKey {
  public static let project = "project"
  public static let workroom = "workroom"
  public static let tab = "tab"
  public static let title = "title"

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
  ]
}
