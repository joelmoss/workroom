//! jj backend — the ONLY site that touches `jj-lib`.
//!
//! Most reads (`log_page`, `changeset`, `current_ref`) are read-only: they `open` the workspace and
//! `load_at_head`, reading commit data WITHOUT snapshotting/locking the working copy (prior learning
//! `jj-concurrent-probes-working-copy-lock`: jj takes the working-copy lock only on ops that *write*
//! `@`). The exception is `working_status` (`snapshot_working_copy`), which MUST snapshot `@` so it
//! reflects on-disk edits — so it takes the lock + rewrites `@`, exactly like every `jj` command.
//!
//! Two different ref reads live here, and they are NOT interchangeable: `bookmark_map` reads LOCAL
//! bookmarks (the history rows' labels), while `origin_tips` reads the tracked bookmarks on remote
//! `origin` (push state). Never mix them — see `PUSH_REMOTE` for why counting jj's pseudo-remote `git`
//! would report every local commit as pushed.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::backend::ChangeId;
use jj_lib::commit::Commit as JjCommit;
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::conflicts::{
    materialize_merge_result_to_bytes, materialized_diff_stream, ConflictMaterializeOptions,
    MaterializedTreeValue,
};
use jj_lib::copies::{CopyOperation, CopyRecords};
use jj_lib::diff::DiffHunkKind;
use jj_lib::diff_presentation::{diff_by_line, LineCompareMode};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::hex_util::encode_reverse_hex;
use jj_lib::id_prefix::IdPrefixIndex;
use jj_lib::local_working_copy::LocalWorkingCopy;
use jj_lib::lock::FileLock;
use jj_lib::matchers::{EverythingMatcher, NothingMatcher};
use jj_lib::merge::{Diff, MergedTreeValue};
use jj_lib::object_id::ObjectId;
use jj_lib::repo::{ReadonlyRepo, Repo, StoreFactories, StoreLoadError};
use jj_lib::repo_path::RepoPath;
use jj_lib::revset::{ResolvedRevsetExpression, Revset, RevsetExpression};
use jj_lib::tree_merge::MergeOptions;
use jj_lib::working_copy::{SnapshotOptions, WorkingCopyFreshness};
use jj_lib::workspace::{default_working_copy_factories, Workspace, WorkspaceLoadError};

use wr_vcs_model as model;
use wr_vcs_model::{Author, Commit, HistoryPage, VcsError};

fn io<E: std::fmt::Display>(e: E) -> VcsError {
    VcsError::Io(e.to_string())
}

/// Classify a `Workspace::load` failure instead of flattening it to `Io`, so the app can tell
/// "this isn't a jj repo (any more)" from "we can't read this repo". Each arm reaches a distinct
/// Swift `VCSError` case and from there a distinct UI state — see `RustJJProvider.mapError`.
///
/// - the two "no repo at this path" variants → `UnsupportedRepo`: the `.jj` dir (or the `repo` dir a
///   secondary workspace's `.jj/repo` file points at) is gone, so the path the app has registered as
///   a jj project no longer is one. Swift maps this to the sidebar's "not a repository", the same
///   honest answer git already gives.
/// - `StoreLoadError::UnsupportedType` → `BackendVersion`: the repo names a backend (commit / op /
///   index / working-copy store) that this build's `StoreFactories` doesn't know — the signature of a
///   repo written by a newer jj than the `jj-lib` we pin. Retrying can't help; the message names the
///   store and type so the user can see which.
/// - everything else (unreadable paths, undecodable repo path, working-copy state, other store load
///   failures) stays `Io`: a real I/O-shaped failure with nothing more specific to say.
fn workspace_load_err(e: WorkspaceLoadError) -> VcsError {
    match e {
        WorkspaceLoadError::NoWorkspaceHere(path) => {
            VcsError::UnsupportedRepo(format!("no jj repo at {}", path.display()))
        }
        WorkspaceLoadError::RepoDoesNotExist(path) => {
            VcsError::UnsupportedRepo(format!("jj repo no longer at {}", path.display()))
        }
        WorkspaceLoadError::StoreLoadError(StoreLoadError::UnsupportedType {
            store,
            store_type,
        }) => VcsError::BackendVersion(format!("unsupported {store} backend type '{store_type}'")),
        other => io(other),
    }
}

/// Open a workspace read-only and load the repo at the current operation head.
fn open(root: &Path) -> model::Result<(Workspace, Arc<ReadonlyRepo>)> {
    let settings = crate::jj_config::user_settings()?;
    let workspace = Workspace::load(
        &settings,
        root,
        &StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .map_err(workspace_load_err)?;
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(io)?;
    Ok((workspace, repo))
}

/// Map a jj `Signature` to our model author + split timestamp (epoch millis + tz offset in seconds;
/// jj stores the offset in minutes).
fn author_of(sig: &jj_lib::backend::Signature) -> (Author, i64, i32) {
    let author = Author {
        name: sig.name.clone(),
        email: sig.email.clone(),
    };
    (
        author,
        sig.timestamp.timestamp.0,
        sig.timestamp.tz_offset * 60,
    )
}

/// Build `commit_id_hex -> [bookmark names]` from the repo view's LOCAL bookmarks (display labels for
/// history rows). Remote bookmarks are deliberately absent here; push state reads them via
/// `origin_tips`.
fn bookmark_map(repo: &ReadonlyRepo) -> HashMap<String, Vec<String>> {
    let mut map: HashMap<String, Vec<String>> = HashMap::new();
    for (name, target) in repo.view().local_bookmarks() {
        let label = name.as_symbol().to_string();
        for id in target.added_ids() {
            map.entry(id.hex()).or_default().push(label.clone());
        }
    }
    map
}

/// The remote whose bookmarks define "pushed". Deliberately just `origin`, not every remote: a commit
/// sitting on a stale backup/fork remote is NOT on the project's shared repo, and the badge claims the
/// latter. Origin-only also excludes jj's pseudo-remote `git` by construction — in a colocated repo
/// every LOCAL git branch is mirrored as `<name>@git` and marked tracked, so counting that remote would
/// make every local commit read `Pushed`.
const PUSH_REMOTE: &str = "origin";

/// `origin`'s tracked, present bookmark tips + their names (for the tooltip scope). Untracked remote
/// bookmarks are skipped: jj only reconciles a remote bookmark with its local counterpart while it's
/// tracked, so an untracked one says nothing about where local work lives.
fn origin_tips(repo: &ReadonlyRepo) -> (Vec<jj_lib::backend::CommitId>, Vec<String>) {
    let mut tips = Vec::new();
    let mut names = Vec::new();
    for (symbol, remote_ref) in repo.view().all_remote_bookmarks() {
        if symbol.remote.as_str() != PUSH_REMOTE || !remote_ref.is_tracked() {
            continue;
        }
        if !remote_ref.is_present() {
            continue;
        }
        names.push(format!("{}/{}", PUSH_REMOTE, symbol.name.as_str()));
        tips.extend(remote_ref.target.added_ids().cloned());
    }
    (tips, names)
}

/// The comparison scope for tooltip copy: name the single origin bookmark when there is exactly one,
/// otherwise just the count. `None` when there is nothing to compare against (⇒ `PushState::Unknown`).
fn push_scope(names: Vec<String>) -> Option<model::PushScope> {
    if names.is_empty() {
        return None;
    }
    let count = names.len() as u32;
    let ref_name = if names.len() == 1 {
        names.into_iter().next()
    } else {
        None
    };
    Some(model::PushScope { ref_name, count })
}

/// `ancestors(tips)` evaluated ONCE, so membership is a cheap per-commit lookup instead of an
/// N-commits × M-tips `is_ancestor` sweep. The default index's `PositionsAccumulator` consumes the
/// underlying walk INCREMENTALLY and stops at the queried position, so this never materializes the
/// whole history. `None` ⇒ nothing to compare against, or the revset failed to evaluate; either way the
/// caller must report `Unknown` (never `Unpushed` — a missing badge beats a wrong one).
///
/// The returned revset borrows `repo`, and `Revset::containing_fn` in turn borrows the revset, so the
/// caller has to keep this value alive while it queries. Hence two steps rather than one helper
/// returning the closure.
fn pushed_revset<'a>(
    repo: &'a dyn Repo,
    tips: &[jj_lib::backend::CommitId],
) -> Option<Box<dyn Revset + 'a>> {
    if tips.is_empty() {
        return None;
    }
    let expr: Arc<ResolvedRevsetExpression> = RevsetExpression::commits(tips.to_vec()).ancestors();
    expr.evaluate(repo).ok()
}

/// `push_of` for the call paths that don't measure push state (the working-copy `CommitChanges`
/// disclosure, which has no such field).
fn unknown_push(_: &jj_lib::backend::CommitId) -> model::PushState {
    model::PushState::Unknown
}

/// Map a `containing_fn` membership probe's result to `PushState` — the match ladder `log_page`
/// and `changeset` each independently hand-rolled inside their `push_of` closure. Generic over the
/// probe's error type so this stays a pure mapper with no jj-lib closure/lifetime to name; a
/// membership read that errors is `Unknown`, never `Unpushed` (a missing badge beats a wrong one),
/// same as `None` (nothing to compare against — see `pushed_revset`).
fn push_state_of<E>(result: Option<Result<bool, E>>) -> model::PushState {
    match result {
        None => model::PushState::Unknown,
        Some(Ok(true)) => model::PushState::Pushed,
        Some(Ok(false)) => model::PushState::Unpushed,
        Some(Err(_)) => model::PushState::Unknown,
    }
}

/// jj's short change-id for display: the reverse-hex ("z-k" digit) form truncated to the shortest
/// prefix that still uniquely resolves in this repo — exactly what `jj log` shows (e.g. `wo`, `znl`),
/// rather than the full 32-digit hex. The empty prefix index falls back to the repo's own index +
/// ref disambiguation, matching the CLI's default (no `--revisions` narrowing).
fn short_change_id(repo: &dyn Repo, change_id: &ChangeId) -> String {
    let full = encode_reverse_hex(change_id.as_bytes());
    let len = IdPrefixIndex::empty()
        .shortest_change_prefix_len(repo, change_id)
        .unwrap_or(full.len())
        .clamp(1, full.len());
    full.chars().take(len).collect()
}

/// Build one model commit from a jj commit, WITHOUT resolving divergence (`divergent_siblings`
/// empty). `change_offset` is the caller-supplied `/N` offset (set only for members of a divergent
/// set). Used both for page commits and for the sibling copies nested under them.
///
/// `push_of` is threaded down rather than applied by the caller afterwards: divergent siblings are
/// built in here, so a post-hoc assignment on the returned commit would leave every sibling `Unknown`.
fn build_commit(
    c: &JjCommit,
    wc_id: Option<&jj_lib::backend::CommitId>,
    bookmarks: &HashMap<String, Vec<String>>,
    repo: &dyn Repo,
    change_offset: Option<u32>,
    push_of: &dyn Fn(&jj_lib::backend::CommitId) -> model::PushState,
) -> Commit {
    let commit_id = c.id().hex();
    let (author, ts_ms, tz) = author_of(c.author());
    let desc = c.description();
    let summary = desc.lines().next().unwrap_or("").to_string();
    let body = desc
        .lines()
        .skip(1)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    Commit {
        short_id: commit_id.chars().take(8).collect(),
        change_id: Some(short_change_id(repo, c.change_id())),
        summary,
        body,
        authors: vec![author],
        timestamp_ms: ts_ms,
        tz_offset_secs: tz,
        refs: bookmarks.get(&commit_id).cloned().unwrap_or_default(),
        parent_ids: c.parent_ids().iter().map(|id| id.hex()).collect(),
        is_working_copy: wc_id.map(|w| w == c.id()).unwrap_or(false),
        // The virtual root commit, asked of the store rather than pattern-matched on an all-zero hex
        // id — that spelling is the git backend's encoding of it, not the definition. Set here (not in
        // `log_page`) so every path that builds a jj commit carries it.
        is_root: c.id() == repo.store().root_commit_id(),
        change_offset,
        divergent_siblings: Vec::new(),
        push_state: push_of(c.id()),
        commit_id,
    }
}

fn to_model_commit(
    c: &JjCommit,
    wc_id: Option<&jj_lib::backend::CommitId>,
    bookmarks: &HashMap<String, Vec<String>>,
    repo: &dyn Repo,
    push_of: &dyn Fn(&jj_lib::backend::CommitId) -> model::PushState,
) -> Commit {
    // Divergence: does this change-id resolve to more than one *visible* commit? Only one copy of a
    // divergent change is an ancestor of `@`, so the `::@` walk shows just that one; jj addresses
    // each copy by a `/N` offset (its position among all — hidden included — commits sharing the
    // change-id, hence non-contiguous). Resolving against the whole repo (not just this page) is what
    // makes it a true divergence check; the change-id index is built lazily, exactly like `jj log`.
    let targets = repo.resolve_change_id(c.change_id()).ok().flatten();
    let divergent = targets.as_ref().is_some_and(|t| t.is_divergent());
    let self_offset = targets
        .as_ref()
        .and_then(|t| t.find_offset(c.id()))
        .map(|o| o as u32);
    let mut commit = build_commit(
        c,
        wc_id,
        bookmarks,
        repo,
        if divergent { self_offset } else { None },
        push_of,
    );
    // Surface the OTHER visible copies (the divergent siblings) so the UI can reveal them — they sit
    // off `::@` and are otherwise invisible in the log. Load each and carry its own `/N` offset.
    if divergent {
        if let Some(targets) = &targets {
            let store = repo.store();
            for (offset, sibling_id) in targets.visible_with_offsets() {
                if sibling_id == c.id() {
                    continue;
                }
                if let Ok(sibling) = store.get_commit(sibling_id) {
                    commit.divergent_siblings.push(build_commit(
                        &sibling,
                        wc_id,
                        bookmarks,
                        repo,
                        Some(offset as u32),
                        push_of,
                    ));
                }
            }
        }
    }
    commit
}

/// `::id` as a revset, which is how both ancestry walks in this module get their ORDER.
///
/// jj-lib's default index iterates every revset in descending global commit position, and a commit's
/// position is always greater than its parents' — so the walk is topological, children before
/// parents, exactly the order `jj log` prints. Committer timestamps are deliberately not consulted:
/// they are metadata a rewrite carries forward, so an amend, a rebase, an imported commit or plain
/// clock skew puts them out of graph order. The timestamp-keyed max-heap this replaced would then
/// interleave the page differently from `jj log` and pick the wrong "nearest" bookmark.
///
/// Cheap on large repos, because the walk is LAZY: `Revset::stream` is `stream::iter` over the
/// index's `RevWalk`, which advances only as far as it is polled (the same incremental property
/// `pushed_revset` documents). It also yields ids, not commits, so nothing is deserialized for
/// commits the caller ends up dropping.
fn ancestors_revset<'a>(
    repo: &'a dyn Repo,
    id: &jj_lib::backend::CommitId,
) -> model::Result<Box<dyn Revset + 'a>> {
    let expr: Arc<ResolvedRevsetExpression> =
        RevsetExpression::commits(vec![id.clone()]).ancestors();
    expr.evaluate(repo).map_err(io)
}

/// Drive `revset`'s stream to at most `limit` ids, in the revset's own order. The stream is async
/// only in shape — the walk underneath is synchronous — so it's blocked on with pollster like the
/// rest of this module. An id that fails to read is an error, never a silently short page.
fn take_revset_ids<'a, R: Revset + ?Sized + 'a>(
    revset: &'a R,
    limit: usize,
) -> model::Result<Vec<jj_lib::backend::CommitId>> {
    use futures::StreamExt;

    pollster::block_on(async {
        let mut ids = Vec::with_capacity(limit);
        let mut stream = revset.stream();
        while ids.len() < limit {
            match stream.next().await {
                Some(id) => ids.push(id.map_err(io)?),
                None => break,
            }
        }
        Ok(ids)
    })
}

/// A bounded page of `::@` ancestry in `jj log`'s own order — topological, children before parents
/// (see `ancestors_revset`, which owns that guarantee). Only reads ~`limit` commits (NOT the whole
/// history), so it's cheap on large repos.
pub fn log_page(root: &Path, limit: usize) -> model::Result<HistoryPage> {
    let (workspace, repo) = open(root)?;
    let store = repo.store();
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .cloned();

    let bookmarks = bookmark_map(&repo);
    // Push state: one `ancestors(origin tips)` revset for the whole page (see `pushed_revset`). Held in
    // this scope because `containing_fn` borrows it.
    let (tips, tip_names) = origin_tips(&repo);
    let pushed = pushed_revset(repo.as_ref(), &tips);
    let contains = pushed.as_ref().map(|r| r.containing_fn());
    let push_of = |id: &jj_lib::backend::CommitId| push_state_of(contains.as_ref().map(|f| f(id)));
    let scope = push_scope(tip_names);

    let Some(wc_id) = wc_id else {
        // No working-copy commit (a bare/foreign workspace) — nothing to page over.
        return Ok(HistoryPage {
            commits: Vec::new(),
            reached_end: true,
            push_scope: scope,
        });
    };

    // Ask for one id PAST the page: getting it proves there's more history (so `reached_end` is
    // false) and it's then dropped. The revset dedupes, so the `seen` set the heap needed is gone.
    let revset = ancestors_revset(repo.as_ref(), &wc_id)?;
    let mut ids = take_revset_ids(revset.as_ref(), limit.saturating_add(1))?;
    let reached_end = ids.len() <= limit;
    ids.truncate(limit);

    let commits = ids
        .iter()
        .map(|id| {
            let commit = store.get_commit(id).map_err(io)?;
            Ok(to_model_commit(
                &commit,
                Some(&wc_id),
                &bookmarks,
                repo.as_ref(),
                &push_of,
            ))
        })
        .collect::<model::Result<Vec<_>>>()?;

    Ok(HistoryPage {
        commits,
        reached_end,
        push_scope: scope,
    })
}

/// The repo's current ref for the sidebar label (read-only; no snapshot/lock — same `open` path as
/// the log). A bookmark directly on the working copy `@` ⇒ `Branch`; else the bookmark on the first
/// bookmarked commit the `::@` walk reaches, in `jj log` order ⇒ `Ancestor`; else `None`. That is the
/// first bookmark History shows, which is not necessarily the graph-nearest one — see
/// `first_bookmark_in_log_order`. jj never reports `Detached` (that's a git concept). When a commit
/// carries several bookmarks the alphabetically-first is chosen, matching the jj CLI's sorted
/// `bookmarks` template.
pub fn current_ref(root: &Path) -> model::Result<model::Ref> {
    let (workspace, repo) = open(root)?;
    let bookmarks = bookmark_map(&repo);
    let none = model::Ref {
        name: None,
        kind: model::RefKind::None,
    };
    let Some(wc_id) = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .cloned()
    else {
        return Ok(none);
    };
    match first_bookmark_in_log_order(repo.as_ref(), &wc_id, &bookmarks)? {
        Some((name, true)) => Ok(model::Ref {
            name: Some(name),
            kind: model::RefKind::Branch,
        }),
        Some((name, false)) => Ok(model::Ref {
            name: Some(name),
            kind: model::RefKind::Ancestor,
        }),
        None => Ok(none),
    }
}

/// The first bookmark in `::@`'s **log order**: `(name, on_working_copy)` — the alphabetically-first
/// bookmark on `@` itself (`on == true`), else the one on the first bookmarked commit the `::@` walk
/// reaches (`on == false`), else `None`. Shared by `current_ref` (the sidebar label) and
/// `working_status` (`branch_for_ci`).
///
/// **The guarantee is log order, not graph distance**, and the name says so because the two really do
/// differ. `::@` is iterated in descending index position (see `ancestors_revset`) — topological, but
/// not breadth-first: at a merge the walk drains whichever side holds the higher positions before it
/// touches the other. Worked example, verified against `jj log -r ::@`: given `base → P1[main]` and
/// `base → Q[feature] → P2`, with `@ = merge(P1, P2)`, this answers `feature` — two hops away, down
/// the SECOND parent — even though `main` sits on `@`'s own first parent, one hop away.
///
/// That answer is the intended one: it is precisely the first bookmark the user sees walking down
/// History, so the sidebar's label always names a row that is visibly there. What it is NOT is a
/// proximity guarantee, and the one consumer that could be misread as needing one is
/// `working_status`'s `branch_for_ci` — see the note at that call site.
///
/// `@` needs no special case: `::@` is walked children-before-parents and `@` is a descendant of
/// everything else in the set, so `@` is always the first id out — which is also what makes the
/// `on_working_copy` flag just an id comparison.
///
/// Ordering matters here as much as in the log. Under the timestamp walk this replaced, a bookmark
/// on a freshly-rewritten commit deeper in the ancestry could outrank an earlier one whose timestamp
/// the rewrite left behind, so the sidebar named a branch the history didn't show.
///
/// Cost: this walks ids only — it stops at the first bookmarked commit and never loads a commit
/// object, where the old heap deserialized every ancestor it passed. That matters because
/// `working_status` calls this on every 15s status sweep, fanned out per workroom.
fn first_bookmark_in_log_order(
    repo: &dyn Repo,
    wc_id: &jj_lib::backend::CommitId,
    bookmarks: &HashMap<String, Vec<String>>,
) -> model::Result<Option<(String, bool)>> {
    use futures::StreamExt;

    if bookmarks.is_empty() {
        return Ok(None);
    }
    let revset = ancestors_revset(repo, wc_id)?;
    pollster::block_on(async {
        let mut stream = revset.stream();
        while let Some(id) = stream.next().await {
            let id = id.map_err(io)?;
            if let Some(name) = bookmarks
                .get(&id.hex())
                .and_then(|names| names.iter().min().cloned())
            {
                return Ok(Some((name, &id == wc_id)));
            }
        }
        Ok(None)
    })
}

/// Map a jj commit + its changed files to a `CommitChanges` disclosure record (reuses
/// `to_model_commit` for identity/description so it matches the log/changeset display).
fn commit_changes(
    commit: &JjCommit,
    files: Vec<model::ChangedFile>,
    bookmarks: &HashMap<String, Vec<String>>,
    repo: &dyn Repo,
) -> model::CommitChanges {
    let c = to_model_commit(commit, None, bookmarks, repo, &unknown_push);
    model::CommitChanges {
        change_id: c.change_id,
        commit_id: Some(c.short_id),
        refs: c.refs,
        description: if c.summary.is_empty() {
            None
        } else {
            Some(c.summary)
        },
        files,
    }
}

/// Base (non-tracked-tree) gitignores for the snapshot: the git global excludes and the repo-local
/// `.git/info/exclude`, mirroring what the jj CLI feeds `SnapshotOptions`. Without these, an
/// auto-status snapshot would *track* a file the user globally-ignores (e.g. a `.env` matched by
/// `~/.config/git/ignore`) into `@`. jj-lib's snapshot walk always chains the in-tree `.gitignore`
/// files on top of this base, so `node_modules` etc. stay ignored regardless.
///
/// Residual gap vs. the CLI: a custom `core.excludesFile` set in git config is not read (that needs
/// a git-config parse); only git's default XDG location (`$XDG_CONFIG_HOME/git/ignore`, i.e.
/// `~/.config/git/ignore`) is honored. Tracked as a follow-up.
fn base_ignores(root: &Path) -> Arc<GitIgnoreFile> {
    use jj_lib::repo_path::RepoPath;
    let mut ignores = GitIgnoreFile::empty();
    let chain = |ignores: Arc<GitIgnoreFile>, file: PathBuf| -> Arc<GitIgnoreFile> {
        // chain_with_file no-ops when the file is absent; on a read error keep what we have.
        ignores
            .chain_with_file(RepoPath::root(), file)
            .unwrap_or(ignores)
    };
    let xdg = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")));
    if let Some(dir) = xdg {
        ignores = chain(ignores, dir.join("git/ignore"));
    }
    chain(ignores, root.join(".git/info/exclude"))
}

/// Is the working-copy lock currently held by someone else?
///
/// `Workspace::start_working_copy_mutation` takes that lock through jj-lib's `FileLock::lock`, which
/// **blocks on `flock` forever** and never reports contention — so a `jj` command the user runs in a
/// workroom terminal (a long `jj rebase`, or `jj log` in a huge repo) would stall the status sweep's
/// snapshot for its whole duration, holding a GCD thread and the project's `JJSnapshotGate` slot,
/// with every other workroom of that project queued behind it. A non-blocking `try_lock` probe first
/// turns that into an instant, typed `LockContention` — the row reports "busy" and the next refresh
/// (15s) tries again.
///
/// Best-effort by construction, and safe in both directions: a `None` (held) answer can only be
/// produced by a real holder, and a `Some` answer can go stale the moment we drop the probe lock —
/// in which case we simply block as before. Dropping our own probe lock deletes the lock file, which
/// is jj's own protocol (its `FileLock::drop` does the same, and waiters re-create it).
///
/// Skipped unless this is a `LocalWorkingCopy`: the lock path is jj's on-disk layout for the local
/// backend (`<workspace>/.jj/working_copy/working_copy.lock`, `DefaultWorkspaceLoader` in the pinned
/// jj-lib), which a custom working-copy backend needn't share. A missing lock file means nobody has
/// locked it, so the common case costs one `exists()`.
fn lock_is_held(workspace: &Workspace) -> bool {
    if workspace.working_copy().name() != LocalWorkingCopy::name() {
        return false;
    }
    let path = workspace
        .workspace_root()
        .join(".jj")
        .join("working_copy")
        .join("working_copy.lock");
    if !path.exists() {
        return false;
    }
    // `Err` ⇒ we couldn't probe (permissions, an odd filesystem); don't invent contention — let
    // `start_working_copy_mutation` produce the real error (or block, as it did before).
    matches!(FileLock::try_lock(path), Ok(None))
}

/// Snapshot the working copy so `@` reflects on-disk edits, returning the repo at the resulting
/// operation. Unlike the read-only `open`, this MUTATES (exactly like every `jj` command): it takes
/// the working-copy lock, and when disk differs from `@`'s tree it rewrites `@`, rebases descendants,
/// and commits a "snapshot working copy" operation. Modeled on jayjay's `refresh_working_copy`.
///
/// `base_ignores` chains the global + repo-local excludes (see `base_ignores`); `max_new_file_size`
/// matches the jj CLI default (1 MiB) so a status refresh can't hash/store an arbitrarily huge
/// untracked file.
fn snapshot_working_copy(root: &Path) -> model::Result<(Workspace, Arc<ReadonlyRepo>)> {
    let settings = crate::jj_config::user_settings()?;
    let mut workspace = Workspace::load(
        &settings,
        root,
        &StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .map_err(workspace_load_err)?;
    let mut repo = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(io)?;

    let wc_name = workspace.workspace_name().to_owned();
    let Some(wc_commit_id) = repo.view().get_wc_commit_id(&wc_name).cloned() else {
        // No working-copy commit (e.g. a bare/foreign workspace) — nothing to snapshot.
        return Ok((workspace, repo));
    };
    let mut wc_commit = repo.store().get_commit(&wc_commit_id).map_err(io)?;

    // Fail fast when someone else holds the working-copy lock (see `lock_is_held`) — a blocking
    // `flock` here would pin this thread, and a gate slot, for as long as the other process runs.
    if lock_is_held(&workspace) {
        return Err(VcsError::LockContention);
    }

    let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(io)?;

    // jj's own staleness guard, which every `jj` command runs and this read used to skip. The lock is
    // taken AFTER the repo was loaded, so between the two another process (the user's `jj` in a
    // terminal, or a sibling *workspace* of the same repo — i.e. another workroom — rewriting this
    // `@`) can have moved things underneath us. Snapshotting anyway would write a new `@` from a base
    // that no longer describes this working copy, which is how work gets clobbered.
    let freshness = pollster::block_on(WorkingCopyFreshness::check_stale(
        locked_ws.locked_wc(),
        &wc_commit,
        &repo,
    ))
    .map_err(io)?;
    match freshness {
        WorkingCopyFreshness::Fresh => {}
        // The working copy is AHEAD of the repo we loaded (something updated it in the gap). Not an
        // error — reload the repo at the working copy's own operation and carry on, exactly as the jj
        // CLI does, so a `jj` command racing the status sweep doesn't flash a failure in the sidebar.
        WorkingCopyFreshness::Updated(wc_operation) => {
            repo = pollster::block_on(repo.reload_at(&wc_operation)).map_err(io)?;
            let Some(id) = repo.view().get_wc_commit_id(&wc_name).cloned() else {
                drop(locked_ws); // release the lock before handing the workspace back
                return Ok((workspace, repo));
            };
            wc_commit = repo.store().get_commit(&id).map_err(io)?;
        }
        // Genuinely stale (`@` was rewritten/abandoned by another workspace) or divergent. Both are
        // `StaleSnapshot`: reporting a recoverable error beats snapshotting from a stale base. The
        // stale case is what `jj workspace update-stale` exists to repair — we deliberately don't run
        // it here, since recovering a working copy is a write the user hasn't asked for.
        WorkingCopyFreshness::WorkingCopyStale | WorkingCopyFreshness::SiblingOperation => {
            return Err(VcsError::StaleSnapshot);
        }
    }

    let options = SnapshotOptions {
        base_ignores: base_ignores(root),
        progress: None,
        start_tracking_matcher: &EverythingMatcher,
        force_tracking_matcher: &NothingMatcher,
        max_new_file_size: 1024 * 1024, // 1 MiB — the jj CLI default (snapshot.max-new-file-size)
    };
    let (new_tree, _stats) =
        pollster::block_on(locked_ws.locked_wc().snapshot(&options)).map_err(io)?;

    if new_tree.tree_ids_and_labels() != wc_commit.tree().tree_ids_and_labels() {
        // Disk changed since the last snapshot → rewrite `@` with the new tree + commit the op.
        let mut tx = repo.start_transaction();
        tx.set_is_snapshot(true);
        let write = tx
            .repo_mut()
            .rewrite_commit(&wc_commit)
            .set_tree(new_tree)
            .write();
        pollster::block_on(write).map_err(io)?;
        pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(io)?;
        let new_repo = pollster::block_on(tx.commit("snapshot working copy")).map_err(io)?;
        pollster::block_on(locked_ws.finish(new_repo.op_id().clone())).map_err(io)?;
        Ok((workspace, new_repo))
    } else {
        // Clean — release the lock without rewriting `@`.
        pollster::block_on(locked_ws.finish(repo.op_id().clone())).map_err(io)?;
        Ok((workspace, repo))
    }
}

/// The jj working-copy status: snapshot `@` (so it reflects disk), then read its change set, the
/// parent `@-` state, and the CI branch. `dirty` is set when `@` has changed files or a conflict.
/// (`insertions`/`deletions` come from this same read via `changed_files` — there is no second
/// `jj diff --stat` pass, Swift-side or otherwise.)
pub fn working_status(root: &Path) -> model::Result<model::WorkingStatus> {
    let (workspace, repo) = snapshot_working_copy(root)?;
    let store = repo.store();
    let bookmarks = bookmark_map(&repo);
    let Some(wc_id) = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .cloned()
    else {
        return Ok(model::WorkingStatus {
            conflicted: false,
            working_copy: model::CommitChanges {
                change_id: None,
                commit_id: None,
                refs: Vec::new(),
                description: None,
                files: Vec::new(),
            },
            branch_for_ci: None,
        });
    };
    let wc_commit = store.get_commit(&wc_id).map_err(io)?;
    let conflicted = wc_commit.has_conflict();
    let wc_files = changed_files(store, &wc_commit)?;
    let working_copy = commit_changes(&wc_commit, wc_files, &bookmarks, repo.as_ref());

    // NB: the parent `@-` change set is deliberately NOT computed — it would re-walk a second tree
    // diff on every status poll (fanned out per-workroom on a 15s sweep) for a disclosure group the
    // Changes panel no longer shows. If a parent view returns, compute it lazily on demand, not here.
    // Read this as "the branch History labels this workroom with", NOT "the branch nearest `@`" and
    // NOT "the branch this work will land on". It is the first bookmark in `::@` log order, which
    // down a merge's second parent can be strictly farther away in hops than a bookmark on `@`'s own
    // first parent (worked example in `first_bookmark_in_log_order`). Deliberately the very same call
    // the sidebar label makes: one answer from one place, so a CI/PR badge can never contradict the
    // branch name printed beside it. A consumer that genuinely needs the closest bookmark wants a
    // different walk, not this one.
    let branch_for_ci =
        first_bookmark_in_log_order(repo.as_ref(), &wc_id, &bookmarks)?.map(|(name, _)| name);

    Ok(model::WorkingStatus {
        conflicted,
        working_copy,
        branch_for_ci,
    })
}

/// A single changeset: metadata + full message + changed-file list (vs the first parent). Per-file
/// hunk-level diff is a separate call (lazy on selection).
pub fn changeset(root: &Path, commit_id_hex: &str) -> model::Result<model::Changeset> {
    let (_workspace, repo) = open(root)?;
    let store = repo.store();
    let id = jj_lib::backend::CommitId::try_from_hex(commit_id_hex)
        .ok_or_else(|| VcsError::NotFound(format!("bad commit id {commit_id_hex}")))?;
    let commit = store.get_commit(&id).map_err(io)?;
    let bookmarks = bookmark_map(&repo);
    let files = changed_files(store, &commit)?;
    // Same push-state read as the log, for one commit — the detail header shows it too.
    let (tips, tip_names) = origin_tips(&repo);
    let pushed = pushed_revset(repo.as_ref(), &tips);
    let contains = pushed.as_ref().map(|r| r.containing_fn());
    let push_of = |id: &jj_lib::backend::CommitId| push_state_of(contains.as_ref().map(|f| f(id)));
    let model_commit = to_model_commit(&commit, None, &bookmarks, repo.as_ref(), &push_of);
    Ok(model::Changeset {
        is_merge: commit.parent_ids().len() > 1,
        full_message: commit.description().to_string(),
        files,
        commit: model_commit,
        push_scope: push_scope(tip_names),
    })
}

/// The changed files of `commit` vs its FIRST parent (the jj root commit provides the empty base for
/// the first real change, so no empty-tree special case is needed). Conflict from an unresolved
/// `after` value, then rename/copy from the backend's copy records, then add/modify/delete from
/// before↔after presence. Drives jj-lib's async tree `diff_stream_with_copies`, blocked on with
/// pollster.
///
/// Both callers share this: the working copy (`working_status`) *and* a historical changeset
/// (`changeset`). That's deliberate — jj stores conflicts in the tree, so a *commit* can be
/// conflicted, which git can't represent. `GitProvider` therefore reports `modified` where this
/// reports `conflicted` for the same colocated commit; `VCSProviderConformanceTests` asserts that
/// divergence explicitly rather than treating it as a parity break.
fn changed_files(
    store: &std::sync::Arc<jj_lib::store::Store>,
    commit: &JjCommit,
) -> model::Result<Vec<model::ChangedFile>> {
    use futures::StreamExt;

    let after = commit.tree();
    let (before, parent_id) = match commit.parent_ids().first() {
        Some(pid) => (store.get_commit(pid).map_err(io)?.tree(), pid.clone()),
        None => return Ok(Vec::new()), // the jj root commit itself
    };
    let copy_records = copy_records(store, &parent_id, commit.id());

    let materialize = materialize_options()?;

    pollster::block_on(async {
        let mut files = Vec::new();
        // MATERIALIZED, not raw tree values: the same stream has to answer both questions this
        // function reports — the change kind (tree values would do) and the ± line counts (which need
        // content). Reading content on a second pass is what the app used to do via a separate
        // `jj diff --stat` process, and that's precisely the bug: two reads of a moving working copy
        // disagree, and `-r @` on a merge doesn't even use the same base as this tree diff.
        let tree_diff = before
            .diff_stream_with_copies(&after, &EverythingMatcher, &copy_records)
            .boxed();
        let labels = Diff {
            before: &UNLABELED_CONFLICT,
            after: &UNLABELED_CONFLICT,
        };
        let mut stream = materialized_diff_stream(store, tree_diff, labels);
        while let Some(entry) = stream.next().await {
            // With copy records in play, an entry's identity is its TARGET path; `source()` is the
            // pre-rename path (and returns the target when the path wasn't renamed/copied, hence the
            // `copy_operation()` gate below).
            let path = entry.path.target().as_internal_file_string().to_string();
            let copy_op = entry.path.copy_operation();
            // The change-kind ladder itself (conflict-before-rename, rename-before-presence, and
            // why) is documented once on the shared `classify_kind`. Reading the kind off
            // MATERIALIZED values keeps every one of its branches intact: an unresolved merge
            // materializes to `FileConflict`/`OtherConflict` (never to `Absent`, the same reason
            // `is_absent()` didn't catch it), and an absent side to `Absent`. `AccessDenied` is a
            // present-but-unreadable value, so it stays a `Modified` as before — with `None`
            // counts, since there's no content to compare.
            let old_path = copy_op
                .map(|_| entry.path.source().as_internal_file_string().to_string())
                .filter(|source| *source != path);
            // `entry.values` folds BOTH failures into one `Err`: the tree walk couldn't read the
            // entry at all, or it could but materializing the file's CONTENT failed. They deserve
            // different answers, so they're told apart here rather than both aborting the read.
            //
            // Materializing is what made content failures reachable in the first place — the tree
            // diff this replaced only ever read tree objects. A single unreadable blob (blobless or
            // partial clone, a pruned object, a gc/repack race) would otherwise fail the WHOLE
            // status read, and `WorkroomStatusResolver.failure(for:)` maps `.partialData` to
            // `.notRepository` — so one bad object made the sidebar and Changes panel both report
            // "Not a repository." for a workroom that is fine apart from that one file.
            let (kind, stats) = match entry.values {
                Ok(diff) => {
                    let kind = classify_kind(
                        is_conflict(&diff.after),
                        copy_op,
                        diff.before.is_absent(),
                        diff.after.is_absent(),
                    );
                    let stats =
                        line_stats(entry.path.source(), entry.path.target(), diff, &materialize)
                            .await;
                    (kind, stats)
                }
                // Re-read the two sides as raw tree values: that's tree objects only, no blob, so it
                // succeeds exactly when the failure was the content. The row still lands with its
                // real kind and `None` counts — which is already what `None` means everywhere else
                // here (binary, oversized, unreadable). If the TREE read fails too, the entry really
                // is unreadable and `PartialData` is right: dropping it would report a changed file
                // as absent, i.e. a dirty commit as clean.
                Err(content_err) => {
                    let unreadable = |e| {
                        VcsError::PartialData(format!(
                            "diff read failed for {path}: {e} (after: {content_err})"
                        ))
                    };
                    let before_value = before
                        .path_value(entry.path.source())
                        .await
                        .map_err(unreadable)?;
                    let after_value = after
                        .path_value(entry.path.target())
                        .await
                        .map_err(unreadable)?;
                    (raw_kind(&before_value, &after_value, copy_op), None)
                }
            };
            files.push(model::ChangedFile {
                path,
                old_path,
                kind,
                line_stats: stats.map(|(insertions, deletions)| model::LineStats {
                    insertions,
                    deletions,
                }),
            });
        }
        Ok(files)
    })
}

/// Conflict sides are materialized WITHOUT labels: labels change the text inside a conflict marker,
/// never the number of marker lines, so they can't move a line count — and leaving them off keeps
/// this path independent of `ui.conflict-marker-style` labelling.
const UNLABELED_CONFLICT: ConflictLabels = ConflictLabels::unlabeled();

/// Byte ceiling for counting one file's changed lines. A side over it reports `None` (like a binary
/// one) instead of being diffed: `changed_files` runs in the 15s status sweep, fanned out per
/// workroom, so line-tokenizing a generated/vendored blob on every poll is a per-workroom CPU and
/// memory spike for a number nobody reads.
///
/// **What this actually bounds, and what it doesn't.** It bounds what we KEEP and what we DIFF, not
/// what the backend reads. jj exposes no length-before-read API, so by the time a size is knowable
/// the bytes already exist:
///
/// - `MaterializedTreeValue::File` hands us an `AsyncRead`, but for the git backend that reader is a
///   `Cursor` over a `Vec` the backend already filled — `GitBackend::read_file` calls
///   `read_file_sync`, which fetches the whole blob (`git_backend.rs`). The
///   `.take(MAX_COUNTED_BYTES + 1)` in `side_content` therefore caps only the COPY into our buffer
///   (the `+ 1` being the byte that proves "over"); it cannot un-read the blob.
/// - `MaterializedTreeValue::FileConflict` is worse: `extract_as_single_hunk` has already read EVERY
///   conflict side in full before we see the value, and the text we measure is the merge of them.
///   So the check on that arm is purely "don't diff this", and it's applied after the materialize.
///
/// jj has the same gap and says so — `diff_presentation::file_content_for_diff` carries a TODO that
/// it looks "at the whole file, even though for binary files we only need to know the file size. To
/// change that we'd have to extend all the data backends to support getting the length." Closing it
/// here would mean the same backend change, so this is a deliberate ceiling on the expensive half
/// (retention + the O(lines) diff), not a guarantee about peak allocation during the read. The
/// transient copy is bounded in practice by the object being one file in one tree entry, processed
/// one at a time and dropped at the end of the arm.
const MAX_COUNTED_BYTES: u64 = 4 * 1024 * 1024;

/// jj's own binary heuristic, mirrored from `diff_presentation::file_content_for_diff`: a NUL byte in
/// the first 8k. (That helper isn't used directly because it reads the whole file before deciding,
/// which is exactly what `MAX_COUNTED_BYTES` exists to avoid.)
fn looks_binary(content: &[u8]) -> bool {
    const PEEK_SIZE: usize = 8000;
    content[..PEEK_SIZE.min(content.len())].contains(&b'\0')
}

fn is_conflict(value: &MaterializedTreeValue) -> bool {
    matches!(
        value,
        MaterializedTreeValue::FileConflict(_) | MaterializedTreeValue::OtherConflict { .. }
    )
}

/// The shared 5-way change-kind classification ladder — used against MATERIALIZED values in
/// `changed_files` and against RAW tree values in `raw_kind` (the fallback for a file whose
/// content wouldn't materialize); only the two predicates' *source* differs between those call
/// sites, not this ordering.
///
/// Conflict FIRST: an unresolved merge on the "after" side *is* the conflict, and it never
/// satisfies an absence check (materialized: `is_absent()` is `Some(None)`, a *resolved* absence;
/// raw: `is_resolved()` on an unmerged value), so without this branch a conflicted file reads as a
/// plain `Modified`. Ordering:
/// - after unresolved + before absent (both sides added) → Conflicted, not Added (git's `AA`)
/// - before unresolved + after absent (conflict then deleted) → Deleted; nothing to resolve
/// - before unresolved + after resolved (conflict resolved) → Modified
///
/// Rename/copy comes SECOND, ahead of the presence tests: a rename's target is absent in `before`,
/// so without this branch it reads as a plain `Added` (and jj-lib has already dropped the paired
/// delete entry, so the old path would vanish entirely).
///
/// Conflicted-before-rename is defensive ordering only: a conflicted path can't currently carry a
/// copy record at all, because records come from each commit's *git* tree and jj exports a
/// conflicted commit as `.jjconflict-*` sidecar trees — so gix's rewrite detection finds no blob to
/// pair. A conflicted rename therefore decomposes into an `Added` at the new path + a `Conflicted`
/// at the old one (pinned by `a_conflicted_rename_does_not_pair_into_one_row`). If a future jj-lib
/// does pair them, this ordering keeps the conflict badge rather than downgrading it to `Renamed`.
fn classify_kind(
    is_conflict: bool,
    copy_op: Option<CopyOperation>,
    before_absent: bool,
    after_absent: bool,
) -> model::ChangeKind {
    if is_conflict {
        model::ChangeKind::Conflicted
    } else if let Some(op) = copy_op {
        match op {
            CopyOperation::Rename => model::ChangeKind::Renamed,
            CopyOperation::Copy => model::ChangeKind::Copied,
        }
    } else if before_absent {
        model::ChangeKind::Added
    } else if after_absent {
        model::ChangeKind::Deleted
    } else {
        model::ChangeKind::Modified
    }
}

/// The change kind read off RAW tree values — the fallback in `changed_files` for a file whose
/// content wouldn't materialize. Delegates to `classify_kind`'s shared ladder; only the predicates'
/// source differs, because a conflict is an *unresolved* merge before materialization rather than
/// a `FileConflict`/`OtherConflict` value after it.
fn raw_kind(
    before: &MergedTreeValue,
    after: &MergedTreeValue,
    copy_op: Option<CopyOperation>,
) -> model::ChangeKind {
    classify_kind(
        !after.is_resolved(),
        copy_op,
        before.is_absent(),
        after.is_absent(),
    )
}

/// jj's DEFAULT conflict-materialization options (its bundled `misc.toml`: `marker-style = "diff"`,
/// `merge.hunk-level = "line"`, `merge.same-change = "accept"`), read through `UserSettings` rather
/// than hardcoded so a jj-lib default change carries over.
///
/// Defaults-only, consistent with `snapshot_working_copy` — a user config stack would change what
/// gets counted here, and that's tracked as its own item ("The jj snapshot ignores the user's real
/// jj/git config"). Marker STYLE can change a conflict's line count, so if that item lands, this
/// call site wants the real settings too.
fn materialize_options() -> model::Result<ConflictMaterializeOptions> {
    let settings = crate::jj_config::user_settings()?;
    Ok(ConflictMaterializeOptions {
        marker_style: settings.get("ui.conflict-marker-style").map_err(io)?,
        marker_len: None,
        merge: MergeOptions::from_settings(&settings).map_err(io)?,
    })
}

/// The content of one side of a diff entry, or `None` when it deliberately isn't counted: a binary
/// file, one over `MAX_COUNTED_BYTES`, or a non-file entry (symlink target changes, submodule
/// pointers, tree/type conflicts, an unreadable value). `None` propagates to BOTH counts on the file
/// — a half-counted diff would read as a real number while being wrong.
async fn side_content(
    path: &RepoPath,
    value: MaterializedTreeValue,
    options: &ConflictMaterializeOptions,
) -> Option<Vec<u8>> {
    use futures::AsyncReadExt as _;

    match value {
        // An absent side is empty content, which is what makes a whole-file add or delete count as
        // all of its lines — the same answer `jj diff --stat` gives.
        MaterializedTreeValue::Absent => Some(Vec::new()),
        MaterializedTreeValue::File(mut file) => {
            let mut buf = Vec::new();
            (&mut file.reader)
                .take(MAX_COUNTED_BYTES + 1)
                .read_to_end(&mut buf)
                .await
                .ok()?;
            if buf.len() as u64 > MAX_COUNTED_BYTES || looks_binary(&buf) {
                return None;
            }
            Some(buf)
        }
        // A conflict counts its MATERIALIZED text — the markers are what the file's content is, both
        // on disk in a conflicted working copy and in what `jj diff --stat`/`git diff` report for the
        // same state. The app's Changes header says so when `@` is conflicted rather than quietly
        // reporting a one-line conflict as dozens of changed lines.
        //
        // Size-capped like the `File` arm, and for the same reason — a 100 MB conflicted lockfile is
        // no cheaper to line-diff than a 100 MB clean one. The cap can only be applied HERE, after
        // materializing: the sides arrive already read in full (`extract_as_single_hunk`), and it's
        // the merged text — sides plus marker lines — that would be counted, so that is the thing
        // whose length has to clear the bar. See `MAX_COUNTED_BYTES` for what that does and doesn't
        // buy us.
        MaterializedTreeValue::FileConflict(conflict) => {
            let text =
                materialize_merge_result_to_bytes(&conflict.contents, &conflict.labels, options);
            let bytes = text.to_vec();
            if bytes.len() as u64 > MAX_COUNTED_BYTES || looks_binary(&bytes) {
                return None;
            }
            Some(bytes)
        }
        MaterializedTreeValue::AccessDenied(_)
        | MaterializedTreeValue::Symlink { .. }
        | MaterializedTreeValue::OtherConflict { .. }
        | MaterializedTreeValue::GitSubmodule(_)
        | MaterializedTreeValue::Tree(_) => {
            let _ = path; // only used for the reader's error reporting on the File arm
            None
        }
    }
}

/// `(insertions, deletions)` for one changed file, or `None` when either side isn't countable.
///
/// This is the fold the jj CLI does in its own `DiffStats` (`jj-cli`'s `diff_util`, not in `jj-lib`):
/// line-tokenize both sides, then every `Different` hunk contributes its left lines as deletions and
/// its right lines as insertions. A `Matching` hunk is context. Counting `split_inclusive('\n')`
/// segments — rather than `'\n'` occurrences — is what makes a final line with no trailing newline
/// count as a line, matching git and `GitProvider.diffLineStats` on the same file.
async fn line_stats(
    before_path: &RepoPath,
    after_path: &RepoPath,
    values: Diff<MaterializedTreeValue>,
    options: &ConflictMaterializeOptions,
) -> Option<(u32, u32)> {
    let before = side_content(before_path, values.before, options).await?;
    let after = side_content(after_path, values.after, options).await?;

    let mut insertions: u32 = 0;
    let mut deletions: u32 = 0;
    for hunk in diff_by_line([&before, &after], &LineCompareMode::Exact).hunks() {
        if hunk.kind != DiffHunkKind::Different {
            continue;
        }
        let [left, right] = hunk.contents[..].try_into().ok()?;
        deletions += count_lines(left);
        insertions += count_lines(right);
    }
    Some((insertions, deletions))
}

fn count_lines(content: &[u8]) -> u32 {
    content.split_inclusive(|b| *b == b'\n').count() as u32
}

/// The backend's copy/rename records for `parent → commit`, used to turn a delete+add pair into one
/// rename row (jj-lib's `CopiesTreeDiffStream` suppresses the delete once a record exists).
///
/// Backend-dependent by design, and **degrading is correct here**: the git backend implements this
/// (gix rewrite detection, 50% similarity, 1000-candidate limit), while jj's own `simple_backend`
/// returns an empty stream — a non-colocated jj repo therefore reports delete+add, exactly as it does
/// today, rather than erroring. Individual record errors are skipped for the same reason: a lost
/// record costs only the rename *label*, never a file — both paths still appear in the diff, so
/// there's no silent-data-loss risk of the kind the entry-level `PartialData` guard exists to catch.
fn copy_records(
    store: &std::sync::Arc<jj_lib::store::Store>,
    parent_id: &jj_lib::backend::CommitId,
    commit_id: &jj_lib::backend::CommitId,
) -> CopyRecords {
    use futures::StreamExt;

    let mut records = CopyRecords::default();
    if let Ok(stream) = store.get_copy_records(None, parent_id, commit_id) {
        records.add_records(pollster::block_on(
            stream
                .filter_map(|r| std::future::ready(r.ok()))
                .collect::<Vec<_>>(),
        ));
    }
    records
}
