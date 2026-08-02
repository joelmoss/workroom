//! The snapshot must stamp the USER's identity onto `@`, not an empty one.
//!
//! `snapshot_working_copy` rewrites `@` whenever the working copy has moved, and jj-lib's
//! `CommitBuilder::for_rewrite_from` unconditionally sets `commit.committer = settings.signature()`.
//! While this crate built settings from `StackedConfig::with_defaults()` — whose compiled-in
//! `misc.toml` carries `user.name = ""` and `user.email = ""` — every status refresh that found a
//! change stamped an EMPTY committer onto the working-copy commit, for every jj user. Usually
//! invisible (`jj log` shows the author) and self-healing on the next real `jj` command, but not if
//! `@` is pushed as-is, which the app's Push button does via `jj git push --change @`.
//!
//! **This is its own test binary on purpose.** The fix reads `JJ_CONFIG` from the PROCESS
//! environment, so proving it end to end means setting that variable — and cargo runs the `#[test]`s
//! within a binary as parallel threads of one process, where a global env write would be visible to
//! and racing with every other test. One test, one binary, no race. The path policy itself is
//! covered deterministically by the unit tests in `src/jj_config.rs`, which take the environment as
//! a parameter and never touch the real one.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

mod common;

fn jj(args: &[&str], dir: &Path, config: &Path) -> std::process::Output {
    Command::new("jj")
        .args(args)
        .current_dir(dir)
        .env("JJ_CONFIG", config)
        .output()
        .unwrap_or_else(|e| panic!("run jj {args:?}: {e}"))
}

/// A throwaway repo whose jj config names a distinctive identity.
fn init_repo(tag: &str) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("wr-ident-{}-{}", std::process::id(), tag));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("jjconfig.toml");
    std::fs::write(
        &config,
        b"[user]\nname = \"Ada Lovelace\"\nemail = \"ada@example.com\"\n",
    )
    .unwrap();
    let init = jj(&["git", "init"], &dir, &config);
    assert!(
        init.status.success(),
        "jj git init: {}",
        String::from_utf8_lossy(&init.stderr)
    );
    (dir, config)
}

/// `@`'s committer, as `name <email>`.
fn committer(dir: &Path, config: &Path) -> String {
    let out = jj(
        &[
            "log",
            "--ignore-working-copy",
            "--no-graph",
            "-r",
            "@",
            "-T",
            r#"committer.name() ++ " <" ++ committer.email() ++ ">""#,
        ],
        dir,
        config,
    );
    assert!(
        out.status.success(),
        "jj log: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

#[test]
fn snapshot_stamps_the_users_identity_not_an_empty_one() {
    if common::skip_without(&["jj"], "committer identity test") {
        return;
    }
    let (dir, config) = init_repo("committer");

    // The fix reads the process environment. Safe here because this binary holds exactly one test.
    std::env::set_var("JJ_CONFIG", &config);

    // An on-disk edit jj hasn't snapshotted, so `working_status` must rewrite `@` to record it —
    // which is the rewrite that stamps the committer.
    std::fs::write(dir.join("a.txt"), b"hello\n").unwrap();

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    assert!(
        !status.working_copy.files.is_empty(),
        "the snapshot should have picked up the on-disk edit"
    );

    let stamped = committer(&dir, &config);
    assert_eq!(
        stamped, "Ada Lovelace <ada@example.com>",
        "the snapshot must carry the user's real identity; an empty one here is the bug this fixes"
    );
    assert!(
        !stamped.starts_with(" <"),
        "committer name must not be empty: {stamped}"
    );

    std::env::remove_var("JJ_CONFIG");
    let _ = std::fs::remove_dir_all(&dir);
}
