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
        status.files.iter().any(|f| f.path == "hello.txt"),
        "hello.txt should be a working-copy change; got {:?}",
        status.files
    );
    assert!(!status.conflicted);

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
        status2.files.iter().any(|f| f.path == "hello.txt"),
        "second read agrees"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
