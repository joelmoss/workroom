//! Integration tests for the typed error surface: every `VcsError` variant the app has a distinct UI
//! state for must be *reachable* from a real repo. Until these existed the backend funnelled almost
//! everything through `VcsError::Io`, so Swift's case-by-case `RustJJProvider.mapError` (and the
//! recovery messages behind it) could never fire — a correct mapping of errors that were never
//! produced. Skips if `jj` isn't on PATH — and says so out loud; see `tests/common/mod.rs`.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use jj_lib::lock::FileLock;
use wr_vcs_model::VcsError;

mod common;

/// Run `jj` in `dir` with `config` as its ONLY config file. `JJ_CONFIG` goes per-`Command` (never
/// `set_var`) because cargo runs `#[test]`s in parallel threads of one process — see
/// `working_status.rs` for the full reasoning.
fn jj(args: &[&str], dir: &Path, config: &Path) -> std::process::Output {
    Command::new("jj")
        .args(args)
        .current_dir(dir)
        .env("JJ_CONFIG", config)
        .output()
        .unwrap_or_else(|e| panic!("run jj {args:?}: {e}"))
}

/// An empty throwaway directory, with an isolated jj config alongside it (for `jj` children).
fn temp_dir(tag: &str) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("wr-err-{}-{}", std::process::id(), tag));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("jjconfig.toml");
    std::fs::write(
        &config,
        b"[user]\nname = \"Test\"\nemail = \"test@example.com\"\n",
    )
    .unwrap();
    (dir, config)
}

/// A fresh throwaway repo (`jj git init`) with one real commit, so `@` has a parent to be rewritten.
fn init_repo(tag: &str) -> (PathBuf, PathBuf) {
    let (dir, config) = temp_dir(tag);
    let init = jj(&["git", "init"], &dir, &config);
    assert!(
        init.status.success(),
        "jj git init: {}",
        String::from_utf8_lossy(&init.stderr)
    );
    std::fs::write(dir.join("f.txt"), b"one\n").unwrap();
    jj(&["commit", "-m", "one"], &dir, &config);
    (dir, config)
}

/// A directory that isn't a jj repo at all must report `UnsupportedRepo`, not a stringified `Io`: the
/// app registers projects by path, and a path whose `.jj` has gone away is "not a repository" — the
/// same honest answer git already gives — rather than an unexplained I/O failure.
///
/// Asserted on BOTH entry shapes, since they take different code paths into `Workspace::load`:
/// `working_status` (the mutating snapshot) and `log_page` (the read-only `open`).
#[test]
fn a_non_jj_directory_reports_unsupported_repo() {
    let (dir, _cfg) = temp_dir("plain");

    match wr_vcs_core::working_status(&dir) {
        Err(VcsError::UnsupportedRepo(msg)) => assert!(
            msg.contains(dir.to_string_lossy().as_ref()),
            "message names the path: {msg}"
        ),
        other => panic!("expected UnsupportedRepo, got {other:?}"),
    }
    match wr_vcs_core::log_page(&dir, 10) {
        Err(VcsError::UnsupportedRepo(_)) => {}
        other => panic!("expected UnsupportedRepo from log_page, got {other:?}"),
    }
}

/// A repo naming a working-copy backend this build doesn't know must report `BackendVersion` — the
/// shape of a repo written by a newer jj than the `jj-lib` we pin. `Io` would invite a pointless
/// retry; `BackendVersion` says the build is the problem, and names the type.
#[test]
fn an_unknown_working_copy_backend_reports_backend_version() {
    if common::skip_without(&["jj"], "backend-version test") {
        return;
    }
    let (dir, _cfg) = init_repo("backend");
    // jj records the working-copy backend's name here; `default_working_copy_factories` only knows
    // "local", so an unknown value is exactly the unsupported-type failure.
    std::fs::write(dir.join(".jj/working_copy/type"), b"from-the-future").unwrap();

    match wr_vcs_core::working_status(&dir) {
        Err(VcsError::BackendVersion(msg)) => {
            assert!(msg.contains("from-the-future"), "names the type: {msg}");
            assert!(msg.contains("working copy"), "names the store: {msg}");
        }
        other => panic!("expected BackendVersion, got {other:?}"),
    }
}

/// The wall-clock budget for the contended read below. Generous by two orders of magnitude against
/// what the `try_lock` probe costs (an `exists()` plus a non-blocking `flock`, microseconds) and
/// still far under any plausible blocking wait — a real `jj rebase` or `jj log` in a big repo holds
/// that lock for seconds to minutes, which is the whole reason the probe exists. Sized to be immune
/// to a loaded CI box: the entire file currently runs in ~5s, of which this test is a fraction.
const CONTENTION_BUDGET: Duration = Duration::from_secs(1);

/// A held working-copy lock must report `LockContention` **immediately**, not block.
///
/// This is the case the taxonomy could never produce: jj-lib's `FileLock::lock` blocks on `flock`
/// forever and has no contention error, so a `jj` command running in a workroom terminal used to
/// stall the status sweep for its whole duration. The lock here is taken exactly the way another
/// process would take it, then released — and the release must leave the repo readable, proving the
/// probe neither corrupts nor wedges the lock file it touches.
///
/// **The elapsed-time assertion is not decoration — it is the actual claim.** The variant on its own
/// pins almost nothing: swap `lock_is_held`'s non-blocking `FileLock::try_lock` probe for a blocking
/// `FileLock::lock` with a timeout, map the timeout to `LockContention`, and a variant-only test
/// stays green while the original defect is fully restored — a GCD thread and the project's
/// `JJSnapshotGate` slot pinned for as long as the user's `jj` command runs, with every other
/// workroom of that project queued behind it. Speed *is* the fix; the error type is just how it's
/// reported.
#[test]
fn a_held_working_copy_lock_reports_lock_contention() {
    if common::skip_without(&["jj"], "lock-contention test") {
        return;
    }
    let (dir, _cfg) = init_repo("lock");
    // Snapshot once while nothing is held, so the failure below can only be the lock.
    wr_vcs_core::working_status(&dir).expect("baseline working_status");

    let lock_path = dir.join(".jj/working_copy/working_copy.lock");
    let held = FileLock::lock(lock_path).expect("take the working-copy lock");
    // Timed around the call alone: the fixture above builds a repo with the `jj` CLI, which is
    // orders of magnitude slower than the thing being measured.
    let started = Instant::now();
    let contended = wr_vcs_core::working_status(&dir);
    let elapsed = started.elapsed();
    // Release before asserting, so a failure can't leave the lock held for the rest of the binary.
    drop(held);

    match contended {
        Err(VcsError::LockContention) => {}
        other => panic!("expected LockContention, got {other:?}"),
    }
    assert!(
        elapsed < CONTENTION_BUDGET,
        "contention must be detected without waiting on the lock, but the read took {elapsed:?} \
         (budget {CONTENTION_BUDGET:?}) — the probe is blocking again"
    );

    wr_vcs_core::working_status(&dir).expect("readable again once the lock is released");
}

/// A stale working copy must report `StaleSnapshot` instead of being snapshotted from a base that no
/// longer describes it.
///
/// This is the real Workroom shape of the bug: workrooms of one project are jj **workspaces** of one
/// repo, so an operation in workroom A can rewrite workroom B's `@`. Here `jj op restore` (run from
/// the first workspace) rewinds the repo under a second workspace whose recorded state is newer. jj's
/// own CLI refuses to work in that state; before this guard our snapshot went ahead and wrote a new
/// `@` from the stale base.
#[test]
fn a_stale_second_workspace_reports_stale_snapshot() {
    if common::skip_without(&["jj"], "stale test") {
        return;
    }
    let (dir, cfg) = init_repo("stale");
    let ws2 = dir.with_file_name(format!(
        "{}-ws2",
        dir.file_name().unwrap().to_string_lossy()
    ));
    let _ = std::fs::remove_dir_all(&ws2);
    let add = jj(&["workspace", "add", ws2.to_str().unwrap()], &dir, &cfg);
    assert!(
        add.status.success(),
        "jj workspace add: {}",
        String::from_utf8_lossy(&add.stderr)
    );

    // The operation to rewind to: everything after this belongs to the second workspace.
    let before = jj(
        &["op", "log", "--no-graph", "-n", "1", "-T", "id.short()"],
        &dir,
        &cfg,
    );
    let before = String::from_utf8_lossy(&before.stdout).trim().to_string();
    assert!(!before.is_empty(), "read an operation id");

    // Give the second workspace a tree of its own and snapshot it — its recorded state is now newer
    // than the operation we're about to restore.
    std::fs::write(ws2.join("mine.txt"), b"second workspace\n").unwrap();
    let status = wr_vcs_core::working_status(&ws2).expect("snapshot the second workspace");
    assert!(status.dirty, "the second workspace has its own change");

    let restore = jj(
        &["op", "restore", &before, "--ignore-working-copy"],
        &dir,
        &cfg,
    );
    assert!(
        restore.status.success(),
        "jj op restore: {}",
        String::from_utf8_lossy(&restore.stderr)
    );

    // jj itself must agree the second workspace is stale — otherwise the fixture is wrong, not the
    // guard under test.
    let cli = jj(&["status"], &ws2, &cfg);
    let cli_says = String::from_utf8_lossy(&cli.stderr).to_lowercase();
    assert!(
        cli_says.contains("stale"),
        "fixture is not stale according to jj: {cli_says}"
    );

    match wr_vcs_core::working_status(&ws2) {
        Err(VcsError::StaleSnapshot) => {}
        other => panic!("expected StaleSnapshot, got {other:?}"),
    }
}
