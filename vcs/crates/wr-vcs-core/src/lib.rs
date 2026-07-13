//! Workroom VCS core: app-facing structured reads over git (gix) and jj (jj-lib).
//!
//! This is the only crate that depends on `jj-lib` (isolated to [`jj_backend`]) and `gix`
//! ([`git_backend`]). Everything else in the workspace stays backend-agnostic.
//!
//! Phase 0: the module layout + a pure repo-identity probe. The real jj-lib/gix reads (log page,
//! changeset, per-file diff) land once the dependency tree is proven to compile (task 2 → task 3).

use std::path::Path;
use wr_vcs_model::{RepoKind, VcsError};

pub mod git_backend;
pub mod jj_backend;

pub use wr_vcs_model as model;

/// A bounded, newest-first page of the repo's history, dispatched to the right backend.
pub fn log_page(root: &Path, limit: usize) -> model::Result<model::HistoryPage> {
    match probe_repo(root) {
        RepoKind::JjColocated | RepoKind::JjNonColocated => jj_backend::log_page(root, limit),
        RepoKind::PlainGit => Err(VcsError::Io("git backend not yet implemented".into())),
        RepoKind::Unsupported(reason) => Err(VcsError::UnsupportedRepo(reason)),
    }
}

/// A single changeset's metadata (+ full message; files land in Phase 1), dispatched by backend.
pub fn changeset(root: &Path, commit_id_hex: &str) -> model::Result<model::Changeset> {
    match probe_repo(root) {
        RepoKind::JjColocated | RepoKind::JjNonColocated => {
            jj_backend::changeset(root, commit_id_hex)
        }
        RepoKind::PlainGit => Err(VcsError::Io("git backend not yet implemented".into())),
        RepoKind::Unsupported(reason) => Err(VcsError::UnsupportedRepo(reason)),
    }
}

/// Classify a path into the backend-selection discriminant. Pure filesystem inspection — no jj-lib
/// or gix calls — so it's cheap and can't take the jj working-copy lock.
///
/// Colocated jj+git (a `.jj` *and* a `.git` under the same root) prefers the jj backend, matching
/// how this very repo is set up.
pub fn probe_repo(root: &Path) -> RepoKind {
    let has_jj = root.join(".jj").is_dir();
    let has_git = root.join(".git").exists(); // dir (normal) or file (worktree/submodule)
    match (has_jj, has_git) {
        (true, true) => RepoKind::JjColocated,
        (true, false) => RepoKind::JjNonColocated,
        (false, true) => RepoKind::PlainGit,
        (false, false) => RepoKind::Unsupported(format!(
            "no .jj or .git found at {}",
            root.display()
        )),
    }
}
