//! jj backend — the ONLY site that touches `jj-lib`.
//!
//! Most reads (`log_page`, `changeset`, `current_ref`) are read-only: they `open` the workspace and
//! `load_at_head`, reading commit data WITHOUT snapshotting/locking the working copy (prior learning
//! `jj-concurrent-probes-working-copy-lock`: jj takes the working-copy lock only on ops that *write*
//! `@`). The exception is `working_status` (`snapshot_working_copy`), which MUST snapshot `@` so it
//! reflects on-disk edits — so it takes the lock + rewrites `@`, exactly like every `jj` command.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::commit::Commit as JjCommit;
use jj_lib::config::StackedConfig;
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::matchers::{EverythingMatcher, NothingMatcher};
use jj_lib::object_id::ObjectId;
use jj_lib::repo::{ReadonlyRepo, Repo, StoreFactories};
use jj_lib::settings::UserSettings;
use jj_lib::working_copy::SnapshotOptions;
use jj_lib::workspace::{default_working_copy_factories, Workspace};

use wr_vcs_model as model;
use wr_vcs_model::{Author, Commit, HistoryPage, VcsError};

fn io<E: std::fmt::Display>(e: E) -> VcsError {
    VcsError::Io(e.to_string())
}

/// Open a workspace read-only and load the repo at the current operation head.
fn open(root: &Path) -> model::Result<(Workspace, Arc<ReadonlyRepo>)> {
    let settings = UserSettings::from_config(StackedConfig::with_defaults()).map_err(io)?;
    let workspace = Workspace::load(
        &settings,
        root,
        &StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .map_err(io)?;
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

/// Build `commit_id_hex -> [bookmark names]` from the repo view's local bookmarks.
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

fn to_model_commit(
    c: &JjCommit,
    wc_id: Option<&jj_lib::backend::CommitId>,
    bookmarks: &HashMap<String, Vec<String>>,
) -> Commit {
    let commit_id = c.id().hex();
    let (author, ts_ms, tz) = author_of(c.author());
    let summary = c.description().lines().next().unwrap_or("").to_string();
    Commit {
        short_id: commit_id.chars().take(8).collect(),
        change_id: Some(c.change_id().hex()),
        summary,
        authors: vec![author],
        timestamp_ms: ts_ms,
        tz_offset_secs: tz,
        refs: bookmarks.get(&commit_id).cloned().unwrap_or_default(),
        parent_ids: c.parent_ids().iter().map(|id| id.hex()).collect(),
        is_working_copy: wc_id.map(|w| w == c.id()).unwrap_or(false),
        commit_id,
    }
}

// Max-heap ordering by committer timestamp then id, so `pop` yields newest-first. (True jj-log
// index-position ordering is a Phase-1 refinement; timestamp-desc is close enough for the proof.)
struct HeapItem(JjCommit);
impl HeapItem {
    fn key(&self) -> (i64, &[u8]) {
        (
            self.0.committer().timestamp.timestamp.0,
            self.0.id().as_bytes(),
        )
    }
}
impl PartialEq for HeapItem {
    fn eq(&self, other: &Self) -> bool {
        self.key() == other.key()
    }
}
impl Eq for HeapItem {}
impl Ord for HeapItem {
    fn cmp(&self, other: &Self) -> Ordering {
        self.key().cmp(&other.key())
    }
}
impl PartialOrd for HeapItem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// A bounded newest-first page of `::@` ancestry. Only visits ~`limit` + frontier commits (NOT the
/// whole history), so it's cheap on large repos.
pub fn log_page(root: &Path, limit: usize) -> model::Result<HistoryPage> {
    let (workspace, repo) = open(root)?;
    let store = repo.store();
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .cloned();

    let bookmarks = bookmark_map(&repo);

    let mut heap: BinaryHeap<HeapItem> = BinaryHeap::new();
    let mut seen: HashSet<Vec<u8>> = HashSet::new();
    if let Some(id) = &wc_id {
        seen.insert(id.as_bytes().to_vec());
        heap.push(HeapItem(store.get_commit(id).map_err(io)?));
    }

    let mut commits = Vec::with_capacity(limit);
    while commits.len() < limit {
        let Some(HeapItem(commit)) = heap.pop() else {
            // Exhausted the reachable graph before filling the page.
            return Ok(HistoryPage {
                commits,
                reached_end: true,
            });
        };
        commits.push(to_model_commit(&commit, wc_id.as_ref(), &bookmarks));
        for parent_id in commit.parent_ids() {
            if seen.insert(parent_id.as_bytes().to_vec()) {
                heap.push(HeapItem(store.get_commit(parent_id).map_err(io)?));
            }
        }
    }
    let reached_end = heap.is_empty();
    Ok(HistoryPage {
        commits,
        reached_end,
    })
}

/// The repo's current ref for the sidebar label (read-only; no snapshot/lock — same `open` path as
/// the log). A bookmark directly on the working copy `@` ⇒ `Branch`; else the nearest ancestor
/// bookmark (walk `@`'s ancestry newest-first, first bookmarked commit wins) ⇒ `Ancestor`; else
/// `None`. jj never reports `Detached` (that's a git concept). When a commit carries several
/// bookmarks the alphabetically-first is chosen, matching the jj CLI's sorted `bookmarks` template.
pub fn current_ref(root: &Path) -> model::Result<model::Ref> {
    let (workspace, repo) = open(root)?;
    let store = repo.store();
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
    match nearest_bookmark(store, &wc_id, &bookmarks)? {
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

/// The nearest bookmark to `@`: `(name, on_working_copy)` — the alphabetically-first bookmark on
/// `@` itself (`on == true`), else the first bookmarked commit walking `@`'s ancestry newest-first
/// (`on == false`), else `None`. Shared by `current_ref` (kind) and `working_status` (CI branch).
fn nearest_bookmark(
    store: &Arc<jj_lib::store::Store>,
    wc_id: &jj_lib::backend::CommitId,
    bookmarks: &HashMap<String, Vec<String>>,
) -> model::Result<Option<(String, bool)>> {
    if bookmarks.is_empty() {
        return Ok(None);
    }
    let pick = |id_hex: &str| -> Option<String> {
        bookmarks
            .get(id_hex)
            .and_then(|names| names.iter().min().cloned())
    };
    if let Some(name) = pick(&wc_id.hex()) {
        return Ok(Some((name, true)));
    }
    let mut seen: HashSet<Vec<u8>> = HashSet::new();
    let mut heap: BinaryHeap<HeapItem> = BinaryHeap::new();
    seen.insert(wc_id.as_bytes().to_vec());
    let wc_commit = store.get_commit(wc_id).map_err(io)?;
    for parent_id in wc_commit.parent_ids() {
        if seen.insert(parent_id.as_bytes().to_vec()) {
            heap.push(HeapItem(store.get_commit(parent_id).map_err(io)?));
        }
    }
    while let Some(HeapItem(commit)) = heap.pop() {
        if let Some(name) = pick(&commit.id().hex()) {
            return Ok(Some((name, false)));
        }
        for parent_id in commit.parent_ids() {
            if seen.insert(parent_id.as_bytes().to_vec()) {
                heap.push(HeapItem(store.get_commit(parent_id).map_err(io)?));
            }
        }
    }
    Ok(None)
}

/// Map a jj commit + its changed files to a `CommitChanges` disclosure record (reuses
/// `to_model_commit` for identity/description so it matches the log/changeset display).
fn commit_changes(
    commit: &JjCommit,
    files: Vec<model::ChangedFile>,
    bookmarks: &HashMap<String, Vec<String>>,
) -> model::CommitChanges {
    let c = to_model_commit(commit, None, bookmarks);
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

/// Snapshot the working copy so `@` reflects on-disk edits, returning the repo at the resulting
/// operation. Unlike the read-only `open`, this MUTATES (exactly like every `jj` command): it takes
/// the working-copy lock, and when disk differs from `@`'s tree it rewrites `@`, rebases descendants,
/// and commits a "snapshot working copy" operation. Modeled on jayjay's `refresh_working_copy`.
///
/// `base_ignores` chains the global + repo-local excludes (see `base_ignores`); `max_new_file_size`
/// matches the jj CLI default (1 MiB) so a status refresh can't hash/store an arbitrarily huge
/// untracked file.
fn snapshot_working_copy(root: &Path) -> model::Result<(Workspace, Arc<ReadonlyRepo>)> {
    let settings = UserSettings::from_config(StackedConfig::with_defaults()).map_err(io)?;
    let mut workspace = Workspace::load(
        &settings,
        root,
        &StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .map_err(io)?;
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(io)?;

    let wc_name = workspace.workspace_name().to_owned();
    let Some(wc_commit_id) = repo.view().get_wc_commit_id(&wc_name).cloned() else {
        // No working-copy commit (e.g. a bare/foreign workspace) — nothing to snapshot.
        return Ok((workspace, repo));
    };
    let wc_commit = repo.store().get_commit(&wc_commit_id).map_err(io)?;

    let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(io)?;
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
/// (`insertions`/`deletions` are added Swift-side from one `jj diff --stat`, jayjay-style.)
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
            dirty: false,
            conflicted: false,
            working_copy: model::CommitChanges {
                change_id: None,
                commit_id: None,
                refs: Vec::new(),
                description: None,
                files: Vec::new(),
            },
            parent: model::ParentState::Unavailable,
            branch_for_ci: None,
        });
    };
    let wc_commit = store.get_commit(&wc_id).map_err(io)?;
    let conflicted = wc_commit.has_conflict();
    let wc_files = changed_files(store, &wc_commit)?;
    let working_copy = commit_changes(&wc_commit, wc_files, &bookmarks);

    // Parent `@-`: 0 parents ⇒ `@` is the root; >1 ⇒ a merge; else the single parent's change set
    // (its files vs `@--`). A parent-load failure degrades to Unavailable, not a misleading empty.
    let parent_ids = wc_commit.parent_ids();
    let parent = if parent_ids.is_empty() {
        model::ParentState::Root
    } else if parent_ids.len() > 1 {
        model::ParentState::Merge(parent_ids.len() as u32)
    } else {
        match store.get_commit(&parent_ids[0]) {
            Ok(parent) => {
                let files = changed_files(store, &parent)?;
                model::ParentState::Changes(commit_changes(&parent, files, &bookmarks))
            }
            Err(_) => model::ParentState::Unavailable,
        }
    };

    let branch_for_ci = nearest_bookmark(store, &wc_id, &bookmarks)?.map(|(name, _)| name);

    Ok(model::WorkingStatus {
        dirty: !working_copy.files.is_empty() || conflicted,
        conflicted,
        working_copy,
        parent,
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
    let model_commit = to_model_commit(&commit, None, &bookmarks);
    Ok(model::Changeset {
        is_merge: commit.parent_ids().len() > 1,
        full_message: commit.description().to_string(),
        files,
        commit: model_commit,
    })
}

/// The changed files of `commit` vs its FIRST parent (the jj root commit provides the empty base for
/// the first real change, so no empty-tree special case is needed). Add/modify/delete from before↔
/// after presence; rename detection (copy records) is a later refinement. Drives jj-lib's async
/// tree `diff_stream`, blocked on with pollster.
fn changed_files(
    store: &std::sync::Arc<jj_lib::store::Store>,
    commit: &JjCommit,
) -> model::Result<Vec<model::ChangedFile>> {
    use futures::StreamExt;

    let after = commit.tree();
    let before = match commit.parent_ids().first() {
        Some(pid) => store.get_commit(pid).map_err(io)?.tree(),
        None => return Ok(Vec::new()), // the jj root commit itself
    };

    let mut files = Vec::new();
    pollster::block_on(async {
        let mut stream = before.diff_stream(&after, &EverythingMatcher);
        while let Some(entry) = stream.next().await {
            let Ok(diff) = entry.values else { continue };
            let kind = if diff.before.is_absent() {
                model::ChangeKind::Added
            } else if diff.after.is_absent() {
                model::ChangeKind::Deleted
            } else {
                model::ChangeKind::Modified
            };
            files.push(model::ChangedFile {
                path: entry.path.as_internal_file_string().to_string(),
                old_path: None,
                kind,
            });
        }
    });
    Ok(files)
}
