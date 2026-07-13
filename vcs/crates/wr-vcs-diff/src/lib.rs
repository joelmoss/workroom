//! jj-lib-free diff engine: turns old/new file content into `wr-vcs-model` hunks.
//!
//! Phase 0 stub — the real histogram line diff + word-diff lands in Phase 1 (and we evaluate reusing
//! jayjay's Apache-2.0 `jj-diff` crate as the producer). Kept as its own crate so the diff logic
//! never pulls in `jj-lib`.

use wr_vcs_model::FileDiff;

/// Placeholder for the Phase-1 diff computation. Signature is intentionally minimal until the
/// producer choice (own vs jayjay `jj-diff`) is made.
pub fn empty_file_diff(path: impl Into<String>, kind: wr_vcs_model::ChangeKind) -> FileDiff {
    FileDiff {
        path: path.into(),
        kind,
        is_binary: false,
        hunks: Vec::new(),
    }
}
