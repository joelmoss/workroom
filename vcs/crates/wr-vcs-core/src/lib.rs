//! Workroom VCS core: structured jj reads over `jj-lib`.
//!
//! **jj-only by design.** git is handled app-side in Swift via SwiftGitX (libgit2) — git has a
//! mature native Swift path, jj does not, so only jj needs the Rust/UniFFI bridge. `jj-lib` is
//! isolated to [`jj_backend`]; everything else stays backend-agnostic.

use std::path::Path;
use wr_vcs_model::RepoKind;

pub mod jj_backend;

pub use wr_vcs_model as model;

/// Classify a path (git / colocated-jj / unsupported). Pure filesystem inspection — no jj-lib call,
/// so it can't take the jj working-copy lock. The Swift side does its own routing (jj → this Rust
/// core, plain git → the SwiftGitX provider); this is exposed for diagnostics/parity.
pub fn probe_repo(root: &Path) -> RepoKind {
    let has_jj = root.join(".jj").is_dir();
    let has_git = root.join(".git").exists();
    match (has_jj, has_git) {
        (true, true) => RepoKind::JjColocated,
        (true, false) => RepoKind::JjNonColocated,
        (false, true) => RepoKind::PlainGit,
        (false, false) => {
            RepoKind::Unsupported(format!("no .jj or .git found at {}", root.display()))
        }
    }
}

/// A bounded, newest-first page of jj history.
pub fn log_page(root: &Path, limit: usize) -> model::Result<model::HistoryPage> {
    jj_backend::log_page(root, limit)
}

/// A single jj changeset's metadata (+ full message; files land in Phase 1).
pub fn changeset(root: &Path, commit_id_hex: &str) -> model::Result<model::Changeset> {
    jj_backend::changeset(root, commit_id_hex)
}

/// The repo's current ref (the `@` bookmark, nearest ancestor bookmark, or none) for the sidebar
/// root-row label. Read-only; no working-copy snapshot/lock.
pub fn current_ref(root: &Path) -> model::Result<model::Ref> {
    jj_backend::current_ref(root)
}

/// The jj working-copy status (dirty flag + `@`'s change set). MUTATING: snapshots `@` first (takes
/// the working-copy lock, rewrites `@` when disk changed) — jj's own per-command behavior.
pub fn working_status(root: &Path) -> model::Result<model::WorkingStatus> {
    jj_backend::working_status(root)
}
