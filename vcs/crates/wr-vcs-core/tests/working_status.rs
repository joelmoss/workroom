//! Integration test for `working_status` against a REAL throwaway jj repo. The point is the
//! snapshot: `working_status` must pick up an on-disk edit that jj hasn't snapshotted yet (proving
//! it takes the working-copy lock + rewrites `@`), and leave the repo consistent (a second read + a
//! `jj status` agree — no corruption). Skips if `jj` isn't on PATH — and says so out loud; see
//! `tests/common/mod.rs`.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

mod common;

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
    if common::skip_without(&["jj"], "conflict test") {
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
    if common::skip_without(&["jj"], "delete/modify conflict test") {
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
    if common::skip_without(&["jj"], "conflicted-changeset test") {
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
    if common::skip_without(&["jj"], "conflict-then-deleted test") {
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

/// Content big enough that a rename is a rename and not a coincidence: gix's rewrite tracking pairs
/// an identical blob exactly, and needs ≥50% similarity when the content also changed.
const RENAME_BODY: &[u8] = b"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n";

/// A renamed file must read as ONE `Renamed` row carrying `old_path`, not a delete + an add. jj-lib
/// itself has no similarity detection — the *backend* supplies copy records, and the git backend
/// (gix rewrite tracking) is what every colocated workroom uses. A pure-jj repo on
/// `simple_backend` returns no records and still reports delete+add; that degradation is deliberate
/// (see `copy_records`), and can't be exercised here since `jj git init` is always git-backed.
#[test]
fn working_status_reports_a_rename_with_its_old_path() {
    if common::skip_without(&["jj"], "rename test") {
        return;
    }
    let (dir, cfg) = init_repo("rename");
    std::fs::write(dir.join("old.txt"), RENAME_BODY).unwrap();
    jj(&["commit", "-m", "add old.txt"], &dir, &cfg);
    // Rename on disk only — the snapshot inside `working_status` is what has to notice.
    std::fs::rename(dir.join("old.txt"), dir.join("new.txt")).unwrap();

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    let files = &status.working_copy.files;
    let new = files
        .iter()
        .find(|f| f.path == "new.txt")
        .unwrap_or_else(|| panic!("new.txt missing from {files:?}"));
    assert_eq!(
        new.kind,
        wr_vcs_core::model::ChangeKind::Renamed,
        "a renamed file must not read as a plain Added; got {files:?}"
    );
    assert_eq!(
        new.old_path.as_deref(),
        Some("old.txt"),
        "the rename must carry its old path"
    );
    // The paired delete is jj-lib's to suppress — if it leaks, the panel shows the file twice.
    assert!(
        !files.iter().any(|f| f.path == "old.txt"),
        "the old path must not also appear as a separate delete; got {files:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// The same classification through `changeset` (History), not just the working copy — both callers
/// share `changed_files`, and a rename that survives an edit (≈75% similar here) still has to pair up
/// rather than fall back to delete+add.
#[test]
fn changeset_reports_a_rename_with_an_edit() {
    if common::skip_without(&["jj"], "rename-changeset test") {
        return;
    }
    let (dir, cfg) = init_repo("rename-changeset");
    std::fs::write(dir.join("old.txt"), RENAME_BODY).unwrap();
    jj(&["commit", "-m", "add old.txt"], &dir, &cfg);
    std::fs::remove_file(dir.join("old.txt")).unwrap();
    std::fs::write(
        dir.join("new.txt"),
        b"one\ntwo\nthree\nfour\nfive\nsix\nEDITED\n",
    )
    .unwrap();
    jj(&["commit", "-m", "rename with an edit"], &dir, &cfg);
    let cid = parent_id(&dir, &cfg);
    assert!(!cid.is_empty(), "could not resolve the rename commit id");

    let cs = wr_vcs_core::changeset(&dir, &cid).expect("changeset");
    let new = cs
        .files
        .iter()
        .find(|f| f.path == "new.txt")
        .unwrap_or_else(|| panic!("new.txt missing from {:?}", cs.files));
    assert_eq!(
        new.kind,
        wr_vcs_core::model::ChangeKind::Renamed,
        "an edited rename is still a rename; got {:?}",
        cs.files
    );
    assert_eq!(new.old_path.as_deref(), Some("old.txt"));
    assert!(
        !cs.files.iter().any(|f| f.path == "old.txt"),
        "no separate delete row; got {:?}",
        cs.files
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// Copy vs rename: when the source SURVIVES, the same copy record must classify as `Copied`, not
/// `Renamed` — the distinction jj-lib draws by checking whether the source is still present in the
/// target tree. The source is also modified on purpose: gix only looks for copy sources among
/// modified files (`CopySource::FromSetOfModifiedFiles`), so an untouched source yields no record at
/// all and the new file is a plain `Added`.
#[test]
fn a_surviving_source_is_copied_not_renamed() {
    if common::skip_without(&["jj"], "copy test") {
        return;
    }
    let (dir, cfg) = init_repo("copy");
    std::fs::write(dir.join("src.txt"), RENAME_BODY).unwrap();
    jj(&["commit", "-m", "add src.txt"], &dir, &cfg);
    std::fs::write(dir.join("dup.txt"), RENAME_BODY).unwrap();
    std::fs::write(
        dir.join("src.txt"),
        b"one\ntwo\nthree\nfour\nfive\nsix\nseven\nEDITED\n",
    )
    .unwrap();

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    let files = &status.working_copy.files;
    let dup = files
        .iter()
        .find(|f| f.path == "dup.txt")
        .unwrap_or_else(|| panic!("dup.txt missing from {files:?}"));
    assert_eq!(
        dup.kind,
        wr_vcs_core::model::ChangeKind::Copied,
        "a copy whose source survives must not read as Renamed; got {files:?}"
    );
    assert_eq!(dup.old_path.as_deref(), Some("src.txt"));
    // The surviving source is still its own modification — a copy suppresses nothing.
    assert!(
        files
            .iter()
            .any(|f| f.path == "src.txt" && f.kind == wr_vcs_core::model::ChangeKind::Modified),
        "the copy source is still listed as Modified; got {files:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// A conflicted path is never ALSO a rename, which is worth pinning because it's the opposite of
/// what the classifier's branch order implies. Fixture: `base` has `old.txt`; `left` edits it in
/// place; `right` renames it to `new.txt` with a different edit. `@ = jj new left right` then holds a
/// delete/modify conflict on `old.txt` plus `new.txt`.
///
/// Observed (not assumed) result: `new.txt` is a plain `Added` with NO `old_path`, and `old.txt` is
/// `Conflicted` — no pairing. The reason is the backend: copy records come from the *git* tree of each
/// commit, and jj exports a conflicted commit as its `.jjconflict-base-N`/`.jjconflict-side-N` sidecar
/// trees, so gix's rewrite detection has no plain blob at the conflicted path to match against. The
/// `Conflicted`-before-rename branch in `changed_files` is therefore defensive ordering, not a case
/// this backend can currently reach — if a future jj-lib pairs them, this test flips and the branch
/// keeps the conflict badge instead of silently downgrading it to `Renamed`.
#[test]
fn a_conflicted_rename_does_not_pair_into_one_row() {
    if common::skip_without(&["jj"], "conflicted-rename test") {
        return;
    }
    let (dir, cfg) = init_repo("conflict-rename");
    std::fs::write(dir.join("old.txt"), RENAME_BODY).unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    let base = parent_id(&dir, &cfg);
    // left: keep old.txt where it is, edit its last line.
    std::fs::write(
        dir.join("old.txt"),
        b"one\ntwo\nthree\nfour\nfive\nsix\nseven\nLEFT\n",
    )
    .unwrap();
    jj(&["commit", "-m", "left edits in place"], &dir, &cfg);
    let left = parent_id(&dir, &cfg);
    // right: rename it, with a conflicting edit on that same last line.
    jj(&["new", &base, "-m", "right renames"], &dir, &cfg);
    std::fs::remove_file(dir.join("old.txt")).unwrap();
    std::fs::write(
        dir.join("new.txt"),
        b"one\ntwo\nthree\nfour\nfive\nsix\nseven\nRIGHT\n",
    )
    .unwrap();
    jj(&["commit", "-m", "right renames"], &dir, &cfg);
    let right = parent_id(&dir, &cfg);
    jj(&["new", &left, &right], &dir, &cfg);
    assert!(
        jj_says_conflicted(&dir, &cfg),
        "fixture is not conflicted — the fixture is wrong, not the classifier"
    );

    let status = wr_vcs_core::working_status(&dir).expect("working_status");
    let files = &status.working_copy.files;
    assert!(
        files
            .iter()
            .any(|f| f.path == "old.txt" && f.kind == wr_vcs_core::model::ChangeKind::Conflicted),
        "the conflicted path must still report the conflict; got {files:?}"
    );
    let new = files
        .iter()
        .find(|f| f.path == "new.txt")
        .unwrap_or_else(|| panic!("new.txt missing from {files:?}"));
    assert_eq!(
        new.kind,
        wr_vcs_core::model::ChangeKind::Added,
        "a conflict's sidecar trees defeat rename pairing; got {files:?}"
    );
    assert_eq!(
        new.old_path, None,
        "no copy record means no old path; got {files:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn working_status_snapshots_disk_edits_without_corrupting() {
    if common::skip_without(&["jj"], "working_status test") {
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
    if common::skip_without(&["jj"], "change-id test") {
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
