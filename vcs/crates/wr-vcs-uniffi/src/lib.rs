//! UniFFI export surface — the Rust↔Swift boundary.
//!
//! These `U*` types mirror `wr-vcs-model` and are mapped at this boundary rather than deriving
//! UniFFI on the model directly. That keeps `wr-vcs-model` free of the FFI dependency and gives the
//! Swift side a stable seam to map into its own app-native models (plan: no raw FFI re-export).

use std::path::Path;

use wr_vcs_model as model;

uniffi::setup_scaffolding!();

#[derive(uniffi::Record)]
pub struct Author {
    pub name: String,
    pub email: String,
}

#[derive(uniffi::Record)]
pub struct Commit {
    pub commit_id: String,
    pub short_id: String,
    pub change_id: Option<String>,
    pub summary: String,
    pub authors: Vec<Author>,
    pub timestamp_ms: i64,
    pub tz_offset_secs: i32,
    pub refs: Vec<String>,
    pub parent_ids: Vec<String>,
    pub is_working_copy: bool,
}

#[derive(uniffi::Record)]
pub struct HistoryPage {
    pub commits: Vec<Commit>,
    pub reached_end: bool,
}

/// Mirrors `model::VcsError`; each variant maps to a distinct, recoverable Swift-side UI state.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum VcsError {
    #[error("unsupported repository: {reason}")]
    UnsupportedRepo { reason: String },
    #[error("not found: {what}")]
    NotFound { what: String },
    #[error("working-copy lock contention")]
    LockContention,
    #[error("stale snapshot")]
    StaleSnapshot,
    #[error("partial data: {detail}")]
    PartialData { detail: String },
    #[error("unsupported backend version: {detail}")]
    BackendVersion { detail: String },
    #[error("io error: {message}")]
    Io { message: String },
}

impl From<model::Author> for Author {
    fn from(a: model::Author) -> Self {
        Author { name: a.name, email: a.email }
    }
}

impl From<model::Commit> for Commit {
    fn from(c: model::Commit) -> Self {
        Commit {
            commit_id: c.commit_id,
            short_id: c.short_id,
            change_id: c.change_id,
            summary: c.summary,
            authors: c.authors.into_iter().map(Author::from).collect(),
            timestamp_ms: c.timestamp_ms,
            tz_offset_secs: c.tz_offset_secs,
            refs: c.refs,
            parent_ids: c.parent_ids,
            is_working_copy: c.is_working_copy,
        }
    }
}

impl From<model::HistoryPage> for HistoryPage {
    fn from(p: model::HistoryPage) -> Self {
        HistoryPage {
            commits: p.commits.into_iter().map(Commit::from).collect(),
            reached_end: p.reached_end,
        }
    }
}

impl From<model::VcsError> for VcsError {
    fn from(e: model::VcsError) -> Self {
        use model::VcsError as M;
        match e {
            M::UnsupportedRepo(reason) => VcsError::UnsupportedRepo { reason },
            M::NotFound(what) => VcsError::NotFound { what },
            M::LockContention => VcsError::LockContention,
            M::StaleSnapshot => VcsError::StaleSnapshot,
            M::PartialData(detail) => VcsError::PartialData { detail },
            M::BackendVersion(detail) => VcsError::BackendVersion { detail },
            M::Io(message) => VcsError::Io { message },
        }
    }
}

/// Classify a repository path (git / colocated-jj / unsupported) — debug string for now.
#[uniffi::export]
pub fn probe_repo(root: String) -> String {
    format!("{:?}", wr_vcs_core::probe_repo(Path::new(&root)))
}

/// A bounded, newest-first page of history for the repo rooted at `root`.
#[uniffi::export]
pub fn log_page(root: String, limit: u32) -> Result<HistoryPage, VcsError> {
    wr_vcs_core::log_page(Path::new(&root), limit as usize)
        .map(HistoryPage::from)
        .map_err(VcsError::from)
}
