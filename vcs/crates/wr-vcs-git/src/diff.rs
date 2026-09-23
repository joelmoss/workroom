//! Git supplies both patch text and exact counts using the same comparison and repository config.
//! NUL-delimited metadata preserves tabs/newlines in paths. No shell interprets request values.
use std::collections::HashMap;
use std::io::Read;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use wr_vcs_model::{self as model, ChangeKind, ChangedFile, Commit, LineStats, VcsError};

const MAX_OUTPUT: usize = 8 * 1024 * 1024;

/// Bounded subprocess read, also used by JJ's existing CLI fallback operations on the agent host.
/// Keep draining both pipes, kill the process group on timeout/overflow, then reap before returning.
pub fn run(root: &Path, program: &str, args: &[&str]) -> model::Result<Vec<u8>> {
    run_with_status(root, program, args, false)
}

/// As `run`, plus child-process-scoped env overrides — never process-wide `std::env::set_var`,
/// which races any concurrently spawned child reading the parent's environment. Test-fixture
/// setup only; production call sites use `run`/`run_with_status` so a repository's own git config
/// (aliases, `diff.renames`, credential helpers) still applies.
pub fn run_with_env(
    root: &Path,
    program: &str,
    args: &[&str],
    env: &[(&str, &str)],
) -> model::Result<Vec<u8>> {
    run_bounded(
        root,
        program,
        args,
        false,
        Duration::from_secs(30),
        None,
        env,
    )
}

/// Retain the operation barrier across exec. If the agent dies, a snapshotting JJ child still
/// owns this descriptor until it really exits. Only the child clears CLOEXEC, never the parent.
pub fn run_with_barrier(
    root: &Path,
    program: &str,
    args: &[&str],
    barrier: RawFd,
) -> model::Result<Vec<u8>> {
    run_bounded(
        root,
        program,
        args,
        false,
        Duration::from_secs(30),
        Some(barrier),
        &[],
    )
}

fn run_with_status(
    root: &Path,
    program: &str,
    args: &[&str],
    difference_is_success: bool,
) -> model::Result<Vec<u8>> {
    run_bounded(
        root,
        program,
        args,
        difference_is_success,
        Duration::from_secs(30),
        None,
        &[],
    )
}

fn run_bounded(
    root: &Path,
    program: &str,
    args: &[&str],
    difference_is_success: bool,
    timeout: Duration,
    barrier: Option<RawFd>,
    extra_env: &[(&str, &str)],
) -> model::Result<Vec<u8>> {
    let mut command = Command::new(program);
    command
        .current_dir(root)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    if let Some(fd) = barrier {
        unsafe {
            command.pre_exec(move || {
                if libc::fcntl(fd, libc::F_SETFD, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    // An inherited repository override must never redirect a request to another checkout.
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ] {
        command.env_remove(key);
    }
    command
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .envs(extra_env.iter().copied());
    let mut child = command.spawn().map_err(super::io)?;
    let exceeded = Arc::new(AtomicBool::new(false));
    let start = Instant::now();
    fn drain(
        mut source: impl Read + AsRawFd,
        exceeded: Arc<AtomicBool>,
        deadline: Instant,
    ) -> std::io::Result<Vec<u8>> {
        let fd = source.as_raw_fd();
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFL);
            if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
                return Err(std::io::Error::last_os_error());
            }
        }
        let mut result = Vec::new();
        let mut bytes = [0; 8192];
        loop {
            if Instant::now() >= deadline || exceeded.load(Ordering::Relaxed) {
                return Ok(result);
            }
            let count = match source.read(&mut bytes) {
                Ok(count) => count,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            };
            if count == 0 {
                return Ok(result);
            }
            if result.len() + count <= MAX_OUTPUT {
                result.extend_from_slice(&bytes[..count]);
            } else {
                exceeded.store(true, Ordering::Relaxed);
            }
        }
    }
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let over = exceeded.clone();
    let out = std::thread::spawn(move || drain(stdout, over, start + timeout));
    let over = exceeded.clone();
    let err = std::thread::spawn(move || drain(stderr, over, start + timeout));
    let mut status = None;
    loop {
        if exceeded.load(Ordering::Relaxed) || start.elapsed() >= timeout {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            if status.is_none() {
                status = Some(child.wait());
            }
            break;
        }
        if status.is_none() {
            match child.try_wait() {
                Ok(Some(exit)) => status = Some(Ok(exit)),
                Ok(None) => {}
                Err(error) => {
                    unsafe {
                        libc::kill(-(child.id() as i32), libc::SIGKILL);
                    }
                    let _ = child.wait();
                    status = Some(Err(error));
                }
            }
        }
        if status.is_some() && out.is_finished() && err.is_finished() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let stdout = out
        .join()
        .map_err(|_| super::io("stdout reader failed"))?
        .map_err(super::io)?;
    let stderr = err
        .join()
        .map_err(|_| super::io("stderr reader failed"))?
        .map_err(super::io)?;
    if exceeded.load(Ordering::Relaxed) {
        return Err(VcsError::PartialData("VCS output exceeds 8 MiB".into()));
    }
    if start.elapsed() >= timeout {
        return Err(super::io("VCS command timed out"));
    }
    let status = status.unwrap().map_err(super::io)?;
    if !(status.success() || difference_is_success && status.code() == Some(1)) {
        return Err(super::io(String::from_utf8_lossy(&stderr)));
    }
    Ok(stdout)
}

/// Security: `-c core.fsmonitor=` blocks a per-repository, non-versioned `.git/config` setting
/// from executing an arbitrary program during `status`/working-tree `diff` (the fsmonitor hook).
/// `GitProvider.swift`'s libgit2 read carries no such flag because libgit2 never spawns that hook
/// at all — this subprocess path can, so every invocation needs it. `git`/`git_with_status` are
/// the only two call sites that shell out to `git` in this crate, precisely so that hardening
/// cannot be forgotten on a future one.
///
/// The same threat covers filter drivers: `status` and a working-tree `diff` run a driver's
/// `clean`/`process` command on any stat-dirty file its attributes select. Drivers defined in the
/// repository's own config (`local`/`worktree` scope) are overridden to nothing. Global and system
/// drivers, git-lfs's among them, are the user's own and keep working. The cost: a driver a tool
/// installs into `.git/config` on purpose (nbstripout, git-crypt) is not applied either, so for a
/// stat-dirty file its line counts and patch can differ from what the user's own `git diff` shows.
/// Submodules keep their config under the same untrusted `.git/modules/`, and a working-tree
/// `status`/`diff` would run a `status` inside each one, so both pass `--ignore-submodules=dirty`
/// (a flag, because it outranks a `submodule.<name>.ignore` in that same config). A submodule
/// with new commits is still reported; one with only working-tree changes is not. `diff` also
/// passes `--submodule=short`: a `diff.submodule` of `diff` or `log` would run a child git inside
/// the submodule, which reads that config and inherits none of these flags (`diff.external`).
fn git(root: &Path, args: &[&str]) -> model::Result<Vec<u8>> {
    git_with_status(root, args, false)
}

/// As `git`, but `--no-index`'s "found a difference" exit code 1 is success, not failure.
fn git_with_status(
    root: &Path,
    args: &[&str],
    difference_is_success: bool,
) -> model::Result<Vec<u8>> {
    let filters = repository_filter_overrides(root)?;
    let mut full = vec![
        "--literal-pathspecs",
        "-c",
        "core.quotePath=false",
        "-c",
        "core.fsmonitor=",
    ];
    for setting in &filters {
        full.extend(["-c", setting.as_str()]);
    }
    full.extend_from_slice(args);
    run_with_status(root, "git", &full, difference_is_success)
}

/// `-c` settings that disable every filter driver whose `clean` or `process` command comes from
/// the repository's own config. Reading config runs no filter.
// ponytail: one extra `git config` spawn per git call (a few ms); compute once per public entry
// point and pass it down if status polling cost ever shows.
fn repository_filter_overrides(root: &Path) -> model::Result<Vec<String>> {
    // Exit 1 is "no such keys", the common case.
    let listing = run_with_status(
        root,
        "git",
        &[
            "config",
            "--null",
            "--show-scope",
            "--get-regexp",
            r"^filter\..*\.(clean|process)$",
        ],
        true,
    )?;
    let mut names: Vec<&str> = Vec::new();
    // `scope NUL key LF value NUL`, repeated.
    let mut fields = listing.split(|&b| b == 0);
    while let (Some(scope), Some(entry)) = (fields.next(), fields.next()) {
        if scope != b"local" && scope != b"worktree" {
            continue;
        }
        let key = entry.split(|&b| b == b'\n').next().unwrap_or(&[]);
        // Fail closed: a driver this cannot name in a `-c` setting (which splits at the first `=`)
        // would otherwise run unopposed.
        let name = std::str::from_utf8(key)
            .ok()
            .and_then(|key| key.strip_prefix("filter."))
            .and_then(|rest| rest.rsplit_once('.'))
            .map(|(name, _)| name)
            .filter(|name| !name.contains('='))
            .ok_or_else(|| VcsError::PartialData("unreadable filter driver name".into()))?;
        if !names.contains(&name) {
            names.push(name);
        }
    }
    Ok(names
        .iter()
        .flat_map(|name| {
            [
                format!("filter.{name}.clean="),
                format!("filter.{name}.process="),
                format!("filter.{name}.required=false"),
            ]
        })
        .collect())
}

fn comparison(commit: &Commit) -> Vec<String> {
    if let Some(parent) = commit.parent_ids.first() {
        vec!["diff".into(), parent.clone(), commit.commit_id.clone()]
    } else {
        vec![
            "diff-tree".into(),
            "--root".into(),
            "--no-commit-id".into(),
            "-r".into(),
            commit.commit_id.clone(),
        ]
    }
}

fn read_diff(
    root: &Path,
    comparison: &[String],
    format: &[&str],
    paths: &[&str],
) -> model::Result<Vec<u8>> {
    let mut args: Vec<&str> = comparison.iter().map(String::as_str).collect();
    // See `git`: a working-tree diff would otherwise run a status inside each submodule, and a
    // `diff.submodule=diff`/`log` setting a `diff`/`log` inside each one.
    args.extend([
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
        "--ignore-submodules=dirty",
        "--submodule=short",
    ]);
    args.extend_from_slice(format);
    args.push("--");
    args.extend_from_slice(paths);
    git(root, &args)
}

fn text(bytes: &[u8]) -> model::Result<String> {
    String::from_utf8(bytes.to_vec())
        .map_err(|_| VcsError::PartialData("non-UTF-8 repository path or patch".into()))
}

pub fn committed_files(root: &Path, commit: &Commit) -> model::Result<Vec<ChangedFile>> {
    files(root, &comparison(commit))
}

pub fn files(root: &Path, comparison: &[String]) -> model::Result<Vec<ChangedFile>> {
    let names = read_diff(root, comparison, &["--name-status", "-z"], &[])?;
    let mut fields = names.split(|b| *b == 0).filter(|s| !s.is_empty());
    let mut result = Vec::new();
    while let Some(status) = fields.next() {
        let first = text(
            fields
                .next()
                .ok_or_else(|| super::io("truncated diff path"))?,
        )?;
        let (kind, old_path, path) = match status[0] {
            b'R' | b'C' => (
                if status[0] == b'R' {
                    ChangeKind::Renamed
                } else {
                    ChangeKind::Copied
                },
                Some(first),
                text(fields.next().ok_or_else(|| super::io("truncated rename"))?)?,
            ),
            b'A' => (ChangeKind::Added, None, first),
            b'D' => (ChangeKind::Deleted, None, first),
            b'U' => (ChangeKind::Conflicted, None, first),
            _ => (ChangeKind::Modified, None, first),
        };
        result.push(ChangedFile {
            path,
            old_path,
            kind,
            line_stats: None,
        });
    }
    // Both passes read the SAME fixed comparison (a commit range never changes underneath a read),
    // so every numstat path is guaranteed present here — unlike the mutable-worktree case handled
    // by `working_status`, which deliberately does not go through this cross-check (see `numstat`).
    let mut index = HashMap::with_capacity(result.len());
    for (position, file) in result.iter().enumerate() {
        index.insert(file.path.clone(), position);
    }
    for (path, line_stats) in numstat(root, comparison)? {
        let &position = index.get(&path).ok_or(VcsError::StaleSnapshot)?;
        result[position].line_stats = Some(line_stats);
    }
    Ok(result)
}

/// `git diff --numstat`, parsed into a per-path map. Split out of `files()` so a MUTABLE worktree
/// read (`working_status`) can consume line stats without depending on a SEPARATE `--name-status`
/// pass over the same comparison staying consistent with this one — a file that changed between
/// the two `git` invocations would otherwise fail the WHOLE status read (`StaleSnapshot`) instead
/// of just missing that one file's counts, and paying for a second full diff (with rename
/// detection) whose classification `working_status` already has from its own `git status` pass.
fn numstat(root: &Path, comparison: &[String]) -> model::Result<HashMap<String, LineStats>> {
    let stats = read_diff(root, comparison, &["--numstat", "-z"], &[])?;
    let mut fields = stats.split(|b| *b == 0);
    let mut result = HashMap::new();
    while let Some(field) = fields.next() {
        if field.is_empty() {
            continue;
        }
        let mut parts = field.splitn(3, |b| *b == b'\t');
        let added = parts.next().unwrap();
        let deleted = parts.next().ok_or_else(|| super::io("invalid numstat"))?;
        let name = parts
            .next()
            .ok_or_else(|| super::io("invalid numstat path"))?;
        let path = if name.is_empty() {
            let _old = fields
                .next()
                .ok_or_else(|| super::io("invalid numstat rename"))?;
            fields
                .next()
                .ok_or_else(|| super::io("invalid numstat destination"))?
        } else {
            name
        };
        let path = text(path)?;
        if added != b"-" && deleted != b"-" {
            result.insert(
                path,
                LineStats {
                    insertions: text(added)?.parse().map_err(super::io)?,
                    deletions: text(deleted)?.parse().map_err(super::io)?,
                },
            );
        }
    }
    Ok(result)
}

pub fn committed_patch(root: &Path, commit: &Commit, path: &str) -> model::Result<String> {
    let files = committed_files(root, commit)?;
    selected_patch(root, &comparison(commit), &files, path)
}

fn selected_patch(
    root: &Path,
    comparison: &[String],
    files: &[ChangedFile],
    path: &str,
) -> model::Result<String> {
    let Some(index) = files.iter().position(|file| file.path == path).or_else(|| {
        files
            .iter()
            .position(|file| file.old_path.as_deref() == Some(path))
    }) else {
        return Ok(String::new());
    };
    let patch_args = ["--patch", "--src-prefix=a/", "--dst-prefix=b/"];
    // Read only this file's delta where that is exact: its own path, plus its source for a rename
    // so rename detection still pairs them. Reading the whole comparison made one file's patch fail
    // whenever the comparison's total patch passed `MAX_OUTPUT`. A copy keeps the whole read:
    // restricting paths can turn a copy into an add, and including its source can append an
    // unrelated source patch. So does any other delta that shares one of these paths, which the
    // restricted read reports as more than one group.
    let file = &files[index];
    if file.kind != ChangeKind::Copied {
        let mut paths = vec![file.path.as_str()];
        paths.extend(file.old_path.as_deref());
        let patch = read_diff(root, comparison, &patch_args, &paths)?;
        if let [only] = patch_groups(&patch)[..] {
            return text(only);
        }
    }
    let patch = read_diff(root, comparison, &patch_args, &[])?;
    let groups = patch_groups(&patch);
    if groups.len() != files.len() {
        return Err(VcsError::PartialData("patch/file list mismatch".into()));
    }
    // Decode only the selected delta: another file's non-UTF-8 text must not fail this one.
    text(groups[index])
}

/// One slice per changed file, in git's order, split on `diff --git ` at the start of a line.
/// Git prints the deletion and addition blocks of a typechange with the same header; those are
/// adjacent, so they form one group.
fn patch_groups(patch: &[u8]) -> Vec<&[u8]> {
    const MARKER: &[u8] = b"diff --git ";
    let starts: Vec<usize> = (0..patch.len())
        .filter(|&i| (i == 0 || patch[i - 1] == b'\n') && patch[i..].starts_with(MARKER))
        .collect();
    let mut groups: Vec<(&[u8], usize, usize)> = Vec::new();
    for (position, &start) in starts.iter().enumerate() {
        let end = starts.get(position + 1).copied().unwrap_or(patch.len());
        let header = patch[start..end]
            .split(|&b| b == b'\n')
            .next()
            .unwrap_or(&[]);
        match groups.last_mut() {
            Some((previous, _, group_end)) if *previous == header => *group_end = end,
            _ => groups.push((header, start, end)),
        }
    }
    groups
        .into_iter()
        .map(|(_, start, end)| &patch[start..end])
        .collect()
}

#[derive(serde::Serialize)]
pub struct WorkingStatus {
    pub conflicted: bool,
    pub files: Vec<ChangedFile>,
    pub untracked: Vec<String>,
    pub branch_for_ci: Option<String>,
}

fn working_comparison(root: &Path) -> model::Result<Vec<String>> {
    let repo = gix::open(root).map_err(super::io)?;
    let base = if repo.head().map_err(super::io)?.is_unborn() {
        // Hash the empty tree without writing an object. Git knows the empty tree internally.
        text(&git(root, &["hash-object", "-t", "tree", "--stdin"])?)?
            .trim()
            .to_owned()
    } else {
        repo.head_id().map_err(super::io)?.to_string()
    };
    Ok(vec!["diff".into(), base])
}

pub fn working_status(root: &Path) -> model::Result<WorkingStatus> {
    let raw = git(
        root,
        &[
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--ignore-submodules=dirty",
        ],
    )?;
    let mut fields = raw.split(|b| *b == 0).filter(|s| !s.is_empty());
    let mut result = Vec::new();
    let mut untracked = Vec::new();
    let mut conflicted = false;
    while let Some(record) = fields.next() {
        if record.len() < 4 {
            return Err(super::io("invalid status record"));
        }
        let status = &record[..2];
        let path = text(&record[3..])?;
        let conflict = status.contains(&b'U') || status == b"AA" || status == b"DD";
        conflicted |= conflict;
        let renamed = status.contains(&b'R') || status.contains(&b'C');
        let old_path = if renamed {
            Some(text(
                fields
                    .next()
                    .ok_or_else(|| super::io("missing rename source"))?,
            )?)
        } else {
            None
        };
        let kind = if conflict {
            ChangeKind::Conflicted
        } else if renamed {
            ChangeKind::Renamed
        } else if status == b"??" {
            untracked.push(path.clone());
            ChangeKind::Added
        } else if status.contains(&b'D') {
            ChangeKind::Deleted
        } else if status.contains(&b'A') {
            ChangeKind::Added
        } else {
            ChangeKind::Modified
        };
        result.push(ChangedFile {
            path,
            old_path,
            kind,
            line_stats: None,
        });
    }
    // `numstat`, not `files`: this `git status` pass already has every file's identity and kind,
    // so a second full diff (with its own `--name-status` invocation and rename detection) would
    // be pure waste — and a file that changed between this call and the `git diff` below would
    // fail the WHOLE status read rather than just missing that file's counts, since `files` cross-
    // checks numstat paths against a name-status list from what is, on a live worktree, a
    // genuinely separate moment in time.
    let counted = numstat(root, &working_comparison(root)?)?;
    for file in &mut result {
        file.line_stats = counted.get(&file.path).copied();
    }
    // Untracked files are rows, but (like git diff HEAD) do not contribute to the tracked diffstat.
    let current = super::current_ref(root)?;
    Ok(WorkingStatus {
        conflicted,
        files: result,
        untracked,
        branch_for_ci: (current.kind == model::RefKind::Branch)
            .then_some(current.name)
            .flatten(),
    })
}

pub fn working_patch(root: &Path, path: &str) -> model::Result<String> {
    let status = working_status(root)?;
    let Some(file) = status.files.iter().find(|file| file.path == path) else {
        return Ok(String::new());
    };
    if status.untracked.iter().any(|p| p == path) {
        return text(&git_with_status(
            root,
            &[
                "diff",
                "--no-index",
                "--no-ext-diff",
                "--no-textconv",
                "--no-color",
                "--src-prefix=a/",
                "--dst-prefix=b/",
                "--",
                "/dev/null",
                path,
            ],
            true,
        )?);
    }
    let _ = file;
    let comparison = working_comparison(root)?;
    selected_patch(root, &comparison, &files(root, &comparison)?, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inherited_pipes_cannot_outlive_the_command_deadline() {
        let started = Instant::now();
        let result = run_bounded(
            Path::new("/tmp"),
            "/bin/sh",
            &["-c", "sleep 60 & exit 0"],
            false,
            Duration::from_millis(100),
            None,
            &[],
        );
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn output_overflow_is_an_error_not_a_truncated_success() {
        let result = run_bounded(
            Path::new("/tmp"),
            "/usr/bin/yes",
            &[],
            false,
            Duration::from_secs(5),
            None,
            &[],
        );
        assert!(matches!(result, Err(VcsError::PartialData(_))));
    }
}
