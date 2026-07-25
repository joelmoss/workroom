//! Integration tests for the ORDER of the jj backend's two ancestry walks — `log_page` (History) and
//! `nearest_bookmark` (the sidebar's branch label, via `current_ref`) — against REAL throwaway jj
//! repos. Read-only reads (`load_at_head`, no working-copy lock), so unlike the `working_status` suite
//! there's no corruption risk. Skips if `jj` isn't on PATH.
//!
//! Both walks used to be keyed on the **committer timestamp**. That is metadata, not graph structure:
//! a rewrite carries it forward, so an amend, a rebase, an imported git commit or plain clock skew
//! moves it out of graph order. jj itself never orders by it — the default index iterates in
//! descending commit position, which is topological.
//!
//! Every fixture here therefore needs TWO things, and a test missing either passes against the buggy
//! code:
//!
//! 1. **Out-of-order committer timestamps**, forced with `JJ_TIMESTAMP` (jj maps it onto
//!    `debug.commit-timestamp`). Real repos get this for free from fetched git history and clock skew.
//! 2. **A merge**, so the two walks actually have a choice to get wrong. Along a LINEAR ancestry a
//!    frontier of one is all either walk ever sees, so timestamps can be arbitrarily scrambled and the
//!    output is still identical — which is why the skew went unnoticed.

use std::path::{Path, PathBuf};
use std::process::Command;

use wr_vcs_model::{Commit, HistoryPage, RefKind};

fn have_jj() -> bool {
    Command::new("jj")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Run `jj` in `dir` with `config` as its ONLY config file, and `stamp` as the committer timestamp of
/// anything it writes.
///
/// Both are passed per-`Command`, never through `std::env::set_var`: cargo runs `#[test]`s in parallel
/// threads of one process, so a global env write is visible to (and racing with) every other test —
/// and here the whole point is that neighbouring commands use *different* timestamps.
fn jj_at(args: &[&str], dir: &Path, config: &Path, stamp: &str) -> std::process::Output {
    let out = Command::new("jj")
        .args(args)
        .current_dir(dir)
        .env("JJ_CONFIG", config)
        .env("JJ_TIMESTAMP", stamp)
        .output()
        .unwrap_or_else(|e| panic!("run jj {args:?}: {e}"));
    assert!(
        out.status.success(),
        "jj {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

/// `jj_at` for commands that only read (or whose timestamp is irrelevant).
fn jj(args: &[&str], dir: &Path, config: &Path) -> std::process::Output {
    jj_at(args, dir, config, "2020-06-01T00:00:00Z")
}

/// A fresh throwaway repo: unique dir, isolated jj config (also supplying an author), `jj git init`.
fn init_repo(tag: &str) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("wr-order-{}-{}", std::process::id(), tag));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("jjconfig.toml");
    std::fs::write(
        &config,
        b"[user]\nname = \"Test\"\nemail = \"test@example.com\"\n",
    )
    .unwrap();
    jj(&["git", "init"], &dir, &config);
    (dir, config)
}

/// The commit id of `rev`, as hex.
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
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// jj's OWN ordering of `::@`, as commit-id hexes newest-first — the reference every ordering claim
/// here is measured against. `--ignore-working-copy` so reading can't perturb what it reports.
fn jj_log_ids(dir: &Path, cfg: &Path) -> Vec<String> {
    let out = jj(
        &[
            "log",
            "-r",
            "::@",
            "--no-graph",
            "--ignore-working-copy",
            "--color",
            "never",
            "-T",
            "commit_id ++ \"\\n\"",
        ],
        dir,
        cfg,
    );
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

/// A repo whose graph and whose committer timestamps disagree, with the newest timestamp on the
/// commit FURTHEST from `@`:
///
/// ```text
///   root ── A(2030, bookmark "deep") ─┬─ B(2019) ── C(2020, bookmark "main") ─┐
///                                     └─ E(2021) ─────────────────────────────┴─ @ = merge(C, E)
/// ```
///
/// Read it as two claims the timestamp walks both got wrong:
///
/// - **History order.** Popping newest-timestamp-first reaches `A` (2030) straight after `E` (2021),
///   i.e. BEFORE `A`'s own descendants `C` and `B` — a parent printed above its child, which no
///   topological order permits and `jj log` never prints.
/// - **Branch label.** The nearest bookmark to `@` is `main`, sitting on `@`'s own first parent `C`.
///   The timestamp walk instead surfaces `deep` on `A`, two hops away, purely because a rewrite left
///   `A` with a later timestamp.
///
/// The sides are addressed by **commit id**, never by bookmark: with jj's
/// `experimental-advance-branches` enabled, `jj commit` advances a bookmark onto the commit it just
/// created, which would collapse the two sides and destroy the merge. (`init_repo`'s isolated
/// `JJ_CONFIG` already keeps that setting out of these tests, but ids don't depend on it.)
fn skewed_merge_repo(tag: &str) -> (PathBuf, PathBuf) {
    let (dir, cfg) = init_repo(tag);

    std::fs::write(dir.join("a.txt"), b"a\n").unwrap();
    jj_at(&["commit", "-m", "A"], &dir, &cfg, "2030-01-01T00:00:00Z");
    let a = id_of("@-", &dir, &cfg);

    std::fs::write(dir.join("b.txt"), b"b\n").unwrap();
    jj_at(&["commit", "-m", "B"], &dir, &cfg, "2019-01-01T00:00:00Z");

    std::fs::write(dir.join("c.txt"), b"c\n").unwrap();
    jj_at(&["commit", "-m", "C"], &dir, &cfg, "2020-01-01T00:00:00Z");
    let c = id_of("@-", &dir, &cfg);

    jj(&["new", &a], &dir, &cfg);
    std::fs::write(dir.join("e.txt"), b"e\n").unwrap();
    jj_at(&["commit", "-m", "E"], &dir, &cfg, "2021-01-01T00:00:00Z");
    let e = id_of("@-", &dir, &cfg);

    jj(&["new", &c, &e], &dir, &cfg);
    jj(&["bookmark", "create", "deep", "-r", &a], &dir, &cfg);
    jj(&["bookmark", "create", "main", "-r", &c], &dir, &cfg);
    (dir, cfg)
}

fn page(root: &Path, limit: usize) -> HistoryPage {
    wr_vcs_core::log_page(root, limit).expect("log_page")
}

fn summaries(commits: &[Commit]) -> Vec<&str> {
    commits.iter().map(|c| c.summary.as_str()).collect()
}

/// Every commit must appear BEFORE each of its parents that is also on the page. This is the whole
/// definition of the order `log_page` promises, and it needs no reference implementation to check.
fn assert_children_before_parents(commits: &[Commit]) {
    let position = |id: &str| commits.iter().position(|c| c.commit_id == id);
    for (i, commit) in commits.iter().enumerate() {
        for parent in &commit.parent_ids {
            if let Some(j) = position(parent) {
                assert!(
                    j > i,
                    "parent {parent} of {} is at {j}, before its child at {i} — not a topological \
                     order: {:?}",
                    commit.commit_id,
                    summaries(commits)
                );
            }
        }
    }
}

#[test]
fn log_page_puts_children_before_parents_despite_newer_ancestor_timestamps() {
    if !have_jj() {
        eprintln!("skipping: jj not on PATH");
        return;
    }
    let (dir, _cfg) = skewed_merge_repo("logtopo");
    let page = page(&dir, 20);
    assert_children_before_parents(&page.commits);

    // Spelled out, so a failure names the bug rather than just the invariant: `A` carries the newest
    // timestamp in the repo, and used to be popped before the two commits descended from it.
    let at = |summary: &str| {
        summaries(&page.commits)
            .iter()
            .position(|s| *s == summary)
            .unwrap_or_else(|| panic!("no {summary:?} in {:?}", summaries(&page.commits)))
    };
    assert!(
        at("C") < at("A"),
        "C descends from A, so it must come first"
    );
    assert!(
        at("B") < at("A"),
        "B descends from A, so it must come first"
    );
}

#[test]
fn log_page_order_matches_jj_log() {
    if !have_jj() {
        eprintln!("skipping: jj not on PATH");
        return;
    }
    let (dir, cfg) = skewed_merge_repo("logparity");
    let ours: Vec<String> = page(&dir, 20)
        .commits
        .iter()
        .map(|c| c.commit_id.clone())
        .collect();
    assert_eq!(
        ours,
        jj_log_ids(&dir, &cfg),
        "History must list `::@` in the same order as `jj log -r ::@`"
    );
}

/// The `reached_end` flag and the page cut are computed by reading ONE id past the page, so they get
/// their own guard: a short page must not claim to be the end, and an over-long limit must.
#[test]
fn log_page_reports_reached_end_only_when_the_page_holds_everything() {
    if !have_jj() {
        eprintln!("skipping: jj not on PATH");
        return;
    }
    let (dir, cfg) = skewed_merge_repo("logpaging");
    let all = jj_log_ids(&dir, &cfg).len();
    assert!(
        all > 3,
        "fixture should have more than 3 commits, got {all}"
    );

    let short = page(&dir, 3);
    assert_eq!(short.commits.len(), 3);
    assert!(!short.reached_end, "3 of {all} commits is not the end");
    // Truncating must not reorder: the short page is the prefix of the full one.
    let full = page(&dir, 20);
    assert_eq!(full.commits.len(), all);
    assert!(full.reached_end, "a page of {all} covers the whole history");
    assert_eq!(summaries(&short.commits), summaries(&full.commits)[..3]);
}

#[test]
fn current_ref_picks_the_nearest_bookmark_not_the_newest_timestamped_one() {
    if !have_jj() {
        eprintln!("skipping: jj not on PATH");
        return;
    }
    let (dir, _cfg) = skewed_merge_repo("nearest");
    let r = wr_vcs_core::current_ref(&dir).expect("current_ref");
    assert_eq!(
        r.name.as_deref(),
        Some("main"),
        "`main` sits on `@`'s own first parent; `deep` is two hops away and only wins on timestamp"
    );
    assert_eq!(
        r.kind,
        RefKind::Ancestor,
        "`@` itself carries no bookmark, so the label is an ancestor's"
    );
}

/// A bookmark ON `@` still outranks every ancestor's. The walk no longer special-cases `@` (it's
/// simply the first id `::@` yields, being a descendant of the whole set), so that has to be pinned.
#[test]
fn current_ref_prefers_a_bookmark_on_the_working_copy_itself() {
    if !have_jj() {
        eprintln!("skipping: jj not on PATH");
        return;
    }
    let (dir, cfg) = skewed_merge_repo("onwc");
    let wc = id_of("@", &dir, &cfg);
    jj(&["bookmark", "create", "here", "-r", &wc], &dir, &cfg);
    let r = wr_vcs_core::current_ref(&dir).expect("current_ref");
    assert_eq!(r.name.as_deref(), Some("here"));
    assert_eq!(
        r.kind,
        RefKind::Branch,
        "a bookmark on `@` is the current branch, not an ancestor label"
    );
}
