//! Integration tests for the jj backend's `push_state` against REAL throwaway jj repos.
//!
//! What matters here is the *scoping*, not the graph math (jj-lib's revset answers reachability):
//!
//! - `origin` only. A commit that lives on some other remote (`backup`, a fork) is NOT on the
//!   project's shared repo, so it must still read `Unpushed`.
//! - NEVER jj's pseudo-remote `git`. Every local git branch is mirrored as `<name>@git` and marked
//!   tracked — even in a non-colocated `jj git init` repo (verified: `jj bookmark list --all-remotes`
//!   shows `@git` there too). Counting that remote would make every local commit read `Pushed`, which
//!   is the single most likely bug in this feature.
//! - Untracked remote bookmarks don't count.
//! - Nothing to compare against ⇒ `Unknown`, which the UI renders as no badge (never `Unpushed`).
//!
//! These are read-only reads (`load_at_head`, no working-copy lock), so unlike the `working_status`
//! suite there's no corruption risk. Skips if `jj` or `git` isn't on PATH — a missing `jj` says so
//! out loud, a missing `git` doesn't; see `tests/common/mod.rs` for both and why they differ.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use wr_vcs_model::PushState;

mod common;

fn run(bin: &str, args: &[&str], dir: &Path) -> std::process::Output {
    Command::new(bin)
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap_or_else(|e| panic!("run {bin} {args:?}: {e}"))
}

fn jj(args: &[&str], dir: &Path) -> std::process::Output {
    let out = run("jj", args, dir);
    assert!(
        out.status.success(),
        "jj {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

fn git(args: &[&str], dir: &Path) -> std::process::Output {
    let out = run("git", args, dir);
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

/// One shared, isolated jj config for the whole test binary. Tests in a file run in parallel threads
/// and `set_var` is process-global, so every test must set the SAME value — hence a `OnceLock` rather
/// than a per-test config path.
fn init_jj_config() {
    static CFG: OnceLock<PathBuf> = OnceLock::new();
    let cfg = CFG.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("wr-push-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("jjconfig.toml");
        std::fs::write(
            &path,
            b"[user]\nname = \"Test\"\nemail = \"test@example.com\"\n",
        )
        .unwrap();
        path
    });
    // SAFETY: every caller sets the same path, before any jj/jj-lib call in that test.
    unsafe { std::env::set_var("JJ_CONFIG", cfg) }
}

/// A fresh temp directory, named after the calling line so parallel tests never collide.
fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wr-push-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// `work` with one commit ("first") on bookmark `main`, pushed to a bare `origin`, plus a second
/// local-only commit ("second"). Returns the work-repo root.
fn repo_with_pushed_main(tag: &str) -> PathBuf {
    init_jj_config();
    let root = temp_dir(tag);
    git(&["init", "-q", "--bare", "origin.git"], &root);
    jj(&["git", "init", "work"], &root);
    let work = root.join("work");
    std::fs::write(work.join("a.txt"), b"a\n").unwrap();
    jj(&["commit", "-m", "first"], &work);
    jj(&["bookmark", "create", "main", "-r", "@-"], &work);
    let origin = root.join("origin.git");
    jj(
        &["git", "remote", "add", "origin", origin.to_str().unwrap()],
        &work,
    );
    // jj 0.43 auto-tracks a new bookmark when it's pushed by name — there is no `--allow-new`.
    jj(&["git", "push", "-b", "main"], &work);
    std::fs::write(work.join("b.txt"), b"b\n").unwrap();
    jj(&["commit", "-m", "second"], &work);
    work
}

fn page(root: &Path) -> wr_vcs_model::HistoryPage {
    wr_vcs_core::log_page(root, 20).expect("log_page")
}

fn state_of(page: &wr_vcs_model::HistoryPage, summary: &str) -> PushState {
    page.commits
        .iter()
        .find(|c| c.summary == summary)
        .unwrap_or_else(|| {
            panic!(
                "no commit summarised {summary:?}; got {:?}",
                page.commits.iter().map(|c| &c.summary).collect::<Vec<_>>()
            )
        })
        .push_state
}

#[test]
fn push_state_splits_at_the_origin_bookmark() {
    if common::skip_without(&["jj", "git"], "origin-split push test") {
        return;
    }
    let work = repo_with_pushed_main("split");
    let page = page(&work);

    assert_eq!(state_of(&page, "first"), PushState::Pushed);
    assert_eq!(state_of(&page, "second"), PushState::Unpushed);
    // The working copy `@` is a real (empty) commit above `second`, so it's unpushed too. The UI
    // suppresses the badge on `@`; the DATA stays truthful.
    let wc = page
        .commits
        .iter()
        .find(|c| c.is_working_copy)
        .expect("@ is in the page");
    assert_eq!(wc.push_state, PushState::Unpushed);

    // Exactly one origin bookmark ⇒ the tooltip can name it.
    let scope = page.push_scope.expect("a tracked origin bookmark exists");
    assert_eq!(scope.count, 1);
    assert_eq!(scope.ref_name.as_deref(), Some("origin/main"));
}

#[test]
fn push_state_is_unknown_without_a_remote() {
    if common::skip_without(&["jj"], "no-remote push test") {
        return;
    }
    init_jj_config();
    let root = temp_dir("noremote");
    jj(&["git", "init", "work"], &root);
    let work = root.join("work");
    std::fs::write(work.join("a.txt"), b"a\n").unwrap();
    jj(&["commit", "-m", "only"], &work);

    let page = page(&work);
    assert!(page.push_scope.is_none(), "nothing to compare against");
    for c in &page.commits {
        assert_eq!(
            c.push_state,
            PushState::Unknown,
            "no remote ⇒ unknown, not unpushed ({:?})",
            c.summary
        );
    }
}

/// THE regression pin for jj's pseudo-remote. A colocated repo mirrors every local git branch as
/// `<name>@git` and marks it tracked, so a "count every tracked remote bookmark" implementation reads
/// `Pushed` for commits that were never pushed anywhere.
#[test]
fn push_state_never_pushed_via_the_pseudo_remote_git() {
    if common::skip_without(&["jj", "git"], "pseudo-remote `git` push test") {
        return;
    }
    init_jj_config();
    let root = temp_dir("colocated");
    jj(&["git", "init", "--colocate", "work"], &root);
    let work = root.join("work");
    std::fs::write(work.join("a.txt"), b"a\n").unwrap();
    jj(&["commit", "-m", "local only"], &work);
    // A local bookmark, hence a `local only@git` remote bookmark — but no real remote anywhere.
    jj(&["bookmark", "create", "feature", "-r", "@-"], &work);

    let page = page(&work);
    assert!(page.push_scope.is_none(), "`git` is not a push remote");
    for c in &page.commits {
        assert_ne!(
            c.push_state,
            PushState::Pushed,
            "a local git branch is not a push ({:?})",
            c.summary
        );
    }
}

#[test]
fn push_state_is_unknown_when_the_origin_bookmark_is_untracked() {
    if common::skip_without(&["jj", "git"], "untracked-bookmark push test") {
        return;
    }
    let work = repo_with_pushed_main("untracked");
    jj(&["bookmark", "untrack", "main@origin"], &work);

    let page = page(&work);
    assert!(page.push_scope.is_none(), "no TRACKED origin bookmark left");
    assert_eq!(state_of(&page, "first"), PushState::Unknown);
    assert_eq!(state_of(&page, "second"), PushState::Unknown);
}

/// Origin-scoping: a commit pushed only to a *different* remote is still unpushed.
#[test]
fn push_state_ignores_non_origin_remotes() {
    if common::skip_without(&["jj", "git"], "non-origin remote push test") {
        return;
    }
    let work = repo_with_pushed_main("backup");
    let root = work.parent().unwrap().to_path_buf();
    git(&["init", "-q", "--bare", "backup.git"], &root);
    let backup = root.join("backup.git");
    jj(
        &["git", "remote", "add", "backup", backup.to_str().unwrap()],
        &work,
    );
    // `second` goes to `backup` only — never to origin.
    jj(&["bookmark", "create", "side", "-r", "@-"], &work);
    jj(&["git", "push", "--remote", "backup", "-b", "side"], &work);

    let page = page(&work);
    assert_eq!(state_of(&page, "second"), PushState::Unpushed);
    assert_eq!(state_of(&page, "first"), PushState::Pushed);
    // The scope still names only origin's bookmark, so the tooltip can't imply `backup` was checked.
    let scope = page.push_scope.expect("origin/main is still tracked");
    assert_eq!(scope.count, 1);
    assert_eq!(scope.ref_name.as_deref(), Some("origin/main"));
}

/// Divergent siblings are built INSIDE `to_model_commit`, so a caller that set `push_state` on the
/// returned commit afterwards would leave every sibling `Unknown`. This pins the closure being
/// threaded down instead.
#[test]
fn push_state_covers_divergent_siblings() {
    if common::skip_without(&["jj", "git"], "divergent-sibling push test") {
        return;
    }
    let work = repo_with_pushed_main("divergent");
    // Divergence recipe: describe `@-` twice, the second time against the operation from BEFORE the
    // first — two visible commits end up sharing one change id.
    let op = jj(
        &[
            "op",
            "log",
            "--no-graph",
            "--color",
            "never",
            "-T",
            "id.short()",
            "-n1",
        ],
        &work,
    );
    let op = String::from_utf8_lossy(&op.stdout).trim().to_string();
    jj(&["describe", "-r", "@-", "-m", "one"], &work);
    jj(
        &["describe", "-r", "@-", "-m", "two", "--at-op", &op],
        &work,
    );

    let page = page(&work);
    let divergent = page
        .commits
        .iter()
        .find(|c| !c.divergent_siblings.is_empty())
        .expect("a divergent commit is on the ::@ line");
    for sib in &divergent.divergent_siblings {
        assert_ne!(
            sib.push_state,
            PushState::Unknown,
            "siblings are measured too, not left unknown ({:?})",
            sib.summary
        );
    }
}

#[test]
fn changeset_push_state_matches_the_log_row() {
    if common::skip_without(&["jj", "git"], "changeset/log push parity test") {
        return;
    }
    let work = repo_with_pushed_main("changeset");
    let page = page(&work);
    for summary in ["first", "second"] {
        let row = page
            .commits
            .iter()
            .find(|c| c.summary == summary)
            .expect("row");
        let cs = wr_vcs_core::changeset(&work, &row.commit_id).expect("changeset");
        assert_eq!(
            cs.commit.push_state, row.push_state,
            "changeset and log agree for {summary:?}"
        );
        assert_eq!(
            cs.push_scope.as_ref().and_then(|s| s.ref_name.as_deref()),
            Some("origin/main"),
            "changeset carries the same comparison scope"
        );
    }
}
