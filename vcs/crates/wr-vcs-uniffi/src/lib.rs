//! UniFFI export surface — the Rust↔Swift boundary.
//!
//! Phase 0 stub: references the deps so the dependency tree (incl. `uniffi`) compiles. The real
//! `#[uniffi::export]` API + `setup_scaffolding!` land in task 4, exposing `wr-vcs-core`'s reads to
//! Swift. The app maps these generated types into its own Swift models (no direct FFI coupling).

use uniffi as _;

/// Temporary smoke symbol so Phase-0 wiring (call-a-Rust-fn-from-Workroom-Dev) has a target before
/// the real export surface exists. Replaced in task 4.
pub fn workroom_vcs_probe(root: &str) -> String {
    format!("{:?}", wr_vcs_core::probe_repo(std::path::Path::new(root)))
}
