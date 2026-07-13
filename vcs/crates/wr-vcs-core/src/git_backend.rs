//! git backend — structured reads via `gix` (gitoxide). Isolated here alongside the jj backend.
//!
//! Phase 0 stub. The real work (task 3, after jj): log page, changeset, per-file diff via gix
//! revwalk + tree diff with rename detection.

// Reference the crate so the dependency is linked while the real API usage is still stubbed.
use gix as _;
