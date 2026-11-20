//! Where a new workroom's branch starts, as Go's `internal/vcs` resolves it (`Git.StartPoint`):
//! the project's base on its remote, freshly fetched, else the local branch, else origin's default
//! branch, and the local work that start leaves out of the main checkout (`Git.LocalWork`).
//!
//! Only what `trust status` needs today: no create's fetch step events, and no pinned start
//! commit (ADR 0059), which `create` adds when it is ported (#672).

use std::path::Path;

use serde::Serialize;

use super::git;
use super::kind::{CliError, Kind};

/// A base branch setting read as `<remote>/<branch>` when the part before the first `/` is one of
/// `remotes`, else a branch on origin. So `upstream/main` is upstream's main, `origin/main` is
/// plain `main`, and `release/1.0` stays an origin branch unless a remote is named "release".
/// Go's `SplitBase`; `testdata/twins/split_base.tsv` holds the cases the app's twin is tested
/// against.
fn split_base<'a>(base: &'a str, remotes: &[&str]) -> (&'a str, &'a str) {
    match base.split_once('/') {
        Some((remote, rest)) if !rest.is_empty() && remotes.contains(&remote) => (remote, rest),
        _ => ("origin", base),
    }
}

/// Resolves where a new workroom's branch starts: `<remote>/<branch>` then the local `<branch>`
/// when there is a base (see [`split_base`]), else origin's default branch. It fetches that remote
/// first so the ref is current, and prunes so a branch deleted there is not used from its stale
/// copy; a failed fetch keeps the last-fetched ref and returns a warning. A base that resolves
/// nowhere is `BaseBranchNotFound`, and so is one that couldn't be looked for because the fetch
/// failed. With `fallback` (the app-wide default), a base the fetched remote and the local
/// branches both lack gives way to origin's default branch, with a warning. With no base and no
/// origin/HEAD the start is "", which is HEAD. Returns the start's ref and the warning, or "".
pub(super) fn start_point(
    dir: &Path,
    base: &str,
    fallback: bool,
) -> Result<(String, String), CliError> {
    // Whatever git said, as Go reads it: a failure's words are split into "remotes" too.
    let (out, _) = git::run(dir, &["remote"]);
    let remotes: Vec<&str> = out.split_whitespace().collect();
    let (remote, branch) = split_base(base, &remotes);
    let has_remote = remotes.contains(&remote);
    let fetched = has_remote && fetch(dir, remote, branch.is_empty());
    // Fully qualified: a tag or branch named like the short form would make it ambiguous.
    let mut candidates = Vec::new();
    if has_remote {
        if branch.is_empty() {
            candidates.push(format!("refs/remotes/{remote}/HEAD"));
        } else {
            candidates.push(format!("refs/remotes/{remote}/{branch}"));
        }
    }
    if !branch.is_empty() {
        candidates.push(format!("refs/heads/{branch}"));
    }
    let start = first_ref(dir, &candidates);
    if start.is_empty() && !branch.is_empty() {
        if has_remote && !fetched {
            return Err(base_not_found(format!(
                "'{base}' (could not fetch {remote} to look there)"
            )));
        }
        if !fallback {
            return Err(base_not_found(format!("'{base}'")));
        }
        return Ok(origin_default(
            dir,
            base,
            &remotes,
            remote == "origin" && fetched,
        ));
    }
    let warning = if has_remote && !fetched {
        format!(
            "Could not fetch {remote}. The workroom starts from {}, which may be out of date.",
            ref_name(dir, &start)
        )
    } else if has_remote && start.starts_with("refs/heads/") {
        // The remote answered without the base: deleted there after a merge, or never pushed.
        // The local copy can be far behind, so say which one this is.
        format!(
            "{remote} has no {branch}, so the workroom starts from your local {branch}, which may \
             be out of date."
        )
    } else {
        String::new()
    };
    Ok((start, warning))
}

/// Go's `ErrBaseBranchNotFound`, with what it couldn't find.
fn base_not_found(detail: String) -> CliError {
    CliError::new(
        Kind::BaseBranchNotFound,
        format!("the base branch exists neither on its remote nor locally: {detail}"),
    )
}

/// Origin's default branch, for an app-wide default base that doesn't exist in this project.
/// Origin is fetched only if the base named another remote; otherwise its fetch for the base
/// already happened (`origin_fetched`), so origin is never fetched twice.
fn origin_default(
    dir: &Path,
    base: &str,
    remotes: &[&str],
    mut origin_fetched: bool,
) -> (String, String) {
    let has_origin = remotes.contains(&"origin");
    let mut start = String::new();
    if has_origin {
        if origin_fetched {
            let _ = git::run(dir, &["remote", "set-head", "origin", "--auto"]);
        } else {
            origin_fetched = fetch(dir, "origin", true);
        }
        start = first_ref(dir, &["refs/remotes/origin/HEAD".to_string()]);
    }
    let mut warning = format!(
        "The default base branch {base} doesn't exist in this project, so the workroom starts \
         from {}.",
        ref_name(dir, &start)
    );
    if has_origin && !origin_fetched {
        warning += " Could not fetch origin, so it may be out of date.";
    }
    (start, warning)
}

/// Fetches `remote`, pruned, and with `set_head` refreshes its HEAD, which fetch never moves after
/// a default-branch rename. Whether the fetch worked.
fn fetch(dir: &Path, remote: &str, set_head: bool) -> bool {
    if !git::run(dir, &["fetch", "--prune", remote]).1 {
        return false;
    }
    if set_head {
        let _ = git::run(dir, &["remote", "set-head", remote, "--auto"]);
    }
    true
}

/// The first of `refs` that names a commit, or "".
fn first_ref(dir: &Path, refs: &[String]) -> String {
    refs.iter()
        .find(|name| {
            git::run(
                dir,
                &[
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    &format!("{name}^{{commit}}"),
                ],
            )
            .1
        })
        .cloned()
        .unwrap_or_default()
}

/// `name` as a person knows it: origin/HEAD as the branch it points to, such as origin/main.
fn ref_name(dir: &Path, name: &str) -> String {
    if name.is_empty() {
        return "HEAD".to_string();
    }
    match git::run(dir, &["rev-parse", "--abbrev-ref", name]) {
        (out, true) if !out.is_empty() => out,
        _ => name.to_string(),
    }
}

/// What a create starting from a remote's copy of a branch leaves behind in the main checkout:
/// commits on the local branch the remote's copy lacks, and uncommitted changes when the main
/// checkout has that branch out. Changes on another branch aren't the base branch's, so they
/// don't count. Go's `vcs.LocalWork`.
#[derive(Default)]
pub(super) struct LocalWork {
    /// The base branch's local name, such as master; "" when there is no local branch to compare,
    /// and nothing else is set.
    pub(super) branch: String,
    /// The remote whose copy of `branch` the create starts from, such as origin.
    pub(super) remote: String,
    /// How many commits the local branch has that the start lacks.
    pub(super) ahead: u64,
    /// Whether the main checkout is on `branch` with changes git hasn't committed.
    pub(super) uncommitted: bool,
    /// How many commits the start has that the local branch lacks.
    pub(super) behind: u64,
}

impl LocalWork {
    /// Whether there is local work a create would leave out.
    pub(super) fn any(&self) -> bool {
        self.ahead > 0 || self.uncommitted
    }

    /// What the work is, plainly, for a person; "" when there is none.
    fn summary(&self) -> String {
        let commits = if self.ahead == 1 { "commit" } else { "commits" };
        let branch = &self.branch;
        match (self.ahead > 0, self.uncommitted) {
            (true, true) => format!(
                "You have {} {commits} on {branch} that you haven't pushed yet, and some changes \
                 you haven't committed",
                self.ahead
            ),
            (true, false) => format!(
                "You have {} {commits} on {branch} that you haven't pushed yet",
                self.ahead
            ),
            (false, true) => format!("You have changes on {branch} that you haven't committed yet"),
            (false, false) => String::new(),
        }
    }

    /// What including the work would leave out instead, when the local branch lacks commits the
    /// remote has; "" when it isn't behind.
    fn behind_note(&self) -> String {
        if self.behind == 0 {
            return String::new();
        }
        let commits = if self.behind == 1 {
            "commit"
        } else {
            "commits"
        };
        format!(
            "Your {} is also {} {commits} behind {}, so including your work starts from your \
             older copy.",
            self.branch, self.behind, self.remote
        )
    }

    /// The `local_work` object of an envelope, in Go's key order.
    pub(super) fn payload(&self) -> LocalWorkPayload {
        LocalWorkPayload {
            ahead: self.ahead,
            behind: self.behind,
            behind_note: self.behind_note(),
            branch: self.branch.clone(),
            remote: self.remote.clone(),
            summary: self.summary(),
            uncommitted: self.uncommitted,
        }
    }
}

/// Local work as an envelope reports it, with `summary` to show and `behind_note`, said beside it
/// when the local branch is behind.
#[derive(Serialize)]
pub(super) struct LocalWorkPayload {
    ahead: u64,
    behind: u64,
    behind_note: String,
    branch: String,
    remote: String,
    summary: String,
    uncommitted: bool,
}

/// Compares `start`, a remote's branch such as refs/remotes/origin/HEAD, with the local branch of
/// the same name and with the main checkout at `dir`. Empty unless `start` is a remote's branch.
pub(super) fn local_work(dir: &Path, start: &str) -> LocalWork {
    let Some(mut rest) = start.strip_prefix("refs/remotes/").map(str::to_string) else {
        return LocalWork::default();
    };
    // origin/HEAD stands for the branch it points to.
    if rest.ends_with("/HEAD") {
        let (target, ok) = git::run(dir, &["symbolic-ref", "--quiet", start]);
        if !ok {
            return LocalWork::default();
        }
        rest = target
            .strip_prefix("refs/remotes/")
            .unwrap_or(&target)
            .to_string();
    }
    let Some((remote, branch)) = rest.split_once('/') else {
        return LocalWork::default();
    };
    if first_ref(dir, &[format!("refs/heads/{branch}")]).is_empty() {
        return LocalWork::default();
    }
    let mut work = LocalWork {
        branch: branch.to_string(),
        remote: remote.to_string(),
        ..LocalWork::default()
    };
    // "<behind>\t<ahead>": the start's commits the local branch lacks, then the local branch's.
    let range = format!("{start}...refs/heads/{branch}");
    if let (out, true) = git::run(dir, &["rev-list", "--left-right", "--count", &range])
        && let Some((behind, ahead)) = out.split_once('\t')
    {
        work.behind = behind.parse().unwrap_or(0);
        work.ahead = ahead.parse().unwrap_or(0);
    }
    if let (head, true) = git::run(dir, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        && head == branch
    {
        let (status, ok) = git::run(dir, &["status", "--porcelain"]);
        work.uncommitted = ok && !status.is_empty();
    }
    work
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_base_names_a_remote_only_when_one_is_called_that() {
        let remotes = ["origin", "upstream"];
        assert_eq!(split_base("upstream/main", &remotes), ("upstream", "main"));
        assert_eq!(split_base("origin/main", &remotes), ("origin", "main"));
        assert_eq!(
            split_base("release/1.0", &remotes),
            ("origin", "release/1.0")
        );
        assert_eq!(split_base("upstream/", &remotes), ("origin", "upstream/"));
        assert_eq!(split_base("", &remotes), ("origin", ""));
    }

    #[test]
    fn local_work_says_what_a_create_leaves_out() {
        let work = |ahead, uncommitted, behind| LocalWork {
            branch: "master".to_string(),
            remote: "origin".to_string(),
            ahead,
            uncommitted,
            behind,
        };
        assert_eq!(
            work(2, true, 0).summary(),
            "You have 2 commits on master that you haven't pushed yet, and some changes you \
             haven't committed"
        );
        assert_eq!(
            work(1, false, 0).summary(),
            "You have 1 commit on master that you haven't pushed yet"
        );
        assert_eq!(
            work(0, true, 0).summary(),
            "You have changes on master that you haven't committed yet"
        );
        assert_eq!(work(0, false, 0).summary(), "");
        assert_eq!(work(0, false, 0).behind_note(), "");
        assert_eq!(
            work(0, false, 3).behind_note(),
            "Your master is also 3 commits behind origin, so including your work starts from \
             your older copy."
        );
        assert_eq!(
            work(0, false, 1).behind_note(),
            "Your master is also 1 commit behind origin, so including your work starts from your \
             older copy."
        );
    }
}
