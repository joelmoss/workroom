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
