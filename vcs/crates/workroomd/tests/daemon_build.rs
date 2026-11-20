//! The daemon build identity (#680): `protocol`'s `daemon-build <hash>`, which a running daemon
//! compares with a binary it is offered to decide whether to hand off. A change to the CLI's
//! `commands` module alone must leave it as it was, so a CLI-only update restarts nothing; any
//! other source, the lock file or the Ghostty pin must change it.
//!
//! The hash is `build.rs`'s, from `build/daemon_build.rs`, loaded here as it is there. The trees
//! below are made up, laid out as `vcs/` is; the last test holds the real tree to the real binary.

use std::path::{Path, PathBuf};
use std::process::Command;

#[allow(dead_code)] // not every helper is used here
mod common;
use common::{Workspace, daemon_binary};

#[path = "../build/daemon_build.rs"]
mod daemon_build;

/// A workspace laid out as `vcs/` is, with a file or two in each place the hash reads.
fn tree(root: &Path) {
    let files: &[(&str, &str)] = &[
        ("Cargo.toml", "[workspace]\n"),
        ("Cargo.lock", "version = 4\n"),
        ("scripts/build-ghostty-vt.sh", "GHOSTTY_SHA=abc\n"),
        (
            "crates/workroomd/Cargo.toml",
            "[package]\nname = \"workroom\"\n",
        ),
        ("crates/workroomd/build.rs", "fn main() {}\n"),
        ("crates/workroomd/build/daemon_build.rs", "// the hash\n"),
        ("crates/workroomd/src/lib.rs", "pub mod commands;\n"),
        ("crates/workroomd/src/main.rs", "fn main() {}\n"),
        ("crates/workroomd/src/cli/route.rs", "// route\n"),
        ("crates/workroomd/src/daemon/serve.rs", "// serve\n"),
        ("crates/workroomd/src/run_supervisor.sh", "#!/bin/sh\n"),
        ("crates/workroomd/src/commands/mod.rs", "// commands\n"),
        ("crates/workroomd/src/commands/version.rs", "// version\n"),
        ("crates/workroomd/tests/hand_off.rs", "// a test\n"),
        ("crates/wr-protocol/Cargo.toml", "[package]\n"),
        ("crates/wr-protocol/src/lib.rs", "// protocol\n"),
        ("crates/wr-protocol/tests/frames.rs", "// a test\n"),
    ];
    for (path, content) in files {
        write(root, path, content);
    }
}

fn write(root: &Path, path: &str, content: &str) {
    let path = root.join(path);
    std::fs::create_dir_all(path.parent().expect("a parent")).expect("mkdir");
    std::fs::write(path, content).expect("write");
}

fn hash(root: &Path) -> String {
    daemon_build::daemon_build(root, &[]).expect("hash").hash
}

/// A copy of the made-up tree with one file written, and its hash.
fn hash_after(name: &str, path: &str, content: &str) -> String {
    let workspace = Workspace::new(name);
    tree(&workspace.dir);
    write(&workspace.dir, path, content);
    hash(&workspace.dir)
}

/// The made-up tree's hash. Each call has a directory of its own: the tests run in parallel.
fn base_hash() -> String {
    static CALLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let call = CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let workspace = Workspace::new(&format!("daemon-build-base-{call}"));
    tree(&workspace.dir);
    hash(&workspace.dir)
}

#[test]
fn a_change_to_the_commands_module_alone_keeps_the_daemon_build() {
    let base = base_hash();
    for (name, path) in [
        ("edit", "crates/workroomd/src/commands/version.rs"),
        ("add", "crates/workroomd/src/commands/update.rs"),
    ] {
        assert_eq!(
            hash_after(
                &format!("daemon-build-commands-{name}"),
                path,
                "// changed\n"
            ),
            base,
            "{path}"
        );
    }
}

/// Tests are no part of the binary, and every CLI port adds contract tests: none of them may hand
/// off a host's daemon. Nor may an editor's swap file or Finder's `.DS_Store`.
#[test]
fn tests_and_hidden_files_keep_the_daemon_build() {
    let base = base_hash();
    for (name, path) in [
        ("test", "crates/workroomd/tests/hand_off.rs"),
        ("dep-test", "crates/wr-protocol/tests/frames.rs"),
        ("swap", "crates/workroomd/src/daemon/.serve.rs.swp"),
        ("finder", "crates/workroomd/src/.DS_Store"),
        ("backup", "crates/workroomd/src/daemon/serve.rs~"),
    ] {
        assert_eq!(
            hash_after(&format!("daemon-build-keeps-{name}"), path, "// changed\n"),
            base,
            "{path}"
        );
    }
}

/// Which arguments are the daemon's and which the CLI's is decided before either runs, on every
/// daemon start and in every child a daemon starts from its own file: a slip there that sends a
/// daemon subcommand to the CLI would break the daemon, so it is the daemon's code, outside the
/// commands module, and changes the daemon build.
#[test]
fn the_routing_between_the_cli_and_the_daemon_changes_the_daemon_build() {
    // The made-up tree holds the real routing's path, so this follows it if it moves.
    let real = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/cli/route.rs");
    let source = std::fs::read_to_string(&real).expect("the routing is at src/cli/route.rs");
    assert!(source.contains("DAEMON_SUBCOMMANDS"), "{}", real.display());
    let base = base_hash();
    for (name, path) in [
        ("route", "crates/workroomd/src/cli/route.rs"),
        ("main", "crates/workroomd/src/main.rs"),
    ] {
        assert_ne!(
            hash_after(
                &format!("daemon-build-routing-{name}"),
                path,
                "// changed\n"
            ),
            base,
            "{path}"
        );
    }
}

#[test]
fn a_change_to_any_other_source_or_the_lock_file_changes_the_daemon_build() {
    let base = base_hash();
    for (name, path) in [
        ("daemon", "crates/workroomd/src/daemon/serve.rs"),
        ("lib", "crates/workroomd/src/lib.rs"),
        ("script", "crates/workroomd/src/run_supervisor.sh"),
        ("new-module", "crates/workroomd/src/daemon/new.rs"),
        ("manifest", "crates/workroomd/Cargo.toml"),
        ("build-script", "crates/workroomd/build.rs"),
        ("hash", "crates/workroomd/build/daemon_build.rs"),
        ("dependency", "crates/wr-protocol/src/lib.rs"),
        ("new-crate", "crates/wr-new/src/lib.rs"),
        ("lock", "Cargo.lock"),
        ("workspace", "Cargo.toml"),
        ("ghostty-pin", "scripts/build-ghostty-vt.sh"),
    ] {
        assert_ne!(
            hash_after(
                &format!("daemon-build-changes-{name}"),
                path,
                "// changed\n"
            ),
            base,
            "{path}"
        );
    }
}

/// A file moved is a change even with its bytes kept, and so is one file's bytes moving into
/// another: each file is framed by its path and length.
#[test]
fn a_moved_file_or_moved_bytes_change_the_daemon_build() {
    let base = base_hash();
    let workspace = Workspace::new("daemon-build-moved");
    tree(&workspace.dir);
    std::fs::rename(
        workspace.dir.join("crates/workroomd/src/daemon/serve.rs"),
        workspace.dir.join("crates/workroomd/src/daemon/served.rs"),
    )
    .expect("move");
    assert_ne!(hash(&workspace.dir), base);

    let workspace = Workspace::new("daemon-build-shifted");
    tree(&workspace.dir);
    write(&workspace.dir, "crates/workroomd/src/daemon/serve.rs", "");
    write(
        &workspace.dir,
        "crates/workroomd/src/lib.rs",
        "pub mod commands;\n// serve\n",
    );
    assert_ne!(hash(&workspace.dir), base);
}

/// The same sources on two machines, checked out in two places, are the same daemon: the hash
/// holds no absolute path and no time, and does not depend on the order a directory lists in.
#[test]
fn the_same_sources_anywhere_are_the_same_daemon_build() {
    let first = Workspace::new("daemon-build-here");
    tree(&first.dir);
    let second = Workspace::new("daemon-build-elsewhere");
    let nested = second.dir.join("somewhere/else/vcs");
    tree(&nested);
    // Older times on every file of one tree, and new files written in another order.
    std::thread::sleep(std::time::Duration::from_millis(20));
    write(
        &nested,
        "crates/workroomd/src/daemon/serve.rs",
        "// serve\n",
    );
    assert_eq!(hash(&first.dir), hash(&nested));
}

/// `terminal-state` decides whether a daemon can repaint a reattaching pane, so a build with it
/// is a different daemon from the same sources without it.
#[test]
fn the_features_are_part_of_the_daemon_build() {
    let workspace = Workspace::new("daemon-build-features");
    tree(&workspace.dir);
    let without = daemon_build::daemon_build(&workspace.dir, &[]).expect("hash");
    let with = daemon_build::daemon_build(&workspace.dir, &["terminal-state"]).expect("hash");
    assert_ne!(without.hash, with.hash);
}

/// Cargo reruns `build.rs` only for what it names, so every place the hash reads is named: a
/// change cargo did not notice would leave a binary reporting its old daemon build. The crates'
/// tests are not, so editing one rebuilds nothing.
#[test]
fn cargo_watches_every_place_the_hash_reads() {
    let workspace = Workspace::new("daemon-build-roots");
    tree(&workspace.dir);
    let roots = daemon_build::daemon_build(&workspace.dir, &[])
        .expect("hash")
        .roots;
    let relative: Vec<PathBuf> = roots
        .iter()
        .map(|root| {
            root.strip_prefix(&workspace.dir)
                .expect("inside the workspace")
                .to_path_buf()
        })
        .collect();
    for watched in [
        "Cargo.toml",
        "Cargo.lock",
        "scripts/build-ghostty-vt.sh",
        "crates/workroomd/Cargo.toml",
        "crates/workroomd/build.rs",
        "crates/workroomd/build",
        "crates/workroomd/src",
        "crates/wr-protocol/Cargo.toml",
        "crates/wr-protocol/src",
    ] {
        assert!(
            relative.contains(&PathBuf::from(watched)),
            "{watched} is not watched: {relative:?}"
        );
    }
    assert!(
        !relative.iter().any(|path| path.ends_with("tests")),
        "a tests directory is watched: {relative:?}"
    );
}

#[test]
fn the_hash_is_sha256() {
    let hex = |bytes: [u8; 32]| -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() };
    for (input, expected) in [
        (
            &b""[..],
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ),
        (
            b"abc",
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        ),
        (
            b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        ),
    ] {
        assert_eq!(hex(daemon_build::sha256(input)), expected);
    }
    assert_eq!(
        hex(daemon_build::sha256(&vec![b'a'; 1_000_000])),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    );
}

/// The real tree, hashed now, is what the binary built from it states, and its marker says the
/// same: so `build.rs` hashes this tree, with the features this binary was built with.
#[test]
fn the_binary_states_the_daemon_build_of_its_own_sources() {
    let binary = daemon_binary();
    let report = Command::new(&binary)
        .arg("protocol")
        .output()
        .expect("protocol");
    let report = String::from_utf8_lossy(&report.stdout).into_owned();
    let stated = report
        .lines()
        .find_map(|line| line.strip_prefix("daemon-build "))
        .unwrap_or_else(|| panic!("no `daemon-build` line in {report:?}"));
    let features: &[&str] = if report.lines().any(|line| line == "terminal-state yes") {
        &["terminal-state"]
    } else {
        &[]
    };
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let hashed = daemon_build::daemon_build(&workspace, features).expect("hash the real tree");
    assert_eq!(stated, hashed.hash);
    assert_eq!(stated.len(), 64, "{stated:?}");
}

/// A daemon reads a binary's daemon build out of its bytes, without running it, as the app reads
/// the build number (`the_linked_program_carries_its_build_marker`, in `hand_off.rs`). So the
/// marker is in the linked program, its prefix is there once (the reader splits the marker rather
/// than spelling the prefix), and it is the value `protocol` states.
#[test]
fn the_linked_program_carries_its_daemon_build_marker() {
    let binary = daemon_binary();
    let bytes = std::fs::read(&binary).expect("read the daemon");
    let prefix = b"WORKROOMD-DAEMON-BUILD:";
    let found: Vec<usize> = bytes
        .windows(prefix.len())
        .enumerate()
        .filter(|(_, window)| *window == prefix)
        .map(|(at, _)| at)
        .collect();
    assert_eq!(found.len(), 1, "the prefix is there {} times", found.len());
    let rest = &bytes[found[0] + prefix.len()..];
    let end = rest
        .iter()
        .position(|&byte| byte == b';')
        .expect("an unterminated marker");
    let marked = std::str::from_utf8(&rest[..end]).expect("a hex marker");
    let report = Command::new(&binary)
        .arg("protocol")
        .output()
        .expect("protocol");
    assert!(
        String::from_utf8_lossy(&report.stdout).contains(&format!("daemon-build {marked}\n")),
        "marker {marked} is not the daemon build protocol states"
    );
}
