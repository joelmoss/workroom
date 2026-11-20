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
