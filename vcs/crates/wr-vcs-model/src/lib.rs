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
}

/// A commit author (git) or the author of a jj change. Plural authors on a `Commit` come from
/// `Co-authored-by:` trailers parsed out of the full message in the changeset detail.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Author {
    pub name: String,
    pub email: String,
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
    pub authors: Vec<Author>,
    pub timestamp_ms: i64,
    pub tz_offset_secs: i32,
    /// jj bookmarks + git ref decorations.
    pub refs: Vec<String>,
    pub parent_ids: Vec<String>,
    /// jj working copy (`@`).
    pub is_working_copy: bool,
}

/// A page of history. `reached_end` is true when the backend yielded fewer than the requested count.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryPage {
    pub commits: Vec<Commit>,
    pub reached_end: bool,
}

/// A full changeset: its commit metadata, full (multi-line) message, and changed-file list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Changeset {
    pub commit: Commit,
    pub full_message: String,
    pub files: Vec<ChangedFile>,
    /// >1 parent ⇒ a merge; the diff basis is the first parent (documented in the UI).
    pub is_merge: bool,
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
