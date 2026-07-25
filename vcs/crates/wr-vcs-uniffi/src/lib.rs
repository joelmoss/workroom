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
    /// Changed lines vs the same (first-parent) base as `kind`. `None` = not counted (binary,
    /// oversized, or a non-file entry) — never zero. See `model::ChangedFile`.
    pub insertions: Option<u32>,
    pub deletions: Option<u32>,
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
            insertions: f.insertions,
            deletions: f.deletions,
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

/// These cover the one hazard this file has: it is a hand-written mirror of `wr-vcs-model`, so every
/// variant is a copy-paste site where an arm can silently point at the wrong case or drop a payload.
/// Nothing here type-checks that `M::Renamed` maps to `Renamed` rather than `Copied` — a test has to.
///
/// The `name_of` helpers are exhaustive matches on BOTH sides, so adding a variant to either enum
/// breaks compilation here and forces this file to be revisited.
#[cfg(test)]
mod tests {
    use super::*;

    fn change_kind_name(k: &ChangeKind) -> &'static str {
        match k {
            ChangeKind::Added => "Added",
            ChangeKind::Modified => "Modified",
            ChangeKind::Deleted => "Deleted",
            ChangeKind::Renamed => "Renamed",
            ChangeKind::Copied => "Copied",
            ChangeKind::Conflicted => "Conflicted",
            ChangeKind::Other => "Other",
        }
    }

    fn model_change_kind_name(k: &model::ChangeKind) -> &'static str {
        match k {
            model::ChangeKind::Added => "Added",
            model::ChangeKind::Modified => "Modified",
            model::ChangeKind::Deleted => "Deleted",
            model::ChangeKind::Renamed => "Renamed",
            model::ChangeKind::Copied => "Copied",
            model::ChangeKind::Conflicted => "Conflicted",
            model::ChangeKind::Other => "Other",
        }
    }

    #[test]
    fn change_kind_maps_every_variant_to_its_namesake() {
        let all = [
            model::ChangeKind::Added,
            model::ChangeKind::Modified,
            model::ChangeKind::Deleted,
            model::ChangeKind::Renamed,
            model::ChangeKind::Copied,
            model::ChangeKind::Conflicted,
            model::ChangeKind::Other,
        ];
        for kind in all {
            let want = model_change_kind_name(&kind);
            let got = change_kind_name(&ChangeKind::from(kind));
            assert_eq!(got, want, "model::ChangeKind::{want} mapped to {got}");
        }
    }

    fn push_state_name(s: &PushState) -> &'static str {
        match s {
            PushState::Pushed => "Pushed",
            PushState::Unpushed => "Unpushed",
            PushState::Unknown => "Unknown",
        }
    }

    fn model_push_state_name(s: &model::PushState) -> &'static str {
        match s {
            model::PushState::Pushed => "Pushed",
            model::PushState::Unpushed => "Unpushed",
            model::PushState::Unknown => "Unknown",
        }
    }

    /// `Pushed` and `Unpushed` are one arm apart and drive an inverted UI decision — a swap here shows
    /// the unpushed badge on exactly the commits that ARE pushed, and hides it on the ones that aren't.
    #[test]
    fn push_state_maps_every_variant_to_its_namesake() {
        let all = [
            model::PushState::Pushed,
            model::PushState::Unpushed,
            model::PushState::Unknown,
        ];
        for state in all {
            let want = model_push_state_name(&state);
            let got = push_state_name(&PushState::from(state));
            assert_eq!(got, want, "model::PushState::{want} mapped to {got}");
        }
    }

    fn ref_kind_name(k: &RefKind) -> &'static str {
        match k {
            RefKind::Branch => "Branch",
            RefKind::Ancestor => "Ancestor",
            RefKind::Detached => "Detached",
            RefKind::None => "None",
        }
    }

    fn model_ref_kind_name(k: &model::RefKind) -> &'static str {
        match k {
            model::RefKind::Branch => "Branch",
            model::RefKind::Ancestor => "Ancestor",
            model::RefKind::Detached => "Detached",
            model::RefKind::None => "None",
        }
    }

    #[test]
    fn ref_kind_maps_every_variant_to_its_namesake() {
        let all = [
            model::RefKind::Branch,
            model::RefKind::Ancestor,
            model::RefKind::Detached,
            model::RefKind::None,
        ];
        for kind in all {
            let want = model_ref_kind_name(&kind);
            let got = ref_kind_name(&RefKind::from(kind));
            assert_eq!(got, want, "model::RefKind::{want} mapped to {got}");
        }
    }

    /// Errors carry the payload the Swift side shows in its inline recovery UI, so this asserts the
    /// variant AND that the message survives — a mapping that lands on the right case but drops the
    /// detail is the same class of bug as flattening every error to `Io`.
    #[test]
    fn vcs_error_maps_every_variant_and_keeps_its_payload() {
        let cases = [
            (
                model::VcsError::UnsupportedRepo("why".into()),
                "UnsupportedRepo",
                Some("why"),
            ),
            (
                model::VcsError::NotFound("what".into()),
                "NotFound",
                Some("what"),
            ),
            (model::VcsError::LockContention, "LockContention", None),
            (model::VcsError::StaleSnapshot, "StaleSnapshot", None),
            (
                model::VcsError::PartialData("detail".into()),
                "PartialData",
                Some("detail"),
            ),
            (
                model::VcsError::BackendVersion("ver".into()),
                "BackendVersion",
                Some("ver"),
            ),
            (model::VcsError::Io("boom".into()), "Io", Some("boom")),
        ];
        for (err, want_variant, want_payload) in cases {
            let mapped = VcsError::from(err);
            let (variant, payload) = match &mapped {
                VcsError::UnsupportedRepo { reason } => ("UnsupportedRepo", Some(reason.as_str())),
                VcsError::NotFound { what } => ("NotFound", Some(what.as_str())),
                VcsError::LockContention => ("LockContention", None),
                VcsError::StaleSnapshot => ("StaleSnapshot", None),
                VcsError::PartialData { detail } => ("PartialData", Some(detail.as_str())),
                VcsError::BackendVersion { detail } => ("BackendVersion", Some(detail.as_str())),
                VcsError::Io { message } => ("Io", Some(message.as_str())),
            };
            assert_eq!(variant, want_variant, "{want_variant} mapped to {variant}");
            assert_eq!(payload, want_payload, "{want_variant} lost its payload");
        }
    }

    /// The nested mappings: a `ChangedFile`'s kind must go through the enum mapping above (not be
    /// defaulted), and a `Commit`'s divergent siblings must survive the recursive `From`.
    #[test]
    fn nested_records_map_through_their_children() {
        let file = ChangedFile::from(model::ChangedFile {
            path: "a/b.txt".into(),
            old_path: Some("a/old.txt".into()),
            kind: model::ChangeKind::Conflicted,
            insertions: Some(3),
            deletions: None,
        });
        assert_eq!(file.path, "a/b.txt");
        assert_eq!(file.old_path.as_deref(), Some("a/old.txt"));
        assert_eq!(change_kind_name(&file.kind), "Conflicted");
        // The counts are `Option`s carrying a real distinction (`None` = not counted, not zero), so
        // the mapping has to preserve BOTH shapes, not default them.
        assert_eq!(file.insertions, Some(3));
        assert_eq!(file.deletions, None);

        let bare = |id: &str| model::Commit {
            commit_id: id.into(),
            short_id: id.into(),
            change_id: None,
            summary: String::new(),
            body: String::new(),
            authors: Vec::new(),
            timestamp_ms: 0,
            tz_offset_secs: 0,
            refs: Vec::new(),
            parent_ids: Vec::new(),
            is_working_copy: false,
            change_offset: None,
            divergent_siblings: Vec::new(),
            push_state: model::PushState::Unpushed,
        };
        let sibling = model::Commit {
            change_offset: Some(1),
            ..bare("sib")
        };
        let commit = Commit::from(model::Commit {
            authors: vec![model::Author {
                name: "A".into(),
                email: "a@example.com".into(),
            }],
            divergent_siblings: vec![sibling],
            ..bare("root")
        });
        assert_eq!(commit.commit_id, "root");
        assert_eq!(commit.authors.len(), 1);
        assert_eq!(commit.authors[0].email, "a@example.com");
        assert_eq!(commit.divergent_siblings.len(), 1);
        assert_eq!(commit.divergent_siblings[0].commit_id, "sib");
        assert_eq!(commit.divergent_siblings[0].change_offset, Some(1));
        // Scalar-ish fields are easy to drop when a new one is added to the model; this is the one the
        // History badge reads, and it must survive on the nested siblings too, not just the root.
        assert_eq!(push_state_name(&commit.push_state), "Unpushed");
        assert_eq!(
            push_state_name(&commit.divergent_siblings[0].push_state),
            "Unpushed"
        );
    }
}
