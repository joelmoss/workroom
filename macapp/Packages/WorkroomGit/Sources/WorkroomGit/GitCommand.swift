/// What every `git` invocation the app runs itself shares.
public enum GitCommand {
  /// `-c` overrides prepended to every `git` invocation that can read the index or run a diff (the
  /// origin and remote probes read only config and refs, so they go without). A workroom can be a
  /// clone of an *untrusted* repo, and the status sweep runs git automatically on
  /// load/focus/selection — without this, a repo-local `core.fsmonitor` runs an arbitrary program on
  /// a plain `git status`. The diff probe additionally passes `--no-ext-diff`/`--no-textconv` (and
  /// the runner unsets `GIT_EXTERNAL_DIFF`) so `diff.external`/textconv config can't execute either.
  /// These flags go before the subcommand.
  public static let hardening = ["-c", "core.fsmonitor="]
}
