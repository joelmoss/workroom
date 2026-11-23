//! The commands only a person may run (#793): `trust`, which approves the setup and teardown
//! scripts Workroom runs, and `delete` and `delete-project`, which delete. Under a coding agent
//! each is refused with `NeedsTheUser` before anything is read or checked, whatever its flags
//! (`--json`, `--stdin`, `--confirm`, `--pretend`), so an agent asks the user rather than approve
//! its own setup script or delete a workroom. `trust status`, `--help` and every other command run
//! as they do anywhere else.
//!
//! **Under a coding agent** means one of this process's parents, up to init, is a known coding
//! agent: the program names the daemon knows them by (`terminal::api::AGENTS`), read as `prompt`
//! reads a session's foreground program (`process::executable_name`, the exec-time name on macOS,
//! `/proc/<pid>/exe` on Linux), or the name its `argv[0]` gave. The walk is `wr_exec::ancestry`:
//! one process at a time, bounded, ending at the first one that has gone. The Mac app runs these
//! commands itself, and launchd is its parent, so the app, a person's terminal, a script and cron
//! are never refused.
//!
//! It stops a confused coding agent, not a determined one: a program can start a command outside
//! its own process tree (`nohup`, `launchctl`), or type it into another terminal (`workroom send`,
//! #792). Nothing turns it off: the binary always walks its parents. The tests run the binary
//! outside their own process tree instead (`tests/outside`), so a test run by a coding agent
//! passes.

use super::kind::{CliError, Kind};
use crate::terminal::{api::AGENTS, process};

/// A command only a person may run: its name, and the words its refusal says.
struct Guarded {
    command: &'static str,
    /// What the command does, after its name.
    does: &'static str,
    /// What was left undone.
    undone: &'static str,
    /// What the user can do in the app instead.
    in_the_app: &'static str,
}

/// The commands only a person may run. A subcommand of one (`trust status`) is not.
const GUARDED: &[Guarded] = &[
    Guarded {
        command: "trust",
        does: "approves the setup and teardown scripts Workroom runs",
        undone: "Nothing was approved",
        in_the_app: "approve the script in the Workroom app, which asks when a create needs it",
    },
    Guarded {
        command: "delete",
        does: "deletes a workroom",
        undone: "Nothing was deleted",
        in_the_app: "delete the workroom in the Workroom app",
    },
    Guarded {
        command: "delete-project",
        does: "removes a project",
        undone: "Nothing was removed",
        in_the_app: "remove the project in the Workroom app",
    },
];

/// The refusal of `command` (a top-level command's name, its subcommand's `leaf`) under the coding
/// agent `agent_above` finds, or `None` when the command is no person's alone, or no coding agent
/// is above. Only a guarded command looks.
pub(super) fn refusal(
    command: &str,
    leaf: &str,
    agent_above: fn() -> Option<String>,
) -> Option<CliError> {
    let guarded = GUARDED
        .iter()
        .find(|guarded| guarded.command == command && leaf == command)?;
    let agent = agent_above()?;
    Some(CliError::new(
        Kind::NeedsTheUser,
        format!(
            "`workroom {command}` {does}, which only the user may do, and it ran under a coding \
             agent ({agent}). {undone}. Ask the user to {in_the_app}, or to run `workroom \
             {command}` themselves in their own terminal.",
            does = guarded.does,
            undone = guarded.undone,
            in_the_app = guarded.in_the_app,
        ),
    ))
}

/// The coding agent this process runs under: the name of the nearest of its parents that is one.
pub(super) fn coding_agent_above() -> Option<String> {
    // SAFETY: `getppid` takes no pointers and cannot fail.
    let parent = unsafe { libc::getppid() };
    coding_agent_among(wr_exec::ancestry(parent))
}

/// The first of `pids` that is a coding agent, by its name.
fn coding_agent_among(pids: impl IntoIterator<Item = i32>) -> Option<String> {
    pids.into_iter().find_map(coding_agent)
}

/// The coding agent `pid` is, by the name `prompt` knows a session's program by, or by its
/// `argv[0]`: Claude Code's native install runs a file named for its version
/// (`~/.local/share/claude/versions/<version>`), which `/proc/<pid>/exe` names on Linux, through
/// the `claude` its user typed.
fn coding_agent(pid: i32) -> Option<String> {
    let typed = process::arguments(pid)
        .and_then(|argv| argv.into_iter().next())
        .and_then(|first| {
            std::path::Path::new(&first)
                .file_name()
                .and_then(std::ffi::OsStr::to_str)
                .map(str::to_string)
        });
    [process::executable_name(pid), typed]
        .into_iter()
        .flatten()
        .find(|name| AGENTS.contains(&name.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Child, Command, Stdio};

    /// A folder this test made, removed with what is in it when the test ends.
    struct Scratch(std::path::PathBuf);

    impl Scratch {
        fn new(name: &str) -> Scratch {
            let dir = std::env::temp_dir().join(format!(
                "workroom-needs-the-user-{name}-{}",
                std::process::id()
            ));
            std::fs::create_dir(&dir).expect("a scratch folder of this test's own");
            Scratch(dir)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A process tree, killed when the test ends: `program` (a shell script) under `name`, which
    /// starts a `sleep` and prints its pid.
    struct Tree {
        top: Child,
        sleep: i32,
    }

    impl Tree {
        fn new(scratch: &Scratch, name: &str) -> Tree {
            let program = scratch.0.join(name);
            std::fs::write(&program, "#!/bin/sh\nsleep 30 &\necho $!\nwait\n").expect("script");
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755))
                .expect("chmod");
            let mut top = Command::new(&program)
                .stdout(Stdio::piped())
                .spawn()
                .expect("start the script");
            let mut line = String::new();
            BufReader::new(top.stdout.take().expect("stdout"))
                .read_line(&mut line)
                .expect("the sleep's pid");
            let sleep = line.trim().parse().expect("a pid");
            Tree { top, sleep }
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            // SAFETY: signals the sleep this test started.
            unsafe { libc::kill(self.sleep, libc::SIGKILL) };
            let _ = self.top.kill();
            let _ = self.top.wait();
        }
    }

    /// A script named `claude` or `codex` above a process is a coding agent above it, as its
    /// interpreter runs it on macOS and on Linux; one named otherwise is not, and neither is the
    /// process itself.
    #[test]
    fn a_coding_agent_is_found_among_a_processs_parents_by_its_name() {
        let scratch = Scratch::new("names");
        for name in AGENTS {
            let tree = Tree::new(&scratch, name);
            let lineage = wr_exec::ancestry(tree.sleep);
            assert_eq!(lineage[1], tree.top.id() as i32, "{lineage:?}");
            assert_eq!(coding_agent_among(lineage), Some(name.to_string()));
        }
        let other = Tree::new(&scratch, "claudette");
        assert_eq!(
            coding_agent_among([other.sleep, other.top.id() as i32]),
            None
        );
        // Gone: no name, and no agent.
        assert_eq!(coding_agent_among([i32::MAX]), None);
    }

    /// Only the commands a person alone may run are refused, never a subcommand of one, and only
    /// with a coding agent above; the message names the agent and what to ask the user.
    #[test]
    fn only_a_guarded_command_under_a_coding_agent_is_refused() {
        let claude = || Some("claude".to_string());
        let error = refusal("delete", "delete", claude).expect("refused");
        assert_eq!(error.kind, Kind::NeedsTheUser);
        assert_eq!(
            error.message,
            "`workroom delete` deletes a workroom, which only the user may do, and it ran under \
             a coding agent (claude). Nothing was deleted. Ask the user to delete the workroom \
             in the Workroom app, or to run `workroom delete` themselves in their own terminal."
        );
        assert!(refusal("trust", "trust", claude).is_some());
        assert!(refusal("delete-project", "delete-project", claude).is_some());
        assert!(refusal("trust", "status", claude).is_none());
        assert!(refusal("untrust", "untrust", claude).is_none());
        assert!(refusal("create", "create", claude).is_none());
        assert!(refusal("delete", "delete", || None).is_none());
    }
}
