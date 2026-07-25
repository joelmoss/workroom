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

/// Mirrors `model::PushState`. `Unknown` = nothing to compare against (no `origin`) or the read
/// failed — the UI renders nothing for it, never a badge.
#[derive(uniffi::Enum)]
pub enum PushState {
    Pushed,
    Unpushed,
    Unknown,
}

/// Mirrors `model::PushScope` — what push state was measured against, for tooltip copy.
#[derive(uniffi::Record)]
pub struct PushScope {
    pub ref_name: Option<String>,
    pub count: u32,
}

#[derive(uniffi::Record)]
pub struct Commit {
    pub commit_id: String,
    pub short_id: String,
    pub change_id: Option<String>,
    pub summary: String,
    pub body: String,
    pub authors: Vec<Author>,
    pub timestamp_ms: i64,
    pub tz_offset_secs: i32,
    pub refs: Vec<String>,
    pub parent_ids: Vec<String>,
    pub is_working_copy: bool,
    /// jj-only: this commit's `/N` offset within its divergent set. `None` unless divergent.
    pub change_offset: Option<u32>,
    /// jj-only: the other visible commits sharing this change-id (the divergent copies). Empty
    /// unless divergent; never nested.
    pub divergent_siblings: Vec<Commit>,
    /// Whether this commit is on the project's `origin`.
    pub push_state: PushState,
}

#[derive(uniffi::Record)]
pub struct HistoryPage {
    pub commits: Vec<Commit>,
    pub reached_end: bool,
    pub push_scope: Option<PushScope>,
}

#[derive(uniffi::Enum)]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    Conflicted,
    Other,
}

#[derive(uniffi::Record)]
pub struct ChangedFile {
    pub path: String,
    pub old_path: Option<String>,
    pub kind: ChangeKind,
}

#[derive(uniffi::Record)]
pub struct Changeset {
    pub commit: Commit,
    pub full_message: String,
    pub files: Vec<ChangedFile>,
    pub is_merge: bool,
    pub push_scope: Option<PushScope>,
}

#[derive(uniffi::Enum)]
pub enum RefKind {
    Branch,
    Ancestor,
    Detached,
    None,
}

#[derive(uniffi::Record)]
pub struct Ref {
    pub name: Option<String>,
    pub kind: RefKind,
}

#[derive(uniffi::Record)]
pub struct CommitChanges {
    pub change_id: Option<String>,
    pub commit_id: Option<String>,
    pub refs: Vec<String>,
    pub description: Option<String>,
    pub files: Vec<ChangedFile>,
}

#[derive(uniffi::Record)]
pub struct WorkingStatus {
    pub dirty: bool,
    pub conflicted: bool,
    pub working_copy: CommitChanges,
    pub branch_for_ci: Option<String>,
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
        Author {
            name: a.name,
            email: a.email,
        }
    }
}

impl From<model::PushState> for PushState {
    fn from(s: model::PushState) -> Self {
        use model::PushState as M;
        match s {
            M::Pushed => PushState::Pushed,
            M::Unpushed => PushState::Unpushed,
            M::Unknown => PushState::Unknown,
        }
    }
}

impl From<model::PushScope> for PushScope {
    fn from(s: model::PushScope) -> Self {
        PushScope {
            ref_name: s.ref_name,
            count: s.count,
        }
    }
}

impl From<model::Commit> for Commit {
    fn from(c: model::Commit) -> Self {
        Commit {
            commit_id: c.commit_id,
            short_id: c.short_id,
            change_id: c.change_id,
            summary: c.summary,
            body: c.body,
            authors: c.authors.into_iter().map(Author::from).collect(),
            timestamp_ms: c.timestamp_ms,
            tz_offset_secs: c.tz_offset_secs,
            refs: c.refs,
            parent_ids: c.parent_ids,
            is_working_copy: c.is_working_copy,
            change_offset: c.change_offset,
            divergent_siblings: c.divergent_siblings.into_iter().map(Commit::from).collect(),
            push_state: c.push_state.into(),
        }
    }
}

impl From<model::HistoryPage> for HistoryPage {
    fn from(p: model::HistoryPage) -> Self {
        HistoryPage {
            commits: p.commits.into_iter().map(Commit::from).collect(),
            reached_end: p.reached_end,
            push_scope: p.push_scope.map(PushScope::from),
        }
    }
}

impl From<model::ChangeKind> for ChangeKind {
    fn from(k: model::ChangeKind) -> Self {
        use model::ChangeKind as M;
        match k {
            M::Added => ChangeKind::Added,
            M::Modified => ChangeKind::Modified,
            M::Deleted => ChangeKind::Deleted,
            M::Renamed => ChangeKind::Renamed,
            M::Copied => ChangeKind::Copied,
            M::Conflicted => ChangeKind::Conflicted,
            M::Other => ChangeKind::Other,
        }
    }
}

impl From<model::ChangedFile> for ChangedFile {
    fn from(f: model::ChangedFile) -> Self {
        ChangedFile {
            path: f.path,
            old_path: f.old_path,
            kind: f.kind.into(),
        }
    }
}

impl From<model::Changeset> for Changeset {
    fn from(c: model::Changeset) -> Self {
        Changeset {
            commit: c.commit.into(),
            full_message: c.full_message,
            files: c.files.into_iter().map(ChangedFile::from).collect(),
            is_merge: c.is_merge,
            push_scope: c.push_scope.map(PushScope::from),
        }
    }
}

impl From<model::RefKind> for RefKind {
    fn from(k: model::RefKind) -> Self {
        use model::RefKind as M;
        match k {
            M::Branch => RefKind::Branch,
            M::Ancestor => RefKind::Ancestor,
            M::Detached => RefKind::Detached,
            M::None => RefKind::None,
        }
    }
}

impl From<model::Ref> for Ref {
    fn from(r: model::Ref) -> Self {
        Ref {
            name: r.name,
            kind: r.kind.into(),
        }
    }
}

impl From<model::CommitChanges> for CommitChanges {
    fn from(c: model::CommitChanges) -> Self {
        CommitChanges {
            change_id: c.change_id,
            commit_id: c.commit_id,
            refs: c.refs,
            description: c.description,
            files: c.files.into_iter().map(ChangedFile::from).collect(),
        }
    }
}

impl From<model::WorkingStatus> for WorkingStatus {
    fn from(s: model::WorkingStatus) -> Self {
        WorkingStatus {
            dirty: s.dirty,
            conflicted: s.conflicted,
            working_copy: s.working_copy.into(),
            branch_for_ci: s.branch_for_ci,
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

/// A single jj changeset: metadata + full message + changed-file list.
#[uniffi::export]
pub fn changeset(root: String, commit_id: String) -> Result<Changeset, VcsError> {
    wr_vcs_core::changeset(Path::new(&root), &commit_id)
        .map(Changeset::from)
        .map_err(VcsError::from)
}

/// The repo's current ref (the `@` bookmark / nearest ancestor bookmark / none) for the sidebar
/// root-row label.
#[uniffi::export]
pub fn current_ref(root: String) -> Result<Ref, VcsError> {
    wr_vcs_core::current_ref(Path::new(&root))
        .map(Ref::from)
        .map_err(VcsError::from)
}

/// The jj working-copy status (dirty + `@`/`@-` change sets + CI branch). MUTATING: snapshots `@`
/// first (takes the working-copy lock, rewrites `@` when disk changed).
#[uniffi::export]
pub fn working_status(root: String) -> Result<WorkingStatus, VcsError> {
    wr_vcs_core::working_status(Path::new(&root))
        .map(WorkingStatus::from)
        .map_err(VcsError::from)
}
