//! Agent-side Git history. Repository handles never cross threads; each request opens its own.
//! Patch and count reads use the owning host's Git, with one comparison policy (see `diff`).
use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use gix::bstr::ByteSlice;
use wr_vcs_model::{self as model, Author, Commit, HistoryPage, PushScope, PushState, VcsError};

pub mod diff;

fn io(error: impl std::fmt::Display) -> VcsError {
    VcsError::Io(error.to_string())
}

fn authors(message: &str, name: String, email: String) -> Vec<Author> {
    let mut seen = HashSet::from([email.to_lowercase()]);
    let mut result = vec![Author { name, email }];
    for line in message.lines().map(str::trim) {
        let Some(prefix) = line.get(..15) else {
            continue;
        };
        if !prefix.eq_ignore_ascii_case("co-authored-by:") {
            continue;
        }
        let value = line[15..].trim();
        let (Some(open), Some(close)) = (value.rfind('<'), value.rfind('>')) else {
            continue;
        };
        if open >= close {
            continue;
        }
        let email = value[open + 1..close].trim();
        if email.is_empty() || !seen.insert(email.to_lowercase()) {
            continue;
        }
        let name = value[..open].trim();
        result.push(Author {
            name: if name.is_empty() { email } else { name }.into(),
            email: email.into(),
        });
    }
    result
}

fn decorations(repo: &gix::Repository) -> model::Result<BTreeMap<String, Vec<String>>> {
    let mut result: BTreeMap<String, Vec<String>> = BTreeMap::new();
    // UI decorations are local branches, then tags; remote refs only inform push state.
    for prefix in ["refs/heads/", "refs/tags/"] {
        let mut group: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for reference in repo
            .references()
            .map_err(io)?
            .prefixed(prefix)
            .map_err(io)?
        {
            let mut reference = reference.map_err(io)?;
            let name = reference.name().shorten().to_string();
            if let Ok(commit) = reference.peel_to_commit() {
                group.entry(commit.id.to_string()).or_default().push(name);
            }
        }
        for (id, mut names) in group {
            names.sort();
            result.entry(id).or_default().extend(names);
        }
    }
    Ok(result)
}

/// An unreadable origin tip makes the whole scope unknown, never partially unpushed.
fn push_states(
    repo: &gix::Repository,
    start: gix::ObjectId,
) -> Option<(HashSet<String>, PushScope)> {
    // Remote-tracking refs without a configured origin are stale, not a trustworthy scope.
    repo.find_remote("origin").ok()?;
    let refs = repo.references().ok()?;
    let mut tips = Vec::new();
    let mut names = Vec::new();
    for reference in refs.prefixed("refs/remotes/origin/").ok()? {
        let mut reference = reference.ok()?;
        if reference.name().as_bstr().ends_with(b"/HEAD") {
            continue;
        }
        names.push(reference.name().shorten().to_string());
        tips.push(reference.peel_to_commit().ok()?.id);
    }
    if tips.is_empty() {
        return None;
    }
    let walk = repo.rev_walk([start]).with_hidden(tips).all().ok()?;
    let mut unpushed = HashSet::new();
    for commit in walk {
        unpushed.insert(commit.ok()?.id.to_string());
    }
    Some((
        unpushed,
        PushScope {
            ref_name: (names.len() == 1).then(|| names[0].clone()),
            count: names.len() as u32,
        },
    ))
}

fn map_commit(
    commit: &gix::Commit<'_>,
    refs: &BTreeMap<String, Vec<String>>,
    push: &Option<(HashSet<String>, PushScope)>,
) -> model::Result<Commit> {
    let message = commit
        .message_raw()
        .map_err(io)?
        .to_str_lossy()
        .into_owned();
    let author = commit.author().map_err(io)?;
    // libgit2's git_commit_time is the committer time, not the author time (rebases differ).
    let time = commit.committer().map_err(io)?.time().map_err(io)?;
    let id = commit.id.to_string();
    Ok(Commit {
        commit_id: id.clone(),
        short_id: commit.id().shorten().map_err(io)?.to_string(),
        change_id: None,
        summary: commit
            .message()
            .map_err(io)?
            .summary()
            .to_str_lossy()
            .into_owned(),
        body: message
            .split_once('\n')
            .map(|(_, body)| body.trim())
            .unwrap_or("")
            .to_owned(),
        authors: authors(
            &message,
            author.name.to_str_lossy().into_owned(),
            author.email.to_str_lossy().into_owned(),
        ),
        timestamp_ms: time.seconds.saturating_mul(1000),
        tz_offset_secs: time.offset,
        refs: refs.get(&id).cloned().unwrap_or_default(),
        parent_ids: commit.parent_ids().map(|id| id.to_string()).collect(),
        is_working_copy: false,
        is_root: false,
        change_offset: None,
        divergent_siblings: vec![],
        push_state: match push {
            None => PushState::Unknown,
            Some((ids, _)) if ids.contains(&id) => PushState::Unpushed,
            _ => PushState::Pushed,
        },
    })
}

pub fn log_page(root: &Path, limit: usize) -> model::Result<HistoryPage> {
    let repo = gix::open(root).map_err(io)?;
    let head = repo.head().map_err(io)?;
    if head.is_unborn() {
        return Ok(HistoryPage {
            commits: vec![],
            reached_end: true,
            push_scope: None,
        });
    }
    let id = repo.head_id().map_err(io)?.detach();
    let refs = decorations(&repo)?;
    let push = push_states(&repo, id);
    let walk = repo
        .rev_walk([id])
        .sorting(gix::revision::walk::Sorting::ByCommitTime(
            gix::traverse::commit::simple::CommitTimeOrder::NewestFirst,
        ))
        .all()
        .map_err(io)?;
    let mut commits = Vec::new();
    let mut reached_end = true;
    for entry in walk {
        let entry = entry.map_err(io)?;
        if commits.len() == limit {
            reached_end = false;
            break;
        }
        commits.push(map_commit(&entry.object().map_err(io)?, &refs, &push)?);
    }
    Ok(HistoryPage {
        commits,
        reached_end,
        push_scope: push.map(|(_, scope)| scope),
    })
}

pub fn changeset(root: &Path, revision: &str) -> model::Result<model::Changeset> {
    let repo = gix::open(root).map_err(io)?;
    let id = gix::ObjectId::from_hex(revision.as_bytes()).map_err(io)?;
    let commit = repo
        .find_object(id)
        .map_err(io)?
        .try_into_commit()
        .map_err(io)?;
    let push = push_states(&repo, id);
    let mapped = map_commit(&commit, &decorations(&repo)?, &push)?;
    let files = diff::committed_files(root, &mapped)?;
    Ok(model::Changeset {
        is_merge: mapped.parent_ids.len() > 1,
        commit: mapped,
        full_message: commit
            .message_raw()
            .map_err(io)?
            .to_str_lossy()
            .into_owned(),
        files,
        push_scope: push.map(|(_, scope)| scope),
    })
}

pub fn current_ref(root: &Path) -> model::Result<model::Ref> {
    let repo = gix::open(root).map_err(io)?;
    let head = repo.head().map_err(io)?;
    if let Some(name) = head.referent_name() {
        return Ok(model::Ref {
            name: Some(name.shorten().to_string()),
            kind: model::RefKind::Branch,
        });
    }
    Ok(model::Ref {
        name: Some(
            repo.head_id()
                .map_err(io)?
                .shorten()
                .map_err(io)?
                .to_string(),
        ),
        kind: model::RefKind::Detached,
    })
}

pub fn file_content(
    root: &Path,
    revision: &str,
    path: &str,
    parent: bool,
) -> model::Result<Option<String>> {
    let repo = gix::open(root).map_err(io)?;
    if revision == "HEAD" && repo.head().map_err(io)?.is_unborn() {
        return Ok(None);
    }
    let mut commit = repo
        .rev_parse_single(revision)
        .map_err(io)?
        .object()
        .map_err(io)?
        .peel_to_commit()
        .map_err(io)?;
    if parent {
        let Some(id) = commit.parent_ids().next() else {
            return Ok(None);
        };
        commit = id.object().map_err(io)?.try_into_commit().map_err(io)?;
    }
    let Some(entry) = commit
        .tree()
        .map_err(io)?
        .lookup_entry_by_path(path)
        .map_err(io)?
    else {
        return Ok(None);
    };
    if !entry.mode().is_blob() {
        return Ok(None);
    }
    let object = entry.object().map_err(io)?;
    if object.data.len() > 2 * 1024 * 1024 || object.data.contains(&0) {
        return Ok(None);
    }
    Ok(String::from_utf8(object.data.clone())
        .ok()
        .filter(|text| !text.is_empty()))
}
