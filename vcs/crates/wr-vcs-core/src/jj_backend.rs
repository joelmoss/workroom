//! jj backend — the ONLY site that touches `jj-lib`.
//!
//! Read-only access to a (colocated) jj repo: open the workspace, load the repo at the current
//! operation head, and read commit data WITHOUT snapshotting/locking the working copy (prior
//! learning `jj-concurrent-probes-working-copy-lock`: jj takes the working-copy lock only on ops
//! that *write* `@` — plain `load_at_head` + reads do not).
//!
//! Phase 0 proof: `log_page` (bounded DAG walk from `@`) and `changeset` (metadata + full message).
//! The changeset FILE LIST / per-file diff needs jj-lib's async `diff_stream` and lands in Phase 1.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;

use jj_lib::commit::Commit as JjCommit;
use jj_lib::config::StackedConfig;
use jj_lib::object_id::ObjectId;
use jj_lib::repo::{ReadonlyRepo, Repo, StoreFactories};
use jj_lib::settings::UserSettings;
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
    (author, sig.timestamp.timestamp.0, sig.timestamp.tz_offset * 60)
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
        (self.0.committer().timestamp.timestamp.0, self.0.id().as_bytes())
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
    let wc_id = repo.view().get_wc_commit_id(workspace.workspace_name()).cloned();

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
            return Ok(HistoryPage { commits, reached_end: true });
        };
        commits.push(to_model_commit(&commit, wc_id.as_ref(), &bookmarks));
        for parent_id in commit.parent_ids() {
            if seen.insert(parent_id.as_bytes().to_vec()) {
                heap.push(HeapItem(store.get_commit(parent_id).map_err(io)?));
            }
        }
    }
    let reached_end = heap.is_empty();
    Ok(HistoryPage { commits, reached_end })
}

/// A single changeset's metadata + full message. NOTE: the changed-file list + per-file diff use
/// jj-lib's async `diff_stream` and land in Phase 1; `files` is empty here by design.
pub fn changeset(root: &Path, commit_id_hex: &str) -> model::Result<model::Changeset> {
    let (_workspace, repo) = open(root)?;
    let store = repo.store();
    let id = jj_lib::backend::CommitId::try_from_hex(commit_id_hex)
        .ok_or_else(|| VcsError::NotFound(format!("bad commit id {commit_id_hex}")))?;
    let commit = store.get_commit(&id).map_err(io)?;
    let bookmarks = bookmark_map(&repo);
    let model_commit = to_model_commit(&commit, None, &bookmarks);
    Ok(model::Changeset {
        is_merge: commit.parent_ids().len() > 1,
        full_message: commit.description().to_string(),
        files: Vec::new(), // Phase 1: async diff_stream(parent_tree, tree)
        commit: model_commit,
    })
}
