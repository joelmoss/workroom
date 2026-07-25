//! Integration test for `working_status` against a REAL throwaway jj repo. The point is the
//! snapshot: `working_status` must pick up an on-disk edit that jj hasn't snapshotted yet (proving
//! it takes the working-copy lock + rewrites `@`), and leave the repo consistent (a second read + a
//! `jj status` agree — no corruption). Skips if `jj` isn't on PATH.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

fn have_jj() -> bool {
    Command::new("jj")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Run `jj` in `dir` with `config` as its ONLY config file.
///
/// `JJ_CONFIG` is passed per-`Command`, never through `std::env::set_var`: cargo runs `#[test]`s in
/// parallel threads of one process, so a global env write is visible to (and racing with) every
/// other test. Nothing else needs it — jj-lib itself never reads `JJ_CONFIG` on our path
/// (`snapshot_working_copy` builds `UserSettings` from `StackedConfig::with_defaults()`), so the
/// variable only has to reach the `jj` CLI children these fixtures shell out to.
fn jj(args: &[&str], dir: &Path, config: &Path) -> std::process::Output {
    Command::new("jj")
        .args(args)
        .current_dir(dir)
        .env("JJ_CONFIG", config)
        .output()
        .unwrap_or_else(|e| panic!("run jj {args:?}: {e}"))
}

/// A fresh throwaway repo: unique dir, isolated jj config (also supplying an author so snapshot
/// operations can commit), `jj git init` run. Returns `(dir, config)` for `jj(…)` calls.
fn init_repo(tag: &str) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("wr-ws-{}-{}", std::process::id(), tag));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("jjconfig.toml");
    std::fs::write(
        &config,
        b"[user]\nname = \"Test\"\nemail = \"test@example.com\"\n",
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

/// The commit id of `@-` (the last real commit), as hex.
fn parent_id(dir: &Path, cfg: &Path) -> String {
    let out = jj(
        &[
            "log",
            "-r",
            "@-",
            "--no-graph",
            "--ignore-working-copy",
            "--color",
            "never",
            "-T",
            "commit_id",
        ],
        dir,
        cfg,
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// A repo whose `@` is a 2-sided **modify/modify** conflict on `f.txt`:
/// `base` → (`left`, `right`) → `jj new <left> <right>`. `@`'s first parent is `left`, so a tree diff
/// of `@` vs its first parent yields `f.txt` with an unresolved `after` value.
///
/// The two sides are addressed by **commit id**, never by bookmark: with jj's
/// `experimental-advance-branches` enabled, `jj commit` advances a bookmark onto the commit it just
/// created, which collapses the two sides onto one and produces no conflict at all. (`init_repo`'s
/// isolated `JJ_CONFIG` already keeps that setting out of these tests, but ids don't depend on it.)
///
/// Built with the `jj` CLI on PATH while the read under test is `jj-lib =0.43.0`. That skew is
/// expected to be harmless, but if this fixture ever breaks on CI first, suspect the CLI before the
/// classifier.
fn conflicted_repo(tag: &str) -> (PathBuf, PathBuf) {
    let (dir, cfg) = init_repo(tag);
    std::fs::write(dir.join("f.txt"), b"base\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    let base = parent_id(&dir, &cfg);
    std::fs::write(dir.join("f.txt"), b"left\n").unwrap();
    jj(&["commit", "-m", "left"], &dir, &cfg);
    let left = parent_id(&dir, &cfg);
    jj(&["new", &base, "-m", "right"], &dir, &cfg);
    std::fs::write(dir.join("f.txt"), b"right\n").unwrap();
    jj(&["commit", "-m", "right"], &dir, &cfg);
    let right = parent_id(&dir, &cfg);
    jj(&["new", &left, &right], &dir, &cfg);
    (dir, cfg)
}

/// Is `@` conflicted according to jj itself? (`--ignore-working-copy` so the check can't perturb the
/// state it's verifying.)
fn jj_says_conflicted(dir: &Path, cfg: &Path) -> bool {
    let out = jj(
        &[
            "log",
            "--no-graph",
            "--ignore-working-copy",
            "--color",
            "never",
            "-r",
            "@",
            "-T",
            "conflict",
        ],
        dir,
        cfg,
    );
    String::from_utf8_lossy(&out.stdout).trim() == "true"
}

/// A conflicted `@` must report the conflict **per file**, not as a plain modification — the jj half
/// of the affordance git already has (`GitProvider` emits per-file `.conflicted`).
///
/// This also guards the riskiest interaction in the read: `working_status` MUTATES (working-copy
/// lock → `rewrite_commit` → `rebase_descendants`), so the conflict has to survive it. Without the
/// second-read + CLI cross-check, a snapshot that silently flattened the conflict into a
/// marker-bearing normal file could pass unnoticed.
#[test]
fn working_status_reports_per_file_conflict_and_leaves_it_intact() {
    if !have_jj() {
        eprintln!("skipping conflict test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = conflicted_repo("conflict");
    assert!(
        jj_says_conflicted(&dir, &cfg),
        "fixture is not conflicted — the fixture is wrong, not the classifier"
    );

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    assert!(status.conflicted, "@ carries a conflict");
    let f = status
        .working_copy
        .files
        .iter()
        .find(|f| f.path == "f.txt")
        .unwrap_or_else(|| panic!("f.txt missing from {:?}", status.working_copy.files));
    assert_eq!(
        f.kind,
        wr_vcs_core::model::ChangeKind::Conflicted,
        "conflicted file must not read as a plain modification"
    );

    // No corruption: the conflict is still there afterwards, per jj itself and per a second read.
    assert!(
        jj_says_conflicted(&dir, &cfg),
        "our mutating snapshot must not resolve/flatten the conflict"
    );
    let again = wr_vcs_core::working_status(&dir).expect("second read");
    assert!(again.conflicted, "second read still conflicted");
    assert!(
        again
            .working_copy
            .files
            .iter()
            .any(|f| f.path == "f.txt" && f.kind == wr_vcs_core::model::ChangeKind::Conflicted),
        "second read agrees on the per-file kind; got {:?}",
        again.working_copy.files
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// A delete/modify conflict where the FIRST parent lacks the path: `base` has `g.txt`, `left`
/// deletes it, `right` modifies it. `@ = jj new left right` therefore diffs an *absent* before
/// against an *unresolved* after — which must classify as `Conflicted`, not `Added` (git calls this
/// shape `AA`/`DU`). Locks the branch ORDER in `changed_files`, not just the branch's existence.
#[test]
fn conflict_beats_added_when_the_first_parent_lacks_the_path() {
    if !have_jj() {
        eprintln!("skipping delete/modify conflict test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("conflict-added");
    std::fs::write(dir.join("g.txt"), b"base\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    let base = parent_id(&dir, &cfg);
    // left: delete g.txt
    std::fs::remove_file(dir.join("g.txt")).unwrap();
    jj(&["commit", "-m", "left-deletes"], &dir, &cfg);
    let left = parent_id(&dir, &cfg);
    // right: modify g.txt
    jj(&["new", &base, "-m", "right-modifies"], &dir, &cfg);
    std::fs::write(dir.join("g.txt"), b"right\n").unwrap();
    jj(&["commit", "-m", "right-modifies"], &dir, &cfg);
    let right = parent_id(&dir, &cfg);
    jj(&["new", &left, &right], &dir, &cfg);
    assert!(
        jj_says_conflicted(&dir, &cfg),
        "fixture is not conflicted — the fixture is wrong, not the classifier"
    );

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    let g = status
        .working_copy
        .files
        .iter()
        .find(|f| f.path == "g.txt")
        .unwrap_or_else(|| panic!("g.txt missing from {:?}", status.working_copy.files));
    assert_eq!(
        g.kind,
        wr_vcs_core::model::ChangeKind::Conflicted,
        "an unresolved after-value outranks an absent before-value"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// jj stores conflicts in the tree, so a *commit* can be conflicted too — `changeset` shares
/// `changed_files` with `working_status`, so a conflicted commit's file list must report it as well.
/// This is the half git cannot represent: a colocated git repo sees the same commit as an ADD of
/// jj's `.jjconflict-*` sidecar trees, with no entry for the conflicted path at all
/// (`VCSProviderConformanceTests` asserts that divergence app-side).
#[test]
fn changeset_reports_a_conflicted_commit() {
    if !have_jj() {
        eprintln!("skipping conflicted-changeset test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = conflicted_repo("conflict-changeset");
    // Turn the conflicted merge `@` into a real (described) commit, then read it back by id.
    jj(&["commit", "-m", "merged with conflict"], &dir, &cfg);
    let out = jj(
        &[
            "log",
            "--no-graph",
            "--ignore-working-copy",
            "--color",
            "never",
            "-r",
            "@-",
            "-T",
            "commit_id",
        ],
        &dir,
        &cfg,
    );
    let cid = String::from_utf8_lossy(&out.stdout).trim().to_string();
    assert!(!cid.is_empty(), "could not resolve the merge commit id");

    let cs = wr_vcs_core::changeset(&dir, &cid).expect("changeset");
    assert!(cs.is_merge, "the fixture commit is a 2-parent merge");
    assert!(
        cs.files
            .iter()
            .any(|f| f.path == "f.txt" && f.kind == wr_vcs_core::model::ChangeKind::Conflicted),
        "conflicted commit should report f.txt as Conflicted; got {:?}",
        cs.files
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// The mirror-image ordering: when the conflict is in the FIRST PARENT and the path is gone from
/// `@`, the file is `Deleted` — there is nothing left to resolve. Guards against a future reorder
/// that tests `before` for a conflict too.
#[test]
fn deleted_beats_conflict_when_the_path_is_gone_from_the_working_copy() {
    if !have_jj() {
        eprintln!("skipping conflict-then-deleted test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = conflicted_repo("conflict-deleted");
    // A child of the conflicted merge, then delete the conflicted file on disk: `@`'s first parent
    // holds the unresolved value, `@` holds nothing.
    jj(&["new", "-m", "drop the conflicted file"], &dir, &cfg);
    std::fs::remove_file(dir.join("f.txt")).unwrap();

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    let f = status
        .working_copy
        .files
        .iter()
        .find(|f| f.path == "f.txt")
        .unwrap_or_else(|| panic!("f.txt missing from {:?}", status.working_copy.files));
    assert_eq!(
        f.kind,
        wr_vcs_core::model::ChangeKind::Deleted,
        "a removed path is Deleted even though the before-value was a conflict"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn working_status_snapshots_disk_edits_without_corrupting() {
    if !have_jj() {
        eprintln!("skipping working_status test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("snapshot");

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
        &cfg,
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
    let (dir, cfg) = init_repo("change-id");
    // A couple of described commits so the repo isn't degenerate (a realistic unique prefix).
    std::fs::write(dir.join("a.txt"), b"a\n").unwrap();
    jj(&["commit", "-m", "first"], &dir, &cfg);
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
        &cfg,
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
        &cfg,
    );
    let short = String::from_utf8_lossy(&short.stdout).trim().to_string();
    assert_eq!(cid, short, "change-id matches jj's short change-id");

    let _ = std::fs::remove_dir_all(&dir);
}
