//! git as the Go CLI runs it (`internal/vcs`'s `childEnvironment`), for every command here that
//! shells out to it in a repository.

use std::path::Path;
use std::process::{Command, Stdio};

/// The variables that point git at another repository, which a `workroom` run from a git hook or
/// alias inherits and which outrank both the working directory and the ceiling: Go's
/// `gitRedirects`.
const GIT_REDIRECTS: [&str; 7] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES",
];

/// git, run in `dir` with the environment Go's `childEnvironment` gives it: this process's without
/// the repository redirects, no credential prompt, and a ceiling so repository discovery stops at
/// `dir`. Its stdin is empty; a caller that feeds it one sets its own.
pub(super) fn command(dir: &Path) -> Command {
    let mut command = Command::new("git");
    command.current_dir(dir).stdin(Stdio::null());
    for key in GIT_REDIRECTS {
        command.env_remove(key);
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    if let Some(ceiling) = wr_vcs_git::diff::ceiling_directories(dir) {
        command.env("GIT_CEILING_DIRECTORIES", ceiling);
    }
    command
}

/// git `args` in `dir` as Go's `RealExecutor` runs it: both streams together, trimmed, and whether
/// it exited 0. A git that can't be started is a failure with nothing said.
pub(super) fn run(dir: &Path, args: &[&str]) -> (String, bool) {
    match command(dir).args(args).output() {
        Ok(output) => {
            let mut said = output.stdout;
            said.extend_from_slice(&output.stderr);
            (
                String::from_utf8_lossy(&said).trim().to_string(),
                output.status.success(),
            )
        }
        Err(_) => (String::new(), false),
    }
}

/// git `args` in `dir` as Go's `RealExecutor` runs it where the order of what git says matters:
/// both streams into one pipe, so they interleave as printed (`worktree add` says "Preparing
/// worktree" on stderr before "HEAD is now at" on stdout), trimmed. With it, how git ended: `Ok`
/// for exit 0, else Go's `exec` error's words (`exit status 128`).
pub(super) fn combined(dir: &Path, args: &[&str]) -> (String, Result<(), String>) {
    use std::io::Read;
    let started = std::io::pipe().and_then(|(mut reader, writer)| {
        let mut command = command(dir);
        command
            .args(args)
            .stdout(writer.try_clone()?)
            .stderr(writer);
        let child = command.spawn();
        // The command holds the pipe's write ends; they must close for the read to end.
        drop(command);
        let mut child = child?;
        let mut said = Vec::new();
        let read = reader.read_to_end(&mut said);
        let status = child.wait()?;
        read?;
        Ok((said, status))
    });
    match started {
        Ok((said, status)) => {
            let text = super::log::go_lossy(&said).trim().to_string();
            let ended = if status.success() {
                Ok(())
            } else {
                Err(super::teardown::go_exit(&status))
            };
            (text, ended)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (
            String::new(),
            Err("exec: \"git\": executable file not found in $PATH".to_string()),
        ),
        Err(error) => (String::new(), Err(super::config::os_error(&error))),
    }
}

/// git `args` in `dir` as Go's `gitOutput` runs it: its stdout, exact, or an error worded as Go's
/// (`git <first arg>: exit status <n>: <stderr>`).
pub(super) fn output(dir: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let first = args.first().copied().unwrap_or_default();
    let output = command(dir)
        .args(args)
        .output()
        .map_err(|error| format!("git {first}: {}", super::config::os_error(&error)))?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    let status = match output.status.code() {
        Some(code) => format!("exit status {code}"),
        None => "signal: killed".to_string(),
    };
    Err(format!(
        "git {first}: {status}: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    ))
}

/// The full hash of the commit `rev` ("" is HEAD) names. Go's `vcs.CommitAt`.
pub(super) fn commit_at(dir: &Path, rev: &str) -> Result<String, String> {
    let rev = if rev.is_empty() { "HEAD" } else { rev };
    let out = output(
        dir,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{rev}^{{commit}}"),
        ],
    )?;
    Ok(String::from_utf8_lossy(&out).trim().to_string())
}

/// Why [`file_at`] couldn't read a file from a commit.
#[derive(Debug)]
pub(super) enum FileAtError {
    /// The file is a symlink pointing outside the repository, whose bytes depend on where the
    /// checkout lands and so can't be read from the commit: Go's `ErrLinkOutside`.
    LinkOutside,
    /// git failed, in its words.
    Git(String),
}

/// `path`'s contents in commit `rev` ("" is HEAD) as a checkout of it writes them, with the
/// repository's filters and line-ending conversion applied, or none when `rev` has no file there
/// (#363). A symlink anywhere along the path (the file itself, or a linked directory such as
/// `scripts/`) is followed within the commit, as running the checkout's file follows it; one that
/// leaves the repository is [`FileAtError::LinkOutside`]. A rev that names no commit, as HEAD in a
/// repository with none, has no file, and neither has a path that is a directory or a submodule.
/// Go's `vcs.FileAt`.
pub(super) fn file_at(dir: &Path, rev: &str, path: &str) -> Result<Option<Vec<u8>>, FileAtError> {
    let rev = if rev.is_empty() { "HEAD" } else { rev };
    let commit = format!("{rev}^{{commit}}");
    if output(dir, &["rev-parse", "--verify", "--quiet", &commit]).is_err() {
        return Ok(None);
    }
    let mut path = path.to_string();
    // A chain of links is followed only so far, as the system follows one only so far.
    let mut hops = 0;
    while hops <= 8 {
        let parts: Vec<String> = path.split('/').map(str::to_string).collect();
        let mut linked = false;
        for i in 0..parts.len() {
            let prefix = parts[..=i].join("/");
            let mode = tree_mode(dir, rev, &prefix).map_err(FileAtError::Git)?;
            match mode.as_str() {
                "" => return Ok(None),
                "120000" => {
                    let target = output(dir, &["cat-file", "blob", &format!("{rev}:{prefix}")])
                        .map_err(FileAtError::Git)?;
                    let target = String::from_utf8_lossy(&target).into_owned();
                    if target.starts_with('/') {
                        return Err(FileAtError::LinkOutside);
                    }
                    let mut elements = vec![slash_dir(&prefix), target];
                    elements.extend(parts[i + 1..].iter().cloned());
                    let next = slash_join(&elements);
                    if next == ".." || next.starts_with("../") {
                        return Err(FileAtError::LinkOutside);
                    }
                    path = next;
                    linked = true;
                    hops += 1;
                }
                mode if i < parts.len() - 1 && mode != "040000" => return Ok(None),
                mode if i == parts.len() - 1 && mode != "100644" && mode != "100755" => {
                    return Ok(None);
                }
                _ => {}
            }
            if linked {
                break;
            }
        }
        if !linked {
            return filtered_blob(dir, rev, &path)
                .map(Some)
                .map_err(FileAtError::Git);
        }
    }
    Err(FileAtError::Git(format!(
        "{path}: too many levels of symbolic links"
    )))
}

/// `path` in `rev` converted by `rev`'s own `.gitattributes` (`--attr-source`), as a checkout of
/// `rev` converts it: the root's attributes can differ, as when a branch changes its line endings.
/// A git older than 2.40 has no `--attr-source` and falls back to the root's attributes.
fn filtered_blob(dir: &Path, rev: &str, path: &str) -> Result<Vec<u8>, String> {
    let object = format!("{rev}:{path}");
    match output(
        dir,
        &[
            &format!("--attr-source={rev}"),
            "cat-file",
            "--filters",
            &object,
        ],
    ) {
        Err(error) if error.contains("unknown option") => {
            output(dir, &["cat-file", "--filters", &object])
        }
        result => result,
    }
}

/// The mode of `path` in commit `rev`, such as 100755, 120000 (a symlink) or 040000 (a directory),
/// or "" when `rev` has nothing there.
fn tree_mode(dir: &Path, rev: &str, path: &str) -> Result<String, String> {
    // Without a trailing slash, a directory is listed as its own entry, not its contents.
    let listed = output(dir, &["ls-tree", "-z", rev, "--", path])?;
    let listed = String::from_utf8_lossy(&listed);
    let listed = listed.trim_matches(|c: char| c.is_ascii_whitespace());
    Ok(listed.split(' ').next().unwrap_or_default().to_string())
}

/// Go's `path.Dir`: all but the last element of a slash-separated path, cleaned.
fn slash_dir(path: &str) -> String {
    match path.rfind('/') {
        Some(slash) => super::config::clean(&path[..=slash]),
        None => ".".to_string(),
    }
}

/// Go's `path.Join`: the non-empty elements joined by slashes, cleaned, or "" for none.
fn slash_join(elements: &[String]) -> String {
    let parts: Vec<&str> = elements
        .iter()
        .map(String::as_str)
        .filter(|part| !part.is_empty())
        .collect();
    if parts.is_empty() {
        return String::new();
    }
    super::config::clean(&parts.join("/"))
}

/// Whether git ignores `path`, relative to `dir`, in `dir`'s checkout: an untracked file a pull
/// never brings. A tracked file is never ignored, and any trouble asking git counts as not. Go's
/// `vcs.Ignored`.
pub(super) fn ignored(dir: &Path, path: &str) -> bool {
    command(dir)
        .args(["check-ignore", "-q", "--", path])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Whether `dir` is itself a git repository's root, by the rule git applies before walking up to
/// an ancestor: a `.git` directory holding `HEAD`, `objects/` and `refs/`, or a `.git` file that
/// starts with "gitdir:" (a linked worktree). An empty or partial `.git` is not one. Go's
/// `vcs.IsGitRepo`.
pub(super) fn is_git_repo(dir: &Path) -> bool {
    let git = dir.join(".git");
    let Ok(info) = std::fs::metadata(&git) else {
        return false;
    };
    if info.is_file() {
        let mut head = [0u8; 7];
        let read = std::fs::File::open(&git).and_then(|mut file| {
            use std::io::Read;
            let mut filled = 0;
            while filled < head.len() {
                match file.read(&mut head[filled..])? {
                    0 => break,
                    count => filled += count,
                }
            }
            Ok(filled)
        });
        return read.is_ok_and(|filled| &head[..filled] == b"gitdir:");
    }
    info.is_dir()
        && std::fs::metadata(git.join("HEAD")).is_ok_and(|head| head.is_file())
        && ["objects", "refs"]
            .iter()
            .all(|sub| std::fs::metadata(git.join(sub)).is_ok_and(|meta| meta.is_dir()))
}

/// Whether `dir` is a linked worktree. A `.git` file alone doesn't say: a submodule or a
/// `git init --separate-git-dir` repository has one at its root too. Only in a linked worktree
/// does git's own directory differ from the common one. Go's `linkedWorktree`, with its git call.
pub(super) fn linked_worktree(dir: &Path) -> bool {
    if !std::fs::metadata(dir.join(".git")).is_ok_and(|info| !info.is_dir()) {
        return false;
    }
    let Ok(output) = command(dir)
        .args([
            "rev-parse",
            "--path-format=absolute",
            "--git-dir",
            "--git-common-dir",
        ])
        .output()
    else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    // Both streams, trimmed, as Go's executor reads them; one path per line, and a path may hold
    // spaces ("My Projects").
    let mut said = output.stdout;
    said.extend_from_slice(&output.stderr);
    let said = String::from_utf8_lossy(&said);
    let dirs: Vec<&str> = said.trim().split('\n').collect();
    dirs.len() == 2 && dirs[0] != dirs[1]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_git_file_counts_only_when_it_points_at_a_git_dir() {
        let scratch = crate::commands::Scratch::new("git-gitfile");
        let dir = &scratch.0;
        std::fs::write(dir.join(".git"), "gitdir: /elsewhere\n").unwrap();
        assert!(is_git_repo(dir));
        std::fs::write(dir.join(".git"), "gitdi").unwrap();
        assert!(!is_git_repo(dir));
        std::fs::remove_file(dir.join(".git")).unwrap();
        std::fs::create_dir(dir.join(".git")).unwrap();
        assert!(
            !is_git_repo(dir),
            "an empty .git directory is not a repository"
        );
    }
}
