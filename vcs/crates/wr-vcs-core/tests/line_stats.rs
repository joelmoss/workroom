//! Integration tests for the per-file ± line counts `changed_files` now returns, against REAL
//! throwaway jj repos. Skips if `jj` isn't on PATH — and says so out loud; see
//! `tests/common/mod.rs`.
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

mod common;

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
            ins + f.line_stats.map(|s| s.insertions).unwrap_or(0),
            del + f.line_stats.map(|s| s.deletions).unwrap_or(0),
        )
    })
}

fn working_files(dir: &Path) -> Vec<ChangedFile> {
    wr_vcs_core::working_status(dir)
        .expect("working_status")
        .working_copy
        .files
}

/// `jj_backend::MAX_COUNTED_BYTES`, mirrored because a private const can't be imported from an
/// integration test. Not a duplicate to keep in sync by hand: the two size fixtures below are built
/// *from* this value and assert they clear it, so if the backend's cap ever moves upward the fixture
/// stops being oversized and its test fails — which is exactly the right failure, since the claim
/// being pinned is "content over the cap is not counted".
const MAX_COUNTED_BYTES: usize = 4 * 1024 * 1024;

/// At least `bytes` of plain, NUL-free text, every line distinct and tagged with `marker`.
///
/// Distinct lines matter twice over: nothing here may look binary (`looks_binary` would otherwise
/// answer before the size check, and the size tests would pass without a size check existing at
/// all), and nothing may coincidentally collapse in a diff.
///
/// Lines are ~512 bytes, which is both realistic and cheap. Realistic because the files that
/// actually hit this cap are generated and minified ones — long lines are their shape. Cheap because
/// the line count, not the byte count, is what `diff_by_line` and jj's conflict merge scale on:
/// at ~80 bytes per line the conflict fixture below spent an extra second tokenizing 50k lines to
/// prove nothing the 8k-line version doesn't.
fn text_of_size(bytes: usize, marker: &str) -> Vec<u8> {
    let filler = "-".repeat(480);
    let mut out = Vec::with_capacity(bytes + 128);
    let mut n: u64 = 0;
    while out.len() < bytes {
        out.extend_from_slice(format!("{marker} line {n:012} {filler}\n").as_bytes());
        n += 1;
    }
    assert!(!out.contains(&0), "the fixture must be TEXT, not binary");
    out
}

/// The ordinary case: an edit that adds two lines and removes one.
#[test]
fn counts_match_a_simple_edit() {
    if common::skip_without(&["jj"], "simple-edit stats test") {
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
    assert_eq!(
        a.line_stats.map(|s| s.insertions),
        Some(3),
        "ONE + four + five; got {a:?}"
    );
    assert_eq!(
        a.line_stats.map(|s| s.deletions),
        Some(1),
        "the replaced `one`; got {a:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// A whole-file add and a whole-file delete count every line, on the correct side — the absent side of
/// the diff has to behave as empty content, not as "uncountable".
#[test]
fn whole_file_add_and_delete_count_every_line() {
    if common::skip_without(&["jj"], "add/delete stats test") {
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
    assert_eq!(
        (
            gone.line_stats.map(|s| s.insertions),
            gone.line_stats.map(|s| s.deletions)
        ),
        (Some(0), Some(4))
    );
    let fresh = file(&files, "fresh.txt");
    assert_eq!(fresh.kind, ChangeKind::Added);
    assert_eq!(
        (
            fresh.line_stats.map(|s| s.insertions),
            fresh.line_stats.map(|s| s.deletions)
        ),
        (Some(2), Some(0))
    );

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
    if common::skip_without(&["jj"], "merge stats test") {
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
        (arriving.line_stats.map(|s| s.insertions), arriving.line_stats.map(|s| s.deletions)),
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
    if common::skip_without(&["jj"], "conflict stats test") {
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
    let insertions = f
        .line_stats
        .map(|s| s.insertions)
        .expect("a conflicted file is still counted");
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
    if common::skip_without(&["jj"], "binary stats test") {
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
        (
            blob.line_stats.map(|s| s.insertions),
            blob.line_stats.map(|s| s.deletions)
        ),
        (None, None),
        "a binary file is not counted; got {blob:?}"
    );
    // And it doesn't poison the file beside it, or the total.
    assert_eq!(
        file(&files, "text.txt").line_stats.map(|s| s.insertions),
        Some(1)
    );
    assert_eq!(totals(&files), (1, 0));

    let _ = std::fs::remove_dir_all(&dir);
}

/// A rename with an edit counts on the ONE renamed row, and counts only the edit — not the whole file
/// twice, which is what a delete+add pair would have reported.
#[test]
fn rename_with_an_edit_counts_on_the_renamed_row() {
    if common::skip_without(&["jj"], "rename stats test") {
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
        (
            new.line_stats.map(|s| s.insertions),
            new.line_stats.map(|s| s.deletions)
        ),
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
    if common::skip_without(&["jj"], "stat-parity test") {
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

/// One unreadable BLOB degrades that one row — it must not fail the whole read.
///
/// Counting lines is what made this reachable: the tree diff `changed_files` replaced only ever read
/// tree objects, whereas materializing content reads the file's blob on both sides. jj-lib folds a
/// content failure into the same `entry.values` error as a tree failure, so treating every error as
/// `PartialData` meant a single missing object (blobless/partial clone, a pruned object, a gc/repack
/// race) took out the entire status read — and Swift maps `.partialData` to `.notRepository`, so the
/// sidebar and the Changes panel both claimed the workroom wasn't a repository at all.
///
/// The blob is deleted straight out of jj's backing git store, which is what a pruned object IS.
#[test]
fn an_unreadable_blob_degrades_one_row_not_the_whole_read() {
    // `git` as well as `jj`: the damage is inflicted with the git CLI, straight into jj's store.
    if common::skip_without(&["jj", "git"], "unreadable-blob test") {
        return;
    }
    let (dir, cfg) = init_repo("unreadable-blob");
    std::fs::write(dir.join("a.txt"), b"one\ntwo\nthree\n").unwrap();
    std::fs::write(dir.join("b.txt"), b"untouched\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    std::fs::write(dir.join("a.txt"), b"ONE\ntwo\nthree\nfour\n").unwrap();
    std::fs::write(dir.join("b.txt"), b"untouched\nplus one\n").unwrap();

    // jj's backing git repo, via the `git_target` pointer rather than a hardcoded path (it's
    // relative to the store dir, and differs between a colocated repo and this one).
    let store_dir = dir.join(".jj/repo/store");
    let target = std::fs::read_to_string(store_dir.join("git_target")).unwrap();
    let store = std::fs::canonicalize(store_dir.join(target.trim())).unwrap();
    let git = |args: &[&str]| {
        Command::new("git")
            .arg("--git-dir")
            .arg(&store)
            .args(args)
            .output()
            .unwrap_or_else(|e| panic!("run git {args:?}: {e}"))
    };
    // `ls-tree`, not `rev-parse <commit>:a.txt` — with no work tree, rev-parse reads that form as a
    // path and fails. Output is `<mode> blob <sha>\t<path>`.
    let parent = id_of("@-", &dir, &cfg);
    let listed = git(&["ls-tree", &parent, "a.txt"]);
    let listed = String::from_utf8_lossy(&listed.stdout);
    let blob = listed.split_whitespace().nth(2).unwrap_or_default();
    assert_eq!(
        blob.len(),
        40,
        "could not resolve the parent blob for a.txt from {listed:?}"
    );
    let object = store.join("objects").join(&blob[..2]).join(&blob[2..]);
    assert!(object.exists(), "expected a loose object at {object:?}");
    std::fs::remove_file(&object).unwrap();

    let status =
        wr_vcs_core::working_status(&dir).expect("one missing blob must not fail the read");
    assert!(status.is_dirty(), "the working copy is still dirty");
    let files = status.working_copy.files;

    // The damaged file keeps its row and its real kind; only the counts go missing — which is
    // already what `None` means here (binary, oversized, unreadable).
    let a = file(&files, "a.txt");
    assert_eq!(a.kind, ChangeKind::Modified, "kind survives; got {a:?}");
    assert_eq!(
        (
            a.line_stats.map(|s| s.insertions),
            a.line_stats.map(|s| s.deletions)
        ),
        (None, None),
        "an unreadable blob can't be counted; got {a:?}"
    );
    // …and the file beside it is unaffected, counts included.
    let b = file(&files, "b.txt");
    assert_eq!(
        (
            b.line_stats.map(|s| s.insertions),
            b.line_stats.map(|s| s.deletions)
        ),
        (Some(1), Some(0)),
        "got {b:?}"
    );
    assert_eq!(totals(&files), (1, 0));

    let _ = std::fs::remove_dir_all(&dir);
}

/// A plain TEXT file over `MAX_COUNTED_BYTES` reports `None`, exactly like a binary one.
///
/// The size arm had no coverage at all — `binary_file_reports_no_counts` exercises the other
/// predicate in the same `if`, so inverting the comparison (`<` for `>`), dropping it, or quietly
/// raising the cap all shipped green. Text, with no NUL anywhere, is the whole point: a binary
/// oversized fixture would be rejected by `looks_binary` first and prove nothing about the size.
///
/// The file is committed SMALL and then grown on disk, which is not incidental. Our snapshot (and
/// the jj CLI's) refuses to start tracking a *new* file over 1 MiB — `SnapshotOptions`'
/// `max_new_file_size`, the CLI's own `snapshot.max-new-file-size` default — so a born-oversized
/// fixture would never be tracked and never reach the diff at all. jj's gate applies only to files
/// it isn't already tracking, so growing a tracked one is snapshotted without complaint.
#[test]
fn a_text_file_over_the_size_cap_reports_no_counts() {
    if common::skip_without(&["jj"], "oversized-text stats test") {
        return;
    }
    let (dir, cfg) = init_repo("oversized");
    std::fs::write(dir.join("huge.txt"), text_of_size(64 * 1024, "seed")).unwrap();
    std::fs::write(dir.join("small.txt"), b"hello\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);

    // A quarter over the cap: clear of it by megabytes, so this can never turn into an off-by-one
    // test, and clear enough that a modest future raise of the cap fails loudly rather than subtly.
    let huge = text_of_size(MAX_COUNTED_BYTES + MAX_COUNTED_BYTES / 4, "grown");
    assert!(
        huge.len() > MAX_COUNTED_BYTES,
        "fixture ({} bytes) must exceed the cap ({MAX_COUNTED_BYTES} bytes) — if the backend raised \
         it, raise this fixture too",
        huge.len()
    );
    std::fs::write(dir.join("huge.txt"), &huge).unwrap();
    std::fs::write(dir.join("small.txt"), b"hello\nworld\n").unwrap();

    let files = working_files(&dir);
    let big = file(&files, "huge.txt");
    assert_eq!(
        big.kind,
        ChangeKind::Modified,
        "an oversized file is still a listed change; got {big:?}"
    );
    assert_eq!(
        (
            big.line_stats.map(|s| s.insertions),
            big.line_stats.map(|s| s.deletions)
        ),
        (None, None),
        "over the cap is not counted — `None`, never a partial count from the truncated read; got \
         {big:?}"
    );
    // And it poisons neither its neighbour nor the header total.
    assert_eq!(
        file(&files, "small.txt").line_stats.map(|s| s.insertions),
        Some(1)
    );
    assert_eq!(totals(&files), (1, 0));

    let _ = std::fs::remove_dir_all(&dir);
}

/// One side of the conflict fixture below. Under the cap on its own, deliberately — see the test.
const CONFLICT_SIDE_BYTES: usize = (MAX_COUNTED_BYTES / 8) * 3;

/// The two properties the conflict fixture's design rests on, checked at COMPILE time — they're
/// constants, so this is a build error rather than a test failure if either ever flips (and clippy
/// rightly refuses a runtime `assert!` on a constant). Between them they say: no single side can be
/// the reason the counts come back `None`, but the materialized markers that embed all three must
/// be. Get the first wrong and the plain `File` arm answers for the before-side, the conflict arm is
/// never consulted, and the test passes with the code under test deleted — which is exactly what the
/// first draft of it did.
const _: () = {
    assert!(
        CONFLICT_SIDE_BYTES < MAX_COUNTED_BYTES,
        "each conflict side must be UNDER the cap on its own"
    );
    assert!(
        3 * CONFLICT_SIDE_BYTES > MAX_COUNTED_BYTES,
        "…but the three sides the materialized markers embed must together exceed it"
    );
};

/// A CONFLICTED file whose MATERIALIZED text is over the cap reports `None` too — the arm that had no
/// size check at all.
///
/// `conflicted_file_counts_its_materialized_markers` pins the opposite for a small conflict (it IS
/// counted, markers and all), so until now the conflict arm's only bound was `looks_binary`: a
/// multi-megabyte conflicted lockfile got read, merged and line-diffed whole on every 15s status
/// sweep, per workroom.
///
/// **The fixture's whole design is about not testing the wrong arm.** `line_stats` short-circuits on
/// the FIRST side that yields `None`, and the *before* side here is a plain `File` — `@`'s first
/// parent, `left`. Sizing the sides at 4 MiB each (the obvious way to build an oversized conflict)
/// makes `left` alone breach the cap, so the `File` arm answers, the conflict arm is never consulted,
/// and the test passes whether or not the check under test exists. Confirmed the hard way: the first
/// draft did exactly that and stayed green with the check deleted.
///
/// So each side is kept comfortably UNDER the cap, and it's their SUM that goes over: with all three
/// sides mutually different, the whole file is one conflicting region, and a materialized region
/// carries every side (`marker-style = "diff"` renders base→left as a diff, then right in full).
/// Three × 1.5 MiB ⇒ ~4.5 MiB of markers out of 1.5 MiB inputs — only the conflict arm can see that.
#[test]
fn a_conflicted_file_over_the_size_cap_reports_no_counts() {
    if common::skip_without(&["jj"], "oversized-conflict stats test") {
        return;
    }
    let (dir, cfg) = init_repo("oversized-conflict");
    // Track both files while they're small (see the `max_new_file_size` note above), then grow
    // `f.txt` in a commit of its own — that commit is the conflict's base.
    std::fs::write(dir.join("f.txt"), b"seed\n").unwrap();
    std::fs::write(dir.join("note.txt"), b"one\n").unwrap();
    jj(&["commit", "-m", "seed"], &dir, &cfg);

    // Three mutually different bodies: every line differs on every side, so the merge finds no
    // common ground and the conflicting region is the entire file.
    std::fs::write(dir.join("f.txt"), text_of_size(CONFLICT_SIDE_BYTES, "base")).unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    let base = id_of("@-", &dir, &cfg);

    std::fs::write(dir.join("f.txt"), text_of_size(CONFLICT_SIDE_BYTES, "left")).unwrap();
    jj(&["commit", "-m", "left"], &dir, &cfg);
    let left = id_of("@-", &dir, &cfg);
    // By commit id, never by bookmark — `experimental-advance-branches` would otherwise collapse the
    // two sides and leave no merge (the same reason the other merge fixtures here do this).
    jj(&["new", &base, "-m", "right"], &dir, &cfg);
    std::fs::write(
        dir.join("f.txt"),
        text_of_size(CONFLICT_SIDE_BYTES, "right"),
    )
    .unwrap();
    jj(&["commit", "-m", "right"], &dir, &cfg);
    let right = id_of("@-", &dir, &cfg);
    jj(&["new", &left, &right], &dir, &cfg);
    // An ordinary edit alongside it, so "nothing was counted" can't be trivially true of the read.
    std::fs::write(dir.join("note.txt"), b"one\ntwo\n").unwrap();

    let files = working_files(&dir);
    let f = file(&files, "f.txt");
    assert_eq!(
        f.kind,
        ChangeKind::Conflicted,
        "the fixture must actually be conflicted, or this measures nothing; got {files:?}"
    );
    assert_eq!(
        (
            f.line_stats.map(|s| s.insertions),
            f.line_stats.map(|s| s.deletions)
        ),
        (None, None),
        "an oversized conflict is not counted, materialized markers or not; got {f:?}"
    );
    assert_eq!(
        file(&files, "note.txt").line_stats.map(|s| s.insertions),
        Some(1)
    );
    assert_eq!(totals(&files), (1, 0));

    let _ = std::fs::remove_dir_all(&dir);
}

/// Symlink entries report `None`: there is no file content to diff, only a target string.
///
/// `side_content` groups `Symlink` with `Tree`/`GitSubmodule`/`OtherConflict`/`AccessDenied` in a
/// single `None` arm, and nothing pinned that. `Symlink` is the plausible one to lose — its `target`
/// is right there in the value, and "count the target as one line" reads like a fix — so moving it
/// into a counting arm would have shipped green.
///
/// Both shapes are covered because they reach `side_content` differently: a RETARGETED link is
/// `Symlink → Symlink`, while a NEW link is `Absent → Symlink`, and only the second proves the
/// `Absent` arm's "empty content" answer doesn't rescue an uncountable other side (`line_stats`
/// short-circuits on the FIRST `None`, so a regression could easily be visible on one and not the
/// other).
///
/// Unix-only: a symlink is the subject, and `std::os::unix::fs::symlink` is how you make one on the
/// two platforms this crate is built for (macOS locally, Linux on CI).
#[cfg(unix)]
#[test]
fn symlink_changes_report_no_counts() {
    if common::skip_without(&["jj"], "symlink stats test") {
        return;
    }
    let (dir, cfg) = init_repo("symlink");
    std::fs::write(dir.join("a.txt"), b"a\n").unwrap();
    std::fs::write(dir.join("b.txt"), b"b\n").unwrap();
    std::fs::write(dir.join("c.txt"), b"one\n").unwrap();
    std::os::unix::fs::symlink("a.txt", dir.join("link")).unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);

    // Retarget the tracked link, add a brand-new one, and make one ordinary edit beside them — the
    // edit is what keeps "nothing was counted" from being trivially true of the whole read.
    std::fs::remove_file(dir.join("link")).unwrap();
    std::os::unix::fs::symlink("b.txt", dir.join("link")).unwrap();
    std::os::unix::fs::symlink("a.txt", dir.join("fresh")).unwrap();
    std::fs::write(dir.join("c.txt"), b"one\ntwo\n").unwrap();

    let files = working_files(&dir);
    let link = file(&files, "link");
    assert_eq!(
        link.kind,
        ChangeKind::Modified,
        "a retargeted symlink is still a listed change; got {link:?}"
    );
    assert_eq!(
        (
            link.line_stats.map(|s| s.insertions),
            link.line_stats.map(|s| s.deletions)
        ),
        (None, None),
        "a symlink has a target, not lines; got {link:?}"
    );
    let fresh = file(&files, "fresh");
    assert_eq!(
        fresh.kind,
        ChangeKind::Added,
        "a new symlink is an Added row; got {fresh:?}"
    );
    assert_eq!(
        (
            fresh.line_stats.map(|s| s.insertions),
            fresh.line_stats.map(|s| s.deletions)
        ),
        (None, None),
        "an absent before-side must not rescue an uncountable after-side; got {fresh:?}"
    );
    assert_eq!(
        file(&files, "c.txt").line_stats.map(|s| s.insertions),
        Some(1)
    );
    assert_eq!(totals(&files), (1, 0));

    let _ = std::fs::remove_dir_all(&dir);
}

// The fourth `None` producer, `MaterializedTreeValue::AccessDenied`, is deliberately NOT tested
// here, because reaching it would cost more truth than it buys. In jj-lib 0.43.0 the only source of
// the `BackendError::ReadAccessDenied` it wraps is `secret_backend.rs` ("Provides a backend for
// testing ACLs") — the git and simple backends never produce it — and `StoreFactories::default()`,
// which is what `open`/`snapshot_working_copy` pass, registers that backend only under jj-lib's
// `testing` feature. Turning that on would mean:
//
//   1. `jj-lib = { features = ["testing"] }` in dev-dependencies, which feature-unifies across every
//      dev-profile build (`cargo check --all-targets`, `clippy`, `test`) — so the jj-lib under test
//      would be configured differently from the jj-lib we ship;
//   2. a fixture that overwrites `.jj/repo/store/type` with "secret", which makes the repo
//      unreadable by the `jj` CLI every other fixture in this file cross-checks against.
//
// The arm is also the least losable of the four: unlike `Symlink`, an `AccessDenied` value carries
// no content anyone could plausibly decide to count, and deleting the arm outright is a
// non-exhaustive `match` — a compile error, not a silent regression.
