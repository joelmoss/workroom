//! Workroom VCS core: structured jj reads over `jj-lib`.
//!
//! **jj-only by design.** git is handled app-side in Swift via SwiftGitX (libgit2) — git has a
//! mature native Swift path, jj does not, so only jj needs the Rust/UniFFI bridge. `jj-lib` is
//! isolated to [`jj_backend`]; everything else stays backend-agnostic.

use std::path::Path;
use wr_vcs_model::RepoKind;

pub mod jj_backend;
mod jj_config;

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

/// The repo's current ref (a bookmark on `@`, else the first ancestor bookmark in `::@` log order —
/// not necessarily the graph-nearest, see `jj_backend::first_bookmark_in_log_order` — else none) for
/// the sidebar root-row label. Read-only; no working-copy snapshot/lock.
pub fn current_ref(root: &Path) -> model::Result<model::Ref> {
    jj_backend::current_ref(root)
}

/// The jj working-copy status (dirty flag + `@`'s change set). MUTATING: snapshots `@` first (takes
/// the working-copy lock, rewrites `@` when disk changed) — jj's own per-command behavior.
pub fn working_status(root: &Path) -> model::Result<model::WorkingStatus> {
    jj_backend::working_status(root)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    /// A scratch directory named after the caller's line, matching the convention in
    /// `tests/working_status.rs` — no `tempfile` dev-dependency for a workspace that pins its deps
    /// exactly.
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wr-probe-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn probe_repo_classifies_a_plain_git_checkout() {
        let dir = scratch("git");
        std::fs::create_dir(dir.join(".git")).unwrap();
        assert_eq!(probe_repo(&dir), RepoKind::PlainGit);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The load-bearing case for THIS product: every workroom is a git worktree, and a worktree's
    /// `.git` is a FILE (`gitdir: …`) pointing back at the main repo, not a directory. That's why the
    /// git probe is `exists()` while the jj probe is `is_dir()` — swap it to `is_dir()` and every
    /// workroom classifies as `Unsupported`.
    #[test]
    fn probe_repo_classifies_a_git_worktree_whose_dot_git_is_a_file() {
        let dir = scratch("worktree");
        std::fs::write(dir.join(".git"), b"gitdir: /elsewhere/.git/worktrees/wt\n").unwrap();
        assert_eq!(probe_repo(&dir), RepoKind::PlainGit);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn probe_repo_classifies_colocated_and_standalone_jj() {
        let dir = scratch("colocated");
        std::fs::create_dir(dir.join(".jj")).unwrap();
        std::fs::create_dir(dir.join(".git")).unwrap();
        assert_eq!(probe_repo(&dir), RepoKind::JjColocated);
        let _ = std::fs::remove_dir_all(&dir);

        let dir = scratch("jj-only");
        std::fs::create_dir(dir.join(".jj")).unwrap();
        assert_eq!(probe_repo(&dir), RepoKind::JjNonColocated);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn probe_repo_rejects_a_directory_with_neither_and_names_the_path() {
        let dir = scratch("bare");
        match probe_repo(&dir) {
            RepoKind::Unsupported(reason) => assert!(
                reason.contains(&dir.display().to_string()),
                "the reason should name the path it looked at; got {reason:?}"
            ),
            other => panic!("expected Unsupported, got {other:?}"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A jj *workspace* always has `.jj` as a directory, so a stray `.jj` file is not one — the
    /// `is_dir()` check must not be loosened to `exists()` to match the git side.
    #[test]
    fn probe_repo_does_not_treat_a_dot_jj_file_as_a_jj_repo() {
        let dir = scratch("jj-file");
        std::fs::write(dir.join(".jj"), b"not a workspace\n").unwrap();
        assert!(matches!(probe_repo(&dir), RepoKind::Unsupported(_)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
