//! The daemon build identity (#680, ADR 0078): a hash of everything the daemon is built from
//! except the CLI's `commands` module, so a change to CLI commands alone is the same daemon and a
//! running one is not handed off for it. `build.rs` stamps it into the binary; `protocol` states it
//! as `daemon-build <hash>`, and a daemon offered a binary compares it with its own. So nothing a
//! daemon runs may be in that module: which arguments are the daemon's is `src/cli/route.rs`'s.
//!
//! Loaded by `build.rs` and by `tests/daemon_build.rs`, so it uses std alone: a build dependency
//! would itself be a change to `Cargo.lock`, and SHA-256 is short.
//!
//! Under-counting is the dangerous direction: a change the hash misses leaves the old daemon
//! running a host's sessions for good. So it reads every file in each crate of the workspace,
//! linked by the daemon or not, rather than a list someone must keep up. Left out are only what is
//! no part of any binary: each crate's `tests/`, and files an editor or Finder leaves (a name that
//! starts with `.` or `#`, or ends with `~`).

use std::path::{Path, PathBuf};

/// What a daemon build is: its hash, and the files and directories it read, for `build.rs` to name
/// to cargo (`rerun-if-changed`), which reruns it for nothing else.
pub struct DaemonBuild {
    /// SHA-256, 64 lowercase hex digits.
    pub hash: String,
    pub roots: Vec<PathBuf>,
}

/// The workspace-level files the daemon is built from, relative to `vcs/`. The Ghostty pin is a
/// script, but it decides the libghostty-vt a `terminal-state` daemon links.
const WORKSPACE_FILES: [&str; 3] = ["Cargo.toml", "Cargo.lock", "scripts/build-ghostty-vt.sh"];
/// The CLI's commands, relative to `vcs/`: what a change to alone hands nothing off.
const COMMANDS: &str = "crates/workroomd/src/commands";

/// The daemon build of the workspace at `workspace` (`vcs/`), built with `features`.
///
/// Deterministic across machines and checkouts: the files are taken in the order of their paths
/// relative to `workspace`, written with `/`, and each is framed by that path and its length, so
/// no absolute path, time or listing order reaches the hash, and moving bytes between files or a
/// file between paths changes it.
pub fn daemon_build(workspace: &Path, features: &[&str]) -> std::io::Result<DaemonBuild> {
    let mut roots = Vec::new();
    let mut files = Vec::new();
    for name in WORKSPACE_FILES {
        let path = workspace.join(name);
        files.push((name.to_string(), path.clone()));
        roots.push(path);
    }
    let mut crates = listing(&workspace.join("crates"))?;
    crates.retain(|(_, path)| path.is_dir());
    for (name, path) in crates {
        for (entry, path) in listing(&path)? {
            if entry == "tests" {
                continue;
            }
            collect(&format!("crates/{name}/{entry}"), &path, &mut files)?;
            roots.push(path);
        }
    }
    files.sort_by(|a, b| a.0.cmp(&b.0));

    let mut features: Vec<&str> = features.to_vec();
    features.sort_unstable();
    let mut input = Vec::new();
    input.extend_from_slice(b"features ");
    input.extend_from_slice(features.join(",").as_bytes());
    input.push(0);
    for (name, path) in files {
        let bytes = std::fs::read(&path)
            .map_err(|e| std::io::Error::new(e.kind(), format!("{}: {e}", path.display())))?;
        input.extend_from_slice(b"file ");
        input.extend_from_slice(name.as_bytes());
        input.push(0);
        input.extend_from_slice(bytes.len().to_string().as_bytes());
        input.push(0);
        input.extend_from_slice(&bytes);
    }
    let hash = sha256(&input).iter().map(|b| format!("{b:02x}")).collect();
    Ok(DaemonBuild { hash, roots })
}

/// A directory's entries, without what an editor or Finder leaves, as (name, path).
fn listing(dir: &Path) -> std::io::Result<Vec<(String, PathBuf)>> {
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(dir)
        .map_err(|e| std::io::Error::new(e.kind(), format!("{}: {e}", dir.display())))?
    {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.starts_with('#') || name.ends_with('~') {
            continue;
        }
        entries.push((name, entry.path()));
    }
    Ok(entries)
}

/// Every file at or under `path`, named `relative` and below, except the commands module.
fn collect(relative: &str, path: &Path, files: &mut Vec<(String, PathBuf)>) -> std::io::Result<()> {
    if relative == COMMANDS {
        return Ok(());
    }
    if !path.is_dir() {
        files.push((relative.to_string(), path.to_path_buf()));
        return Ok(());
    }
    for (name, path) in listing(path)? {
        collect(&format!("{relative}/{name}"), &path, files)?;
    }
    Ok(())
}

/// SHA-256 (FIPS 180-4) of `data`.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    // The message, a 1 bit, zeros to 56 bytes past a multiple of 64, and its length in bits.
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64).wrapping_mul(8)).to_be_bytes());
    // Whole blocks: the padding made the length a multiple of 64.
    for block in message.as_chunks::<64>().0 {
        let mut w = [0u32; 64];
        for (i, word) in block.as_chunks::<4>().0.iter().enumerate() {
            w[i] = u32::from_be_bytes(*word);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ (!e & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(choice)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (word, add) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *word = word.wrapping_add(add);
        }
    }
    let mut digest = [0u8; 32];
    for (i, word) in state.iter().enumerate() {
        digest[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    digest
}
