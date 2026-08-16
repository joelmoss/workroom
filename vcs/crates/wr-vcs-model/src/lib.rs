//! Domain types for Workroom's VCS reads — the durable core.
//!
//! These are `jj-lib`-free on purpose: both the jj and git backends in `wr-vcs-core` produce these
//! same shapes, and a cross-backend conformance suite asserts they agree. The SwiftUI app maps
//! these (via UniFFI) into its own Swift models rather than binding the UI to this ABI directly.

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
    /// `None` means "deliberately not counted", never a zero-valued `LineStats`: a binary file (jj's
    /// own NUL heuristic), a file over the backend's size ceiling, or a non-file entry
    /// (symlink/tree/submodule/unreadable). A conflicted file counts its MATERIALIZED marker text,
    /// matching what `jj diff --stat` and a git worktree diff both report for the same state.
    ///
    /// One `Option`, not two independently-nullable fields: the sole producer (`changed_files` in
    /// wr-vcs-core) always counts both sides together or neither, so "counted" vs "deliberately not
    /// counted" is one decision, not two that merely happen to always agree.
    pub line_stats: Option<LineStats>,
}

/// Paired ± line counts for one changed file. See `ChangedFile::line_stats`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LineStats {
    pub insertions: u32,
    pub deletions: u32,
}

/// A commit author (git) or the author of a jj change. Plural authors on a `Commit` come from
/// `Co-authored-by:` trailers parsed out of the full message in the changeset detail.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Author {
    pub name: String,
    pub email: String,
}

/// Whether a commit has reached the remote. `Unknown` is NOT "no": it means there was nothing to
/// compare against (no `origin` remote / no tracked origin bookmarks) or the reachability read failed,
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
/// when `origin` has exactly one bookmark/branch (then the tooltip can say "not on origin/main");
/// otherwise `count` drives "not on any of origin's N branches". `count` is 0 when there was nothing
/// to compare against — the `PushState::Unknown` case.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushScope {
    pub ref_name: Option<String>,
    pub count: u32,
}

/// One row in the history log. `commit_id` is the stable identity used for dedupe + diffing;
/// `change_id` is jj-only (display). Timestamp is split into epoch millis + tz offset so the UI can
/// render in the commit's own zone or local, its choice.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Commit {
    pub commit_id: String,
    pub short_id: String,
    pub change_id: Option<String>,
    pub summary: String,
    /// The commit message below the summary line (the "description" body), trimmed. Empty when the
    /// message is a single line.
    pub body: String,
    pub authors: Vec<Author>,
    pub timestamp_ms: i64,
    pub tz_offset_secs: i32,
    /// jj bookmarks + git ref decorations.
    pub refs: Vec<String>,
    pub parent_ids: Vec<String>,
    /// jj working copy (`@`).
    pub is_working_copy: bool,
    /// jj-only: the repo's virtual **root commit** — the all-zero-id, author-less, message-less,
    /// epoch-timestamped commit every jj history terminates in (`◆ root() 00000000` in `jj log`).
    /// It sits on `::@` like any ancestor, so the log page carries it; the flag is what lets the UI
    /// render it as `root()` instead of a commit with no author, no description and a 1970 date.
    /// Always false for git — a git repo's first commit is a real commit.
    pub is_root: bool,
    /// jj-only: this commit's offset among all commits sharing its change-id (the `/N` jj appends,
    /// e.g. the `0` in `xl/0`) — hidden commits count, so it can be non-contiguous. `None` unless the
    /// change-id is divergent. Set on both a divergent commit and each of its `divergent_siblings`.
    pub change_offset: Option<u32>,
    /// jj-only: the OTHER visible commits sharing this commit's change-id — the divergent copies.
    /// Empty unless this commit's change-id is divergent (resolves to more than one visible commit).
    /// The history walk only follows `::@`, so these siblings live off that line and would otherwise
    /// be invisible; surfacing them here is what lets the History pane reveal a change's divergence.
    /// Never nested (a sibling's own `divergent_siblings` is always empty).
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

/// The kind of a repo's current ref (the sidebar root-row label). `Ancestor` is jj-only (the nearest
/// bookmark above a bookmark-less `@`); `Detached` is git-only (HEAD on a raw commit, no branch).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RefKind {
    Branch,
    Ancestor,
    Detached,
    None,
}

/// A repo's current ref: jj's `@` bookmark (or nearest ancestor bookmark), or git's current branch
/// (or a short SHA when detached). `name` is `None` only for `RefKind::None`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ref {
    pub name: Option<String>,
    pub kind: RefKind,
}

/// A commit's change set for a jj disclosure group: its identity/description header + changed files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommitChanges {
    /// Change-id (jj display), shortest-8 commit-id, bookmarks, and first-line description.
    pub change_id: Option<String>,
    pub commit_id: Option<String>,
    pub refs: Vec<String>,
    pub description: Option<String>,
    /// Changed files vs the commit's first parent.
    pub files: Vec<ChangedFile>,
}

/// The jj working-copy status for the sidebar/Changes badges. Reading it first SNAPSHOTS the working
/// copy so `@` reflects on-disk edits (jj's own behavior on every command).
///
/// The diffstat lives PER FILE on each `ChangedFile`, and there is deliberately no aggregate field:
/// a total stored beside the rows is a second representation that can disagree with them, which is
/// exactly the bug this replaced (the app used to add the totals from a separate `jj diff --stat`
/// process, so a merge `@` stated them against a different base than the file list, and an edit
/// between the two reads skewed them). Callers sum the rows they display.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkingStatus {
    pub conflicted: bool,
    /// The working copy `@`'s change set (metadata + files vs `@-`).
    pub working_copy: CommitChanges,
    /// The bookmark to look a CI run / PR up by, since jj's `@` is a detached git HEAD. `None` ⇒ no
    /// bookmark in `@`'s ancestry at all.
    ///
    /// Specifically the FIRST bookmark in `::@` log order — the same one the sidebar labels the
    /// workroom with, so the two can't disagree. Not the graph-nearest one: past a merge, log order
    /// can reach a bookmark down the second parent before one sitting on `@`'s own first parent (the
    /// backend's `first_bookmark_in_log_order` documents the case). Treat it as a label, not as
    /// "the branch this commit will land on".
    pub branch_for_ci: Option<String>,
}

impl WorkingStatus {
    /// `true` when `@` has changed files or a conflict. Computed rather than stored: a stored
    /// `dirty` beside `working_copy.files`/`conflicted` is a second representation that can
    /// disagree with them — exactly the class of bug this struct's own diffstat design (see its
    /// doc comment) already guards against elsewhere.
    pub fn is_dirty(&self) -> bool {
        !self.working_copy.files.is_empty() || self.conflicted
    }
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

/// The kind of a single diff line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DiffLineKind {
    Context,
    Added,
    Removed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    pub old_lineno: Option<u32>,
    pub new_lineno: Option<u32>,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffHunk {
    pub old_start: u32,
    pub old_len: u32,
    pub new_start: u32,
    pub new_len: u32,
    pub lines: Vec<DiffLine>,
}

/// The structured diff of one file at a changeset. The Swift side maps these hunks into the existing
/// `UnifiedDiff`/`DiffViewer` renderer (plan: core produces hunks, Swift keeps rendering).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDiff {
    pub path: String,
    pub kind: ChangeKind,
    pub is_binary: bool,
    pub hunks: Vec<DiffHunk>,
}

/// What kind of repository a path is — the backend-selection discriminant. Colocated jj+git prefers
/// the jj backend (this repo is colocated). `Unsupported` carries a human reason and becomes a typed
/// error at the boundary rather than a silent empty result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RepoKind {
    PlainGit,
    JjColocated,
    JjNonColocated,
    Unsupported(String),
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
