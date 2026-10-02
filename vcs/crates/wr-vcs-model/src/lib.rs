//! Domain types for Workroom's VCS reads — the durable core.
//!
//! Free of any VCS library on purpose: `wr-vcs-git` produces these shapes and `wr-agent` serves them
//! as JSON. The SwiftUI app maps them into its own Swift models rather than binding the UI to this
//! wire format directly.

use serde::{Deserialize, Serialize};

/// How a file changed within a changeset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    Conflicted,
    Other,
}

/// One changed file in a changeset. `old_path` is set for renames/copies.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChangedFile {
    pub path: String,
    pub old_path: Option<String>,
    pub kind: ChangeKind,
    /// Changed lines vs the same base the `kind` was computed against (the commit's FIRST parent).
    /// `None` means "deliberately not counted", never a zero-valued `LineStats`: a binary file, a
    /// file over the backend's size ceiling, or a non-file entry (symlink/tree/submodule/unreadable).
    /// A conflicted file counts its marker text, matching what a git worktree diff reports.
    ///
    /// One `Option`, not two independently-nullable fields: the backend always counts both sides
    /// together or neither, so "counted" vs "deliberately not counted" is one decision, not two that
    /// merely happen to always agree.
    pub line_stats: Option<LineStats>,
}

/// Paired ± line counts for one changed file. See `ChangedFile::line_stats`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LineStats {
    pub insertions: u32,
    pub deletions: u32,
}

/// A commit author. Plural authors on a `Commit` come from
/// `Co-authored-by:` trailers parsed out of the full message in the changeset detail.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Author {
    pub name: String,
    pub email: String,
}

/// Whether a commit has reached the remote. `Unknown` is NOT "no": it means there was nothing to
/// compare against (no `origin` remote / no tracked origin branches) or the reachability read failed,
/// so the UI must render nothing rather than guess. `Pushed` means "reachable from a tip of the
/// project's `origin`" — computed from LOCAL remote-tracking state, so it reflects whatever your last
/// fetch or push wrote, never the server's live state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PushState {
    Pushed,
    Unpushed,
    Unknown,
}

/// What `PushState` was measured against, so the UI can name it in a tooltip. `ref_name` is set only
/// when `origin` has exactly one branch (then the tooltip can say "not on origin/main");
/// otherwise `count` drives "not on any of origin's N branches". `count` is 0 when there was nothing
/// to compare against — the `PushState::Unknown` case.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushScope {
    pub ref_name: Option<String>,
    pub count: u32,
}

/// One row in the history log. `commit_id` is the stable identity used for dedupe + diffing.
/// Timestamp is split into epoch millis + tz offset so the UI can render in the commit's own zone or
/// local, its choice.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Commit {
    pub commit_id: String,
    pub short_id: String,
    // ponytail: change_id, is_working_copy, is_root, change_offset and divergent_siblings are
    // jj-era fields git always leaves empty. They stay on the wire because older apps decode them
    // non-optionally (`AgentCommit`) and a host's agent can be newer than the app talking to it;
    // prune once a protocol gate or stable hand-off covers that skew (TODOS.md).
    pub change_id: Option<String>,
    pub summary: String,
    /// The commit message below the summary line (the "description" body), trimmed. Empty when the
    /// message is a single line.
    pub body: String,
    pub authors: Vec<Author>,
    pub timestamp_ms: i64,
    pub tz_offset_secs: i32,
    /// Git ref decorations.
    pub refs: Vec<String>,
    pub parent_ids: Vec<String>,
    pub is_working_copy: bool,
    pub is_root: bool,
    pub change_offset: Option<u32>,
    pub divergent_siblings: Vec<Commit>,
    /// Whether this commit is on the project's `origin`. See `PushState` — `Unknown` renders nothing.
    pub push_state: PushState,
}

/// A page of history. `reached_end` is true when the backend yielded fewer than the requested count.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryPage {
    pub commits: Vec<Commit>,
    pub reached_end: bool,
    /// What the page's `push_state`s were measured against (tooltip copy). `None` ⇒ nothing to compare.
    pub push_scope: Option<PushScope>,
}

/// The kind of a repo's current ref (the sidebar root-row label). `Detached` is HEAD on a raw commit,
/// no branch. `Ancestor` is never produced since jj support was removed; it stays for the app's
/// decoder (see the `Commit` fields note).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RefKind {
    Branch,
    Ancestor,
    Detached,
    None,
}

/// A repo's current ref: the current branch (or a short SHA when detached). `name` is `None` only for `RefKind::None`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ref {
    pub name: Option<String>,
    pub kind: RefKind,
}

/// A full changeset: its commit metadata, full (multi-line) message, and changed-file list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Changeset {
    pub commit: Commit,
    pub full_message: String,
    pub files: Vec<ChangedFile>,
    /// >1 parent ⇒ a merge; the diff basis is the first parent (documented in the UI).
    pub is_merge: bool,
    /// What `commit.push_state` was measured against (tooltip copy). `None` ⇒ nothing to compare.
    pub push_scope: Option<PushScope>,
}

/// The typed error surface. Each variant maps to a distinct, recoverable UI state on the Swift side
/// (inline message + retry) — never a silent empty list.
#[derive(Debug, Clone, thiserror::Error, Serialize, Deserialize)]
pub enum VcsError {
    #[error("unsupported repository: {0}")]
    UnsupportedRepo(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("working-copy lock contention")]
    LockContention,
    #[error("stale snapshot")]
    StaleSnapshot,
    #[error("partial data: {0}")]
    PartialData(String),
    #[error("unsupported backend version: {0}")]
    BackendVersion(String),
    #[error("io error: {0}")]
    Io(String),
}

pub type Result<T> = std::result::Result<T, VcsError>;
