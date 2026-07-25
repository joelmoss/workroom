//! Integration tests for the per-file ± line counts `changed_files` now returns, against REAL
//! throwaway jj repos. Skips if `jj` isn't on PATH.
//!
//! These counts used to be added app-side from a SECOND read — one `jj diff -r @ --stat` process,
//! run after the native file list. Three separate defects came out of that split, and the tests below
//! pin each one:
//!
//! 1. `-r @` on a **merge** diffs the auto-merged parents, while the file list is a tree diff against
//!    the FIRST parent — so the totals described a different set of files than the rows beside them.
//!    A single-parent fixture cannot expose this (the two bases coincide), so
//!    `merge_working_copy_counts_against_the_first_parent` needs a real merge — and it asserts jj's own
//!    `-r @` number to show the old path really was wrong, not just differently derived.
//! 2. Two reads of a moving working copy can disagree; counts now come from the same snapshot as the
//!    list, which is what `counts_match_jj_diff_stat_for_a_linear_working_copy` measures against jj.
//! 3. A conflicted file's materialized markers count as changed lines. That is *kept* — it's what jj
//!    and git both report for the same state — and pinned here so the app's "counts include conflict
//!    markers" wording stays true.
//!
//! `working_status` MUTATES (working-copy lock → snapshot → rewrite `@`), so every fixture is a
//! throwaway dir under the temp dir, never a real repo.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use wr_vcs_core::model::ChangeKind;
use wr_vcs_core::model::ChangedFile;

fn have_jj() -> bool {
    Command::new("jj")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Run `jj` in `dir` with `config` as its ONLY config file. Passed per-`Command` rather than through
/// `std::env::set_var`, which would race the other tests in this parallel process.
fn jj(args: &[&str], dir: &Path, config: &Path) -> std::process::Output {
    Command::new("jj")
        .args(args)
        .current_dir(dir)
        .env("JJ_CONFIG", config)
        .output()
        .unwrap_or_else(|e| panic!("run jj {args:?}: {e}"))
}

/// A fresh throwaway repo: unique dir, isolated jj config (supplying an author so snapshot operations
/// can commit), `jj git init` run.
fn init_repo(tag: &str) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("wr-stats-{}-{}", std::process::id(), tag));
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

fn id_of(rev: &str, dir: &Path, cfg: &Path) -> String {
    let out = jj(
        &[
            "log",
            "-r",
            rev,
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
    let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
    assert!(!id.is_empty(), "could not resolve {rev}");
    id
}

/// jj's OWN totals for a diff, parsed from `jj diff --stat`'s summary line — the exact string the app
/// used to parse app-side. Used here as the cross-check that our native fold agrees with jj where it
/// should, and disagrees where jj is answering a different question (`-r @` on a merge).
fn jj_stat_totals(args: &[&str], dir: &Path, cfg: &Path) -> (u32, u32) {
    let mut full = vec!["diff"];
    full.extend_from_slice(args);
    full.extend_from_slice(&["--ignore-working-copy", "--stat", "--color", "never"]);
    let out = jj(&full, dir, cfg);
    let text = String::from_utf8_lossy(&out.stdout);
    let summary = text.lines().last().unwrap_or_default();
    let count = |suffix: &str| -> u32 {
        summary
            .split(", ")
            .find(|part| part.contains(suffix))
            .and_then(|part| part.split_whitespace().next())
            .and_then(|n| n.parse().ok())
            .unwrap_or(0)
    };
    (count("insertion"), count("deletion"))
}

fn file<'a>(files: &'a [ChangedFile], path: &str) -> &'a ChangedFile {
    files
        .iter()
        .find(|f| f.path == path)
        .unwrap_or_else(|| panic!("{path} missing from {files:?}"))
}

/// Sum the rows the way the app's Changes header does. Files with `None` counts (binary, oversized,
/// non-file) contribute nothing, matching how git and jj both leave binaries out of a diffstat.
fn totals(files: &[ChangedFile]) -> (u32, u32) {
    files.iter().fold((0, 0), |(ins, del), f| {
        (
            ins + f.insertions.unwrap_or(0),
            del + f.deletions.unwrap_or(0),
        )
    })
}

fn working_files(dir: &Path) -> Vec<ChangedFile> {
    wr_vcs_core::working_status(dir)
        .expect("working_status")
        .working_copy
        .files
}

/// The ordinary case: an edit that adds two lines and removes one.
#[test]
fn counts_match_a_simple_edit() {
    if !have_jj() {
        eprintln!("skipping simple-edit stats test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("simple");
    std::fs::write(dir.join("a.txt"), b"one\ntwo\nthree\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    // one → ONE (a modified line is one deletion + one insertion), plus two appended lines.
    std::fs::write(dir.join("a.txt"), b"ONE\ntwo\nthree\nfour\nfive\n").unwrap();

    let files = working_files(&dir);
    let a = file(&files, "a.txt");
    assert_eq!(a.kind, ChangeKind::Modified);
    assert_eq!(a.insertions, Some(3), "ONE + four + five; got {a:?}");
    assert_eq!(a.deletions, Some(1), "the replaced `one`; got {a:?}");

    let _ = std::fs::remove_dir_all(&dir);
}

/// A whole-file add and a whole-file delete count every line, on the correct side — the absent side of
/// the diff has to behave as empty content, not as "uncountable".
#[test]
fn whole_file_add_and_delete_count_every_line() {
    if !have_jj() {
        eprintln!("skipping add/delete stats test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("add-delete");
    std::fs::write(dir.join("gone.txt"), b"1\n2\n3\n4\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    std::fs::remove_file(dir.join("gone.txt")).unwrap();
    std::fs::write(dir.join("fresh.txt"), b"a\nb\n").unwrap();

    let files = working_files(&dir);
    let gone = file(&files, "gone.txt");
    assert_eq!(gone.kind, ChangeKind::Deleted);
    assert_eq!((gone.insertions, gone.deletions), (Some(0), Some(4)));
    let fresh = file(&files, "fresh.txt");
    assert_eq!(fresh.kind, ChangeKind::Added);
    assert_eq!((fresh.insertions, fresh.deletions), (Some(2), Some(0)));

    let _ = std::fs::remove_dir_all(&dir);
}

/// **The merge defect.** `@` is a clean 2-sided merge: `left` edited `a.txt`, `right` added
/// `right.txt`. The file list diffs `@` against its FIRST parent (`left`), so `right.txt` is listed —
/// and its lines must be counted.
///
/// jj's `jj diff -r @` answers a different question (the diff against the auto-merged parents, which
/// for a clean merge with no working-copy edits is EMPTY), and that is the number the app used to put
/// next to these rows. Asserting both here is what makes this a regression test rather than a
/// tautology: ours is non-zero, jj's `-r @` is zero, and ours equals jj's own first-parent-anchored
/// stat.
#[test]
fn merge_working_copy_counts_against_the_first_parent() {
    if !have_jj() {
        eprintln!("skipping merge stats test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("merge");
    std::fs::write(dir.join("a.txt"), b"one\ntwo\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    let base = id_of("@-", &dir, &cfg);
    // left: edit a.txt
    std::fs::write(dir.join("a.txt"), b"ONE\ntwo\n").unwrap();
    jj(&["commit", "-m", "left"], &dir, &cfg);
    let left = id_of("@-", &dir, &cfg);
    // right: add a new file. Addressed by COMMIT ID, never by bookmark — with
    // `experimental-advance-branches` on, `jj commit` would advance a bookmark onto the new commit and
    // collapse the two sides into one, leaving no merge at all.
    jj(&["new", &base, "-m", "right"], &dir, &cfg);
    std::fs::write(dir.join("right.txt"), b"r1\nr2\nr3\n").unwrap();
    jj(&["commit", "-m", "right"], &dir, &cfg);
    let right = id_of("@-", &dir, &cfg);
    jj(&["new", &left, &right], &dir, &cfg);

    let files = working_files(&dir);
    let arriving = file(&files, "right.txt");
    assert_eq!(
        (arriving.insertions, arriving.deletions),
        (Some(3), Some(0)),
        "a file arriving from the merge's other side is listed, so it must be counted; got {arriving:?}"
    );

    // The old app-side read, still reproducible through the CLI: zero, next to a row that has three
    // added lines.
    assert_eq!(
        jj_stat_totals(&["-r", "@"], &dir, &cfg),
        (0, 0),
        "`-r @` on a merge is the wrong base — if this ever stops being 0, re-derive this test"
    );
    // …and the base the file list actually uses agrees with us.
    assert_eq!(
        totals(&files),
        jj_stat_totals(&["--from", &left, "--to", "@"], &dir, &cfg),
        "our totals must match jj's own first-parent-anchored stat; got {files:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// A conflicted file counts its MATERIALIZED marker text. Deliberate, and load-bearing for the app's
/// header wording: git reports the same inflation for a conflicted worktree (the markers are really on
/// disk) and our own commit path already asserts it (`VCSProviderConformanceTests`), so suppressing it
/// on jj alone would make the two backends disagree. What the app does instead is SAY so.
///
/// Also a corruption guard: the counting read materializes conflict content, and the conflict must
/// still be a conflict afterwards.
#[test]
fn conflicted_file_counts_its_materialized_markers() {
    if !have_jj() {
        eprintln!("skipping conflict stats test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("conflict");
    std::fs::write(dir.join("f.txt"), b"base\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    let base = id_of("@-", &dir, &cfg);
    std::fs::write(dir.join("f.txt"), b"left\n").unwrap();
    jj(&["commit", "-m", "left"], &dir, &cfg);
    let left = id_of("@-", &dir, &cfg);
    jj(&["new", &base, "-m", "right"], &dir, &cfg);
    std::fs::write(dir.join("f.txt"), b"right\n").unwrap();
    jj(&["commit", "-m", "right"], &dir, &cfg);
    let right = id_of("@-", &dir, &cfg);
    jj(&["new", &left, &right], &dir, &cfg);

    let files = working_files(&dir);
    let f = file(&files, "f.txt");
    assert_eq!(f.kind, ChangeKind::Conflicted);
    let insertions = f.insertions.expect("a conflicted file is still counted");
    assert!(
        insertions > 1,
        "the marker text is the file's content, so a 1-line conflict counts more than 1 line; got {f:?}"
    );

    // The conflict survives being counted (the same no-corruption guard the classification suite has).
    let again = working_files(&dir);
    assert_eq!(
        file(&again, "f.txt").kind,
        ChangeKind::Conflicted,
        "counting must not resolve or flatten the conflict"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// A binary file reports `None`, not a garbage line count — the distinction the `Option` exists for.
/// `None` is not zero: zero would claim "changed nothing".
#[test]
fn binary_file_reports_no_counts() {
    if !have_jj() {
        eprintln!("skipping binary stats test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("binary");
    std::fs::write(dir.join("blob.bin"), [0x00, 0x01, 0x02, 0x00, 0xff]).unwrap();
    std::fs::write(dir.join("text.txt"), b"hello\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    std::fs::write(dir.join("blob.bin"), [0x00, 0x09, 0x09, 0x00, 0xfe, 0x01]).unwrap();
    std::fs::write(dir.join("text.txt"), b"hello\nworld\n").unwrap();

    let files = working_files(&dir);
    let blob = file(&files, "blob.bin");
    assert_eq!(blob.kind, ChangeKind::Modified, "still a listed change");
    assert_eq!(
        (blob.insertions, blob.deletions),
        (None, None),
        "a binary file is not counted; got {blob:?}"
    );
    // And it doesn't poison the file beside it, or the total.
    assert_eq!(file(&files, "text.txt").insertions, Some(1));
    assert_eq!(totals(&files), (1, 0));

    let _ = std::fs::remove_dir_all(&dir);
}

/// A rename with an edit counts on the ONE renamed row, and counts only the edit — not the whole file
/// twice, which is what a delete+add pair would have reported.
#[test]
fn rename_with_an_edit_counts_on_the_renamed_row() {
    if !have_jj() {
        eprintln!("skipping rename stats test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("rename");
    // Similar enough for gix's rewrite detection (≥50%) to pair the two paths after the edit.
    std::fs::write(
        dir.join("old.txt"),
        b"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n",
    )
    .unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    std::fs::remove_file(dir.join("old.txt")).unwrap();
    std::fs::write(
        dir.join("new.txt"),
        b"one\ntwo\nthree\nfour\nfive\nsix\nseven\nEIGHT\n",
    )
    .unwrap();

    let files = working_files(&dir);
    let new = file(&files, "new.txt");
    assert_eq!(new.kind, ChangeKind::Renamed);
    assert_eq!(new.old_path.as_deref(), Some("old.txt"));
    assert_eq!(
        (new.insertions, new.deletions),
        (Some(1), Some(1)),
        "only the edited line, counted once; got {new:?}"
    );
    assert!(
        !files.iter().any(|f| f.path == "old.txt"),
        "the rename is one row, so there is nothing to double-count; got {files:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// Parity with the tool: for an ordinary single-parent working copy our totals must equal what
/// `jj diff --stat` prints, since that is the number this replaced. Covers the pieces most likely to
/// drift from jj's own counting — a file with no trailing newline, and a mixed edit.
#[test]
fn counts_match_jj_diff_stat_for_a_linear_working_copy() {
    if !have_jj() {
        eprintln!("skipping stat-parity test: `jj` not on PATH");
        return;
    }
    let (dir, cfg) = init_repo("parity");
    std::fs::write(dir.join("a.txt"), b"one\ntwo\nthree\n").unwrap();
    std::fs::write(dir.join("b.txt"), b"no trailing newline").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    std::fs::write(dir.join("a.txt"), b"one\nTWO\nthree\nfour\n").unwrap();
    std::fs::write(dir.join("b.txt"), b"still no trailing newline").unwrap();
    std::fs::write(dir.join("c.txt"), b"new file\n").unwrap();

    let files = working_files(&dir);
    let ours = totals(&files);
    assert_ne!(ours, (0, 0), "guard against passing vacuously: {files:?}");
    assert_eq!(
        ours,
        jj_stat_totals(&["-r", "@"], &dir, &cfg),
        "our fold must agree with jj's own diffstat on a linear @; got {files:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
