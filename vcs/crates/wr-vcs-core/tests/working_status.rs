//! Integration test for `working_status` against a REAL throwaway jj repo. The point is the
//! snapshot: `working_status` must pick up an on-disk edit that jj hasn't snapshotted yet (proving
//! it takes the working-copy lock + rewrites `@`), and leave the repo consistent (a second read + a
//! `jj status` agree — no corruption). Skips if `jj` isn't on PATH.

use std::path::Path;
use std::process::Command;

fn have_jj() -> bool {
    Command::new("jj")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn jj(args: &[&str], dir: &Path) -> std::process::Output {
    Command::new("jj")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap_or_else(|e| panic!("run jj {args:?}: {e}"))
}

#[test]
fn working_status_snapshots_disk_edits_without_corrupting() {
    if !have_jj() {
        eprintln!("skipping working_status test: `jj` not on PATH");
        return;
    }
    let dir = std::env::temp_dir().join(format!("wr-ws-{}-{}", std::process::id(), line!()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // Isolate jj config so the test doesn't depend on (or touch) the developer's ~/.config/jj, and
    // provides an author for the snapshot operation.
    let cfg = dir.join("jjconfig.toml");
    std::fs::write(
        &cfg,
        b"[user]\nname = \"Test\"\nemail = \"test@example.com\"\n",
    )
    .unwrap();
    // SAFETY: single-threaded test process; set before any jj/jj-lib call.
    unsafe { std::env::set_var("JJ_CONFIG", &cfg) }

    let init = jj(&["git", "init"], &dir);
    assert!(
        init.status.success(),
        "jj git init: {}",
        String::from_utf8_lossy(&init.stderr)
    );

    // Write a file on disk that jj has NOT snapshotted yet.
    std::fs::write(dir.join("hello.txt"), b"hi\n").unwrap();

    // The read must snapshot `@` so the on-disk file shows up as a change.
    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    assert!(status.dirty, "an on-disk edit should make @ dirty");
    assert!(
        status
            .working_copy
            .files
            .iter()
            .any(|f| f.path == "hello.txt"),
        "hello.txt should be a working-copy change; got {:?}",
        status.working_copy.files
    );
    assert!(!status.conflicted);
    // @ sits on the (empty) root commit → parent is the root's change set (or Root if @ IS root).
    assert!(
        matches!(
            status.parent,
            wr_vcs_core::model::ParentState::Changes(_) | wr_vcs_core::model::ParentState::Root
        ),
        "parent resolves to a single-parent change set or root; got {:?}",
        status.parent
    );

    // No corruption: jj itself now sees the snapshotted file in @, and a second read agrees.
    let diff = jj(
        &[
            "diff",
            "--summary",
            "-r",
            "@",
            "--ignore-working-copy",
            "--color",
            "never",
        ],
        &dir,
    );
    assert!(
        diff.status.success(),
        "jj diff after snapshot: {}",
        String::from_utf8_lossy(&diff.stderr)
    );
    assert!(
        String::from_utf8_lossy(&diff.stdout).contains("hello.txt"),
        "jj should see hello.txt in @ after our snapshot; got {:?}",
        String::from_utf8_lossy(&diff.stdout)
    );
    let status2 = wr_vcs_core::working_status(&dir).expect("second read");
    assert!(
        status2
            .working_copy
            .files
            .iter()
            .any(|f| f.path == "hello.txt"),
        "second read agrees"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// The working copy's `change_id` is jj's SHORT display id: the reverse-hex ("z-k" digit) form
/// truncated to a unique prefix — the same thing `jj log` shows (e.g. `wo`), NOT the full 32-digit
/// hex. Guards the "use short refs for jj" behavior the Changes-panel header depends on.
#[test]
fn working_status_change_id_is_short_reverse_hex() {
    if !have_jj() {
        eprintln!("skipping change-id test: `jj` not on PATH");
        return;
    }
    let dir = std::env::temp_dir().join(format!("wr-ws-{}-{}", std::process::id(), line!()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let cfg = dir.join("jjconfig.toml");
    std::fs::write(
        &cfg,
        b"[user]\nname = \"Test\"\nemail = \"test@example.com\"\n",
    )
    .unwrap();
    // SAFETY: single-threaded test process; set before any jj/jj-lib call.
    unsafe { std::env::set_var("JJ_CONFIG", &cfg) }
    assert!(jj(&["git", "init"], &dir).status.success());
    // A couple of described commits so the repo isn't degenerate (a realistic unique prefix).
    std::fs::write(dir.join("a.txt"), b"a\n").unwrap();
    jj(&["commit", "-m", "first"], &dir);
    std::fs::write(dir.join("b.txt"), b"b\n").unwrap();

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    let cid = status.working_copy.change_id.expect("@ has a change-id");

    // The full change-id jj prints for `@` (reverse-hex; no method → all 32 "digits").
    let full = jj(
        &[
            "log",
            "--no-graph",
            "--color",
            "never",
            "-r",
            "@",
            "-T",
            "change_id",
        ],
        &dir,
    );
    let full = String::from_utf8_lossy(&full.stdout).trim().to_string();

    assert!(!cid.is_empty(), "change-id is non-empty");
    assert!(
        cid.len() < full.len(),
        "short prefix ({cid:?}) shorter than full ({full:?})"
    );
    assert!(
        full.starts_with(&cid),
        "{cid:?} is a prefix of the full change-id {full:?}"
    );
    // Reverse-hex uses the letters k..=z only — never a 0-9a-f hex digit.
    assert!(
        cid.chars().all(|c| ('k'..='z').contains(&c)),
        "reverse-hex letters only; got {cid:?}"
    );
    // And it matches exactly what `jj log` shows as the short change-id.
    let short = jj(
        &[
            "log",
            "--no-graph",
            "--color",
            "never",
            "-r",
            "@",
            "-T",
            "change_id.shortest()",
        ],
        &dir,
    );
    let short = String::from_utf8_lossy(&short.stdout).trim().to_string();
    assert_eq!(cid, short, "change-id matches jj's short change-id");

    let _ = std::fs::remove_dir_all(&dir);
}
