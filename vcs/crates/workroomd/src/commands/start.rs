//! Where a new workroom's branch starts, as the retired Go CLI resolved it (ported from its
//! `Git.StartPoint`):
//! the project's base on its remote, freshly fetched, else the local branch, else origin's default
//! branch, and the local work that start leaves out of the main checkout (`Git.LocalWork`).
//!
//! `trust status` resolves the start silently. `create` reports its fetch as the create's `fetch`
//! step, with git's output in its log ([`FetchStep`]), and a create answering a create question
//! starts from the commit it was asked about, fetching nothing (ADR 0059).

use std::path::Path;

use serde::Serialize;

use super::git;
use super::kind::{CliError, Kind};

/// Where a create's steps and the git output behind them go: Go's `vcs.Progress`. States are
/// `running`, `done`, `warning`, `skipped` and `failed`; `detail` is the warning, the skip
/// reason or the failure.
pub(super) trait Progress {
    fn step(&mut self, id: &str, state: &str, detail: &str);
    /// One line of the running step's log, as Go's `fmt.Fprintln` writes one to it.
    fn log(&mut self, line: &str);
}

/// No one to tell: `trust status`'s start, and a create without `--json`.
pub(super) struct Silent;

impl Progress for Silent {
    fn step(&mut self, _: &str, _: &str, _: &str) {}
    fn log(&mut self, _: &str) {}
}

/// git `args` in `dir` as Go's `Git.run` runs it for a create: `$ git <args>` in the log, then
/// what git printed there, both streams in the order printed. Its output and whether it exited 0,
/// or, when it didn't, how it ended in Go's words (`exit status 128`).
pub(super) fn logged_git(
    progress: &mut dyn Progress,
    dir: &Path,
    args: &[&str],
) -> Result<String, String> {
    progress.log(&format!("$ git {}", args.join(" ")));
    let (out, ended) = git::combined(dir, args);
    if !out.is_empty() {
        progress.log(&out);
    }
    ended.map(|()| out)
}

/// The create's `fetch` step: unannounced until a fetch is tried, so a project with no remote goes
/// straight to skipped. A pinned create has none: the create whose question it answers fetched,
/// and reported it. Go's `fetchStep`.
pub(super) struct FetchStep<'a> {
    pub(super) progress: &'a mut dyn Progress,
    attempted: bool,
    /// The fetch was tried and failed.
    pub(super) failed: bool,
    pinned: bool,
    /// A dry run's (`--pretend`, #798): nothing is fetched, and the start is found as a failed
    /// fetch finds it, among the refs as last fetched, saying so.
    dry: bool,
}

impl<'a> FetchStep<'a> {
    /// The fetch step of a create; `pinned` when it starts from a commit it was given.
    pub(super) fn new(progress: &'a mut dyn Progress, pinned: bool) -> FetchStep<'a> {
        FetchStep {
            progress,
            attempted: false,
            failed: false,
            pinned,
            dry: false,
        }
    }

    /// Why `remote` wasn't fetched: the fetch failed, or a dry run fetches nothing.
    fn not_fetched(&self, remote: &str) -> String {
        if self.dry {
            format!("--pretend fetches nothing, so {remote} wasn't fetched")
        } else {
            format!("could not fetch {remote}")
        }
    }

    /// Ends the step once the start is settled: a base found nowhere fails it, and a start-point
    /// warning ends it with that warning.
    pub(super) fn finish(&mut self, warning: &str, error: Option<&CliError>) {
        if self.pinned {
            return;
        }
        if let Some(error) = error {
            self.progress.log(&error.message);
            self.progress.step("fetch", "failed", &error.message);
        } else if !warning.is_empty() {
            self.progress.step("fetch", "warning", warning);
        } else if !self.attempted {
            self.progress
                .step("fetch", "skipped", "No remote to fetch from");
        } else {
            self.progress.step("fetch", "done", "");
        }
    }

    /// Fetches `remote`, pruned, and with `set_head` refreshes its HEAD, which fetch never moves
    /// after a default-branch rename. Whether the fetch worked; a pinned create fetches nothing
    /// and counts as fetched.
    fn fetch(&mut self, dir: &Path, remote: &str, set_head: bool) -> bool {
        if self.pinned {
            return true;
        }
        if self.dry {
            return false;
        }
        if !self.attempted {
            self.progress.step("fetch", "running", "");
        }
        self.attempted = true;
        if logged_git(self.progress, dir, &["fetch", "--prune", remote]).is_err() {
            self.failed = true;
            return false;
        }
        if set_head {
            let _ = git::run(dir, &["remote", "set-head", remote, "--auto"]);
        }
        true
    }
}

/// A base branch setting read as `<remote>/<branch>` when the part before the first `/` is one of
/// `remotes`, else a branch on origin. So `upstream/main` is upstream's main, `origin/main` is
/// plain `main`, and `release/1.0` stays an origin branch unless a remote is named "release".
/// Ported from the retired Go CLI's `SplitBase`; `testdata/twins/split_base.tsv` holds the cases
/// this and the app's twin are tested against.
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
/// Without `fetch` (`--pretend`) nothing is fetched: the start is found among the refs as last
/// fetched, as a failed fetch finds it, and the warning or the refusal says `--pretend` fetched
/// nothing.
pub(super) fn start_point(
    dir: &Path,
    base: &str,
    fallback: bool,
    fetch: bool,
) -> Result<(String, String), CliError> {
    let mut silent = Silent;
    let mut step = FetchStep::new(&mut silent, false);
    step.dry = !fetch;
    resolve(dir, base, fallback, &mut step)
}

/// [`start_point`], fetching through `fs`, which the caller finishes once the start is settled.
pub(super) fn resolve(
    dir: &Path,
    base: &str,
    fallback: bool,
    fs: &mut FetchStep,
) -> Result<(String, String), CliError> {
    // Whatever git said, as Go reads it: a failure's words are split into "remotes" too.
    let (out, _) = git::run(dir, &["remote"]);
    let remotes: Vec<&str> = out.split_whitespace().collect();
    let (remote, branch) = split_base(base, &remotes);
    let has_remote = remotes.contains(&remote);
    let fetched = has_remote && fs.fetch(dir, remote, branch.is_empty());
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
                "'{base}' ({} to look there)",
                fs.not_fetched(remote)
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
            fs,
        ));
    }
    let warning = if has_remote && !fetched {
        format!(
            "{}. The workroom starts from {}, which may be out of date.",
            capitalized(&fs.not_fetched(remote)),
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
    fs: &mut FetchStep,
) -> (String, String) {
    let has_origin = remotes.contains(&"origin");
    let mut start = String::new();
    if has_origin {
        if fs.pinned {
            // `set-head --auto` asks the remote, and a pinned create reaches it for nothing: the
            // create whose question it answers set origin/HEAD, and said if its fetch failed.
            origin_fetched = true;
        } else if origin_fetched {
            let _ = git::run(dir, &["remote", "set-head", "origin", "--auto"]);
        } else {
            origin_fetched = fs.fetch(dir, "origin", true);
        }
        start = first_ref(dir, &["refs/remotes/origin/HEAD".to_string()]);
    }
    let mut warning = format!(
        "The default base branch {base} doesn't exist in this project, so the workroom starts \
         from {}.",
        ref_name(dir, &start)
    );
    if has_origin && !origin_fetched {
        warning += &format!(
            " {}, so it may be out of date.",
            capitalized(&fs.not_fetched("origin"))
        );
    }
    (start, warning)
}

/// `text` with its first letter upper case.
fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map_or_else(String::new, |first| {
        first.to_uppercase().chain(chars).collect()
    })
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
pub(super) fn ref_name(dir: &Path, name: &str) -> String {
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
    /// The start already came with a warning (a failed fetch, a fallback), so the counts are
    /// against a remote copy that may be out of date: nobody is asked, though a start chosen
    /// beforehand still holds.
    pub(super) stale: bool,
}

impl LocalWork {
    /// Whether there is local work a create would leave out.
    pub(super) fn any(&self) -> bool {
        self.ahead > 0 || self.uncommitted
    }

    /// What the work is, plainly, for a person; "" when there is none.
    pub(super) fn summary(&self) -> String {
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
    pub(super) fn behind_note(&self) -> String {
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
#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct LocalWorkPayload {
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
    local_work_at(dir, start, start)
}

/// [`local_work`] with the counts taken against `at`, the commit a create starts from, which a
/// pinned create holds behind where `start` has since moved. Go's `localWork`.
pub(super) fn local_work_at(dir: &Path, start: &str, at: &str) -> LocalWork {
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
    let range = format!("{at}...refs/heads/{branch}");
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

/// Whether `commit` is a commit that `name` ("" is HEAD) points to or descends from: where a
/// pinned create may start from its start point. Go's `isAncestor`.
pub(super) fn is_ancestor(dir: &Path, commit: &str, name: &str) -> bool {
    let name = if name.is_empty() { "HEAD" } else { name };
    git::run(
        dir,
        &[
            "merge-base",
            "--is-ancestor",
            &format!("{commit}^{{commit}}"),
            name,
        ],
    )
    .1
}

/// The commit `start` ("" is HEAD) names, which a create question reports as its `start_commit`
/// (ADR 0059); "" when it names none, as in a repository with no commits yet. Go's `question`.
pub(super) fn question_commit(dir: &Path, start: &str) -> String {
    let start = if start.is_empty() { "HEAD" } else { start };
    match git::run(
        dir,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{start}^{{commit}}"),
        ],
    ) {
        (commit, true) => commit,
        _ => String::new(),
    }
}

/// The warning for a start switched to the local branch against a remote copy that came with
/// one: why the default base wasn't used, if it wasn't, that the workroom starts from the local
/// branch, and, when the fetch failed, that it couldn't be compared with what was pushed. Go's
/// `localStartWarning`.
pub(super) fn local_start_warning(
    base: &str,
    remote_start: &str,
    work: &LocalWork,
    fetch_failed: bool,
) -> String {
    let mut parts = Vec::new();
    // `origin_default`'s fallback: the app-wide default base gave way to origin's default branch.
    if !base.is_empty() && remote_start == "refs/remotes/origin/HEAD" {
        parts.push(format!(
            "The default base branch {base} doesn't exist in this project."
        ));
    }
    parts.push(format!(
        "The workroom starts from your local {}, as you chose.",
        work.branch
    ));
    if fetch_failed {
        parts.push(
            "It couldn't be compared with what you've pushed, so the two may differ.".to_string(),
        );
    }
    parts.join(" ")
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

    /// Every row of the table the app's `RemoteWorkrooms.splitBase` is tested against, so the CLI
    /// and the app read a base branch alike.
    #[test]
    fn a_base_splits_as_the_shared_table_says() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../testdata/twins/split_base.tsv"
        );
        let table = std::fs::read_to_string(path).expect("read split_base.tsv");
        let mut rows = 0;
        for line in table.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = line.split('\t').collect();
            assert_eq!(fields.len(), 4, "{line:?}");
            let remotes: Vec<&str> = fields[0].split(',').collect();
            assert_eq!(
                split_base(fields[1], &remotes),
                (fields[2], fields[3]),
                "{line:?}"
            );
            rows += 1;
        }
        assert!(rows >= 8, "read only {rows} rows");
    }

    #[test]
    fn local_work_says_what_a_create_leaves_out() {
        let work = |ahead, uncommitted, behind| LocalWork {
            branch: "master".to_string(),
            remote: "origin".to_string(),
            ahead,
            uncommitted,
            behind,
            stale: false,
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
