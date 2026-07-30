//! Integration tests for the ORDER of the jj backend's two ancestry walks — `log_page` (History) and
//! `first_bookmark_in_log_order` (the sidebar's branch label, via `current_ref`) — against REAL
//! throwaway jj repos. Read-only reads (`load_at_head`, no working-copy lock), so unlike the
//! `working_status` suite there's no corruption risk. Skips if `jj` isn't on PATH — and says so out
//! loud; see `tests/common/mod.rs`.
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

mod common;

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
/// - **Branch label.** The first bookmark `::@` reaches is `main`, on `@`'s own first parent `C`.
///   The timestamp walk instead surfaces `deep` on `A`, deeper in the ancestry, purely because a
///   rewrite left `A` with a later timestamp. (Log order and graph distance happen to agree in THIS
///   graph; `current_ref_takes_the_first_bookmark_in_log_order_even_when_another_is_nearer` builds
///   the one where they don't.)
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
    if common::skip_without(&["jj"], "topological-order test") {
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
    if common::skip_without(&["jj"], "log-order parity test") {
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
    if common::skip_without(&["jj"], "paging test") {
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

/// jj's virtual **root commit** is on `::@`, so it IS on the page — deliberately, for parity with
/// `jj log`. What it must not be is indistinguishable from a real commit: it has no author, no
/// description and an epoch timestamp, so the History pane renders it as `root()` off `is_root`
/// rather than as "(no description), 56 yr ago". This pins both halves: the flag is set on exactly
/// the last row, and the page still holds everything `jj log -r ::@` prints.
#[test]
fn log_page_flags_the_root_commit() {
    if common::skip_without(&["jj"], "root-commit flag test") {
        return;
    }
    let (dir, cfg) = init_repo("logroot");
    std::fs::write(dir.join("a.txt"), b"a\n").unwrap();
    jj(&["commit", "-m", "only"], &dir, &cfg);

    let page = page(&dir, 20);
    assert_eq!(
        page.commits.len(),
        jj_log_ids(&dir, &cfg).len(),
        "the root commit stays on the page — `jj log -r ::@` prints it too"
    );
    let root = page.commits.last().expect("a non-empty page");
    assert!(
        root.is_root,
        "the oldest row of a jj page is `root()`: {:?}",
        summaries(&page.commits)
    );
    assert!(
        root.commit_id.chars().all(|c| c == '0'),
        "the git-backed root commit's id is all zeros, got {}",
        root.commit_id
    );
    // Why the flag is needed at all: root's own fields are empty (the signature is present but
    // blank, and the timestamp is the epoch), so nothing about the DATA distinguishes it from a
    // description-less commit authored by nobody in 1970 — which is precisely how the pane used to
    // render it, `?` avatar included.
    assert!(root.summary.is_empty(), "root has no description");
    assert!(
        root.authors
            .iter()
            .all(|a| a.name.is_empty() && a.email.is_empty()),
        "root's author signature is blank, got {:?}",
        root.authors
    );
    assert_eq!(root.timestamp_ms, 0, "root is stamped at the epoch");
    assert_eq!(
        page.commits.iter().filter(|c| c.is_root).count(),
        1,
        "only `root()` is flagged; the real commits must not be"
    );
}

/// Named for what the walk promises — the first bookmark in LOG order — not "the nearest", which it
/// deliberately isn't (see `first_bookmark_in_log_order`, and the test below this one for a graph
/// where the two answers differ). Here they coincide, and the defect being pinned is the timestamp
/// walk this replaced.
#[test]
fn current_ref_picks_the_first_log_order_bookmark_not_the_newest_timestamped_one() {
    if common::skip_without(&["jj"], "log-order-vs-timestamp label test") {
        return;
    }
    let (dir, _cfg) = skewed_merge_repo("logorder");
    let r = wr_vcs_core::current_ref(&dir).expect("current_ref");
    assert_eq!(
        r.name.as_deref(),
        Some("main"),
        "`main` is the first bookmark `::@` reaches; `deep` is deeper and only wins on timestamp"
    );
    assert_eq!(
        r.kind,
        RefKind::Ancestor,
        "`@` itself carries no bookmark, so the label is an ancestor's"
    );
}

/// LOG ORDER IS NOT GRAPH DISTANCE, and the label follows log order. This is the graph where the two
/// disagree, pinned because `first_bookmark_in_log_order`'s name and doc now promise exactly which
/// one it answers — and because the obvious "improvement", a breadth-first walk returning the
/// genuinely closest bookmark, would quietly make the sidebar name a commit that isn't the first
/// bookmarked row in History.
///
/// ```text
///   base ─┬─ P1 [main] ────────────┐
///         └─ Q [feature] ── P2 ────┴─ @ = merge(P1, P2)
/// ```
///
/// `main` is ONE hop from `@`, on its own first parent. `feature` is TWO, down the second parent.
/// `jj log -r ::@` still prints `feature` first — the revset walks descending index position, and at
/// a merge that drains the higher-positioned side before the other — so `feature` is the first
/// bookmark a user meets scrolling down History, and therefore what the label must say. Both halves
/// are asserted: jj's own order (so the premise is measured, not assumed) and ours agreeing with it.
///
/// `working_status`'s `branch_for_ci` is this very same value, which is why its call-site comment
/// warns against reading it as "the branch this work will land on".
#[test]
fn current_ref_takes_the_first_bookmark_in_log_order_even_when_another_is_nearer() {
    if common::skip_without(&["jj"], "log-order-vs-graph-distance label test") {
        return;
    }
    let (dir, cfg) = init_repo("logorder-vs-distance");
    std::fs::write(dir.join("base.txt"), b"base\n").unwrap();
    jj(&["commit", "-m", "base"], &dir, &cfg);
    let base = id_of("@-", &dir, &cfg);

    // The first-parent side: one commit off `base`, bookmarked `main`.
    std::fs::write(dir.join("p1.txt"), b"p1\n").unwrap();
    jj(&["commit", "-m", "P1"], &dir, &cfg);
    let p1 = id_of("@-", &dir, &cfg);

    // The second-parent side: two commits off `base`, with `feature` on the LOWER of them.
    jj(&["new", &base], &dir, &cfg);
    std::fs::write(dir.join("q.txt"), b"q\n").unwrap();
    jj(&["commit", "-m", "Q"], &dir, &cfg);
    let q = id_of("@-", &dir, &cfg);
    std::fs::write(dir.join("p2.txt"), b"p2\n").unwrap();
    jj(&["commit", "-m", "P2"], &dir, &cfg);
    let p2 = id_of("@-", &dir, &cfg);

    jj(&["bookmark", "create", "main", "-r", &p1], &dir, &cfg);
    jj(&["bookmark", "create", "feature", "-r", &q], &dir, &cfg);
    // Sides by commit id, never by bookmark — `experimental-advance-branches` would otherwise move a
    // bookmark onto the merge and dissolve the whole question.
    jj(&["new", &p1, &p2], &dir, &cfg);

    // The premise, straight from jj: `feature`'s commit really is reached before `main`'s. Without
    // this the assertion below could pass on a graph that never posed the question.
    let order = jj_log_ids(&dir, &cfg);
    let at = |id: &str| {
        order
            .iter()
            .position(|x| x == id)
            .unwrap_or_else(|| panic!("{id} is not in ::@: {order:?}"))
    };
    assert!(
        at(&q) < at(&p1),
        "fixture: `jj log -r ::@` must reach Q[feature] before P1[main], else there is nothing to \
         test; got {order:?}"
    );

    let r = wr_vcs_core::current_ref(&dir).expect("current_ref");
    assert_eq!(
        r.name.as_deref(),
        Some("feature"),
        "the label is the first bookmark in LOG order (`feature`, two hops down the second parent), \
         not the graph-nearest one (`main`, on `@`'s own first parent)"
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
    if common::skip_without(&["jj"], "bookmark-on-@ label test") {
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
