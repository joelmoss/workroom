//! The commands only a person may run (#793): `trust`, which approves the setup and teardown
//! scripts Workroom runs, and `delete` and `delete-project`, which delete. Under a coding agent
//! each is refused with `NeedsTheUser` before anything is read or checked, whatever its flags
//! (`--json`, `--stdin`, `--confirm`), so an agent asks the user rather than approve its own setup
//! script or delete a workroom. A `delete --pretend` or `delete-project --pretend` changes nothing,
//! so it runs; a `trust --pretend` doesn't. `trust status`, `--help` and every other command run as
//! they do anywhere else.
//!
//! Every approval and delete is refused under one too, whatever command reaches it, since a
//! terminal an agent holds (a pty, tmux, `script`) is no person to ask: a create's prompt for an
//! unapproved setup script (`create_refusal`), every write of an approval
//! (`Config::set_trusted_script`, `approval_refusal`), and every delete (`teardown::Delete`,
//! `Config::remove_project`, `deletion_refusal`).
//!
//! **Under a coding agent** means one of this process's parents, up to init, is a known coding
//! agent ([`coding_agent`]): one the daemon knows by name (`terminal::api::AGENTS`), read as
//! `prompt` reads a session's foreground program (`process::executable_name`) or from its
//! `argv[0]`, case aside; or one whose executable or script lies in a coding agent's folder
//! ([`AGENT_FOLDERS`]: Claude Code's native install, npm package and Agent SDK, Codex's npm
//! package). The walk is `wr_exec::ancestry`: one process at a time, bounded, ending at the first
//! one that has gone. The Mac app runs these commands itself, and launchd is its parent, so the
//! app, a person's terminal, a script and cron are never refused. An agent built into an editor
//! (Cursor's, Copilot's) runs commands in the editor's terminal, whose processes are the editor's:
//! it can't be told from the user.
//!
//! It stops a confused coding agent, not a determined one: a program can start a command outside
//! its own process tree (a double fork, `launchctl submit`, a tmux server, `ssh localhost`), or type
//! it into another terminal (`workroom send`, #792). Nothing turns it off: the binary always walks
//! its parents. The tests run the binary outside their own process tree instead
//! (`tests/outside`), so a test run by a coding agent passes.

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
    /// Whether its `--pretend` changes nothing, so a coding agent may run it to show the user what
    /// the command would do.
    dry_run: bool,
}

/// The commands only a person may run. A subcommand of one (`trust status`) is not.
const GUARDED: &[Guarded] = &[
    Guarded {
        command: "trust",
        does: "approves the setup and teardown scripts Workroom runs",
        undone: "Nothing was approved",
        in_the_app: "approve the script in the Workroom app, which asks when a create needs it",
        dry_run: false,
    },
    Guarded {
        command: "delete",
        does: "deletes a workroom",
        undone: "Nothing was deleted",
        in_the_app: "delete the workroom in the Workroom app",
        dry_run: true,
    },
    Guarded {
        command: "delete-project",
        does: "removes a project",
        undone: "Nothing was removed",
        in_the_app: "remove the project in the Workroom app",
        dry_run: true,
    },
];

/// What a guarded command's `--help` and CLI page say of it, after its description.
pub(super) fn says(command: &str) -> Option<String> {
    let guarded = GUARDED.iter().find(|guarded| guarded.command == command)?;
    let mut text = String::from(
        "Only a person may run it. Under a coding agent, such as Claude Code or Codex, it is \
         refused with NeedsTheUser and changes nothing, on a Mac or elsewhere, before anything \
         else is checked: the agent asks you to do it in the Workroom app or in your own \
         terminal.",
    );
    if guarded.dry_run {
        text += " With --pretend, which changes nothing, it runs.";
    }
    text += " That stops a confused coding agent, not a determined one.";
    Some(text)
}

/// The refusal of `command` (a top-level command's name, its subcommand's `leaf`) under the coding
/// agent `agent_above` finds, or `None` when the command is no person's alone, is a dry run
/// (`pretend`) that changes nothing, or no coding agent is above. Only a guarded command looks.
pub(super) fn refusal(
    command: &str,
    leaf: &str,
    pretend: bool,
    agent_above: fn() -> Option<String>,
) -> Option<CliError> {
    let guarded = GUARDED
        .iter()
        .find(|guarded| guarded.command == command && leaf == command)?;
    if pretend && guarded.dry_run {
        return None;
    }
    Some(refused(guarded, &agent_above()?))
}

fn refused(guarded: &Guarded, agent: &str) -> CliError {
    CliError::new(
        Kind::NeedsTheUser,
        format!(
            "`workroom {command}` {does}, which only the user may do, and it ran under a coding \
             agent ({agent}). {undone}. Ask the user to {in_the_app}, or to run `workroom \
             {command}` themselves in their own terminal.",
            command = guarded.command,
            does = guarded.does,
            undone = guarded.undone,
            in_the_app = guarded.in_the_app,
        ),
    )
}

/// A create's refusal to ask about `file`, a script this Mac hasn't approved, under a coding agent
/// `agent_above` finds: a person at a terminal is asked, and a pty an agent holds is no person.
pub(super) fn create_refusal(file: &str, agent_above: fn() -> Option<String>) -> Option<CliError> {
    let agent = agent_above()?;
    Some(CliError::new(
        Kind::NeedsTheUser,
        format!(
            "`workroom create` would run {file}, which this Mac hasn't approved, and only the user \
             may approve it: it ran under a coding agent ({agent}). Nothing was approved. Ask \
             the user to approve the script in the Workroom app, or to run `workroom \
             create` themselves in their own terminal, or create without the script with \
             `--skip-setup`."
        ),
    ))
}

/// The refusal to record an approval under a coding agent, for every write of one
/// (`Config::set_trusted_script`), whatever command got there.
pub(super) fn approval_refusal(agent_above: fn() -> Option<String>) -> Option<CliError> {
    let agent = agent_above()?;
    Some(CliError::new(
        Kind::NeedsTheUser,
        format!(
            "Approving a setup or teardown script is the user's to do, and this ran under a coding \
             agent ({agent}). Nothing was approved. Ask the user to approve it in the Workroom \
             app, or to run the command themselves in their own terminal."
        ),
    ))
}

/// The refusal to delete a workroom, or with `project` to remove a project, under a coding agent,
/// for every delete (`teardown::Delete`, `Config::remove_project`), whatever command got there.
pub(super) fn deletion_refusal(
    project: bool,
    agent_above: fn() -> Option<String>,
) -> Option<CliError> {
    let guarded = if project { &GUARDED[2] } else { &GUARDED[1] };
    Some(refused(guarded, &agent_above()?))
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

/// Where a coding agent's program lives when no name of its is one of [`AGENTS`], for finding one
/// above a process only (`prompt` knows a session's agent by its name alone): a folder of the
/// path, case aside. Claude Code's native install runs a file named for its version
/// (`~/.local/share/claude/versions/<version>`, its exec path; on Linux `/proc/<pid>/exe`, while
/// its arguments can read the version too), and its npm package, and the Agent SDK's copy of it,
/// run `cli.js` under node.
const AGENT_FOLDERS: &[(&str, &str)] = &[
    ("/claude/versions/", "claude"),
    ("/@anthropic-ai/claude-code/", "claude"),
    ("/@anthropic-ai/claude-agent-sdk/", "claude"),
    ("/@openai/codex/", "codex"),
];

/// The coding agent `pid` is, as [`AGENTS`] names it: by the name `prompt` knows a session's
/// program by, or its `argv[0]`, case aside (the Claude app, `Claude`, starts the shells of the
/// MCP servers it runs), or by the folders of its executable or its script ([`AGENT_FOLDERS`]).
fn coding_agent(pid: i32) -> Option<String> {
    let typed = process::arguments(pid)
        .and_then(|argv| argv.into_iter().next())
        .and_then(|first| file_name(&first).map(str::to_string));
    let named = [process::executable_name(pid), typed]
        .into_iter()
        .flatten()
        .find_map(|name| {
            AGENTS
                .iter()
                .find(|agent| agent.eq_ignore_ascii_case(&name))
                .map(|agent| agent.to_string())
        });
    named.or_else(|| {
        [executable_path(pid), process::program(pid)]
            .into_iter()
            .flatten()
            .find_map(|path| in_an_agents_folder(&path).map(str::to_string))
    })
}

/// The coding agent whose folder `path` is in ([`AGENT_FOLDERS`]), case aside.
fn in_an_agents_folder(path: &str) -> Option<&'static str> {
    let path = path.to_ascii_lowercase();
    AGENT_FOLDERS
        .iter()
        .find(|(folder, _)| path.contains(folder))
        .map(|(_, agent)| *agent)
}

fn file_name(path: &str) -> Option<&str> {
    std::path::Path::new(path)
        .file_name()
        .and_then(std::ffi::OsStr::to_str)
}

/// The file process `pid` runs: `proc_pidpath` on macOS, `/proc/<pid>/exe` on Linux.
#[cfg(target_os = "macos")]
fn executable_path(pid: i32) -> Option<String> {
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: `buffer` is as long as the size passed, so the kernel writes within it.
    let written = unsafe {
        libc::proc_pidpath(
            pid,
            buffer.as_mut_ptr().cast(),
            libc::PROC_PIDPATHINFO_MAXSIZE as u32,
        )
    };
    (written > 0).then(|| String::from_utf8_lossy(&buffer[..written as usize]).into_owned())
}

#[cfg(target_os = "linux")]
fn executable_path(pid: i32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/exe"))
        .ok()
        .and_then(|path| path.to_str().map(str::to_string))
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

    /// What the top of a tree runs: start a `sleep`, print its pid and wait for it.
    const SLEEP: &str = "sleep 30 &\necho $!\nwait\n";

    impl Tree {
        /// A script at `name` under the scratch folder (folders made as needed), run by its
        /// `#!/bin/sh` line.
        fn new(scratch: &Scratch, name: &str) -> Tree {
            let program = scratch.0.join(name);
            std::fs::create_dir_all(program.parent().expect("folder")).expect("folders");
            std::fs::write(&program, format!("#!/bin/sh\n{SLEEP}")).expect("script");
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755))
                .expect("chmod");
            Tree::of(Command::new(&program))
        }

        /// `command`, which runs [`SLEEP`].
        fn of(mut command: Command) -> Tree {
            let mut top = command
                .stdout(Stdio::piped())
                .spawn()
                .expect("start the tree");
            let mut line = String::new();
            BufReader::new(top.stdout.take().expect("stdout"))
                .read_line(&mut line)
                .expect("the sleep's pid");
            let sleep = line.trim().parse().expect("a pid");
            Tree { top, sleep }
        }

        fn top(&self) -> i32 {
            self.top.id() as i32
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

    /// The review's false positive (#793): a shell whose `-c` string names a coding agent's path
    /// runs the shell, so it is no coding agent; nor is a script run by an interpreter whose
    /// path only mentions one in a flag's code.
    #[test]
    fn a_shells_command_string_naming_an_agent_is_no_coding_agent() {
        let scratch = Scratch::new("command-string");
        let codex = scratch.0.join("codex");
        std::fs::write(&codex, "#!/bin/sh\n").expect("a file named codex");
        let mut sh = Command::new("/bin/sh");
        sh.arg("-c")
            .arg(format!("{SLEEP}ls {} >/dev/null", codex.display()));
        let tree = Tree::of(sh);
        assert_eq!(coding_agent_among([tree.sleep, tree.top()]), None);
        let mut sh = Command::new("/bin/sh");
        sh.arg("-c").arg(SLEEP).arg(&codex);
        let tree = Tree::of(sh);
        assert_eq!(coding_agent_among([tree.sleep, tree.top()]), None);
    }

    /// Beside the names: the Claude app (`Claude`, case aside), Claude Code's npm package and the
    /// Agent SDK's copy of it (`cli.js` under node, here under sh, an interpreter as node is), and
    /// Codex's npm package.
    #[test]
    fn a_coding_agent_is_found_by_its_app_name_and_its_packages_folder() {
        let scratch = Scratch::new("folders");
        for (path, agent) in [
            ("Claude", "claude"),
            ("CODEX", "codex"),
            (
                "lib/node_modules/@anthropic-ai/claude-code/cli.js",
                "claude",
            ),
            (
                "app/node_modules/@anthropic-ai/claude-agent-sdk/cli.js",
                "claude",
            ),
            ("lib/node_modules/@openai/codex/bin/codex.js", "codex"),
        ] {
            let tree = Tree::new(&scratch, path);
            assert_eq!(
                coding_agent_among([tree.sleep, tree.top()]),
                Some(agent.to_string()),
                "{path}"
            );
        }
        let other = Tree::new(&scratch, "lib/node_modules/@anthropic-ai/sdk/cli.js");
        assert_eq!(coding_agent_among([other.sleep, other.top()]), None);
    }

    /// Claude Code's native install, a file named for its version (`claude/versions/<version>`),
    /// run by a name that is no agent's and with arguments that read its version, as one that
    /// renames itself does: found by the file it runs. A copy of a shell stands in for it.
    #[test]
    fn a_native_claude_code_that_renames_itself_is_found_by_its_file() {
        use std::os::unix::process::CommandExt;
        let Some(shell) = ["/bin/bash", "/bin/dash"]
            .into_iter()
            .find(|shell| std::path::Path::new(shell).is_file())
        else {
            eprintln!("skipped: no bash or dash to stand in for a native binary");
            return;
        };
        let scratch = Scratch::new("native");
        let versions = scratch.0.join("share/claude/versions");
        std::fs::create_dir_all(&versions).expect("versions folder");
        let native = versions.join("2.1.232");
        // Its bytes only. `fs::copy` (copyfile) carries a system binary's HFS compression over, as
        // a `com.apple.decmpfs` attribute codesign then fails on ("Attribute not found") when the
        // machine is busy.
        std::fs::write(&native, std::fs::read(shell).expect("read the shell")).expect("copy it");
        std::fs::set_permissions(&native, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        // macOS kills a copy of a system binary signed as Apple's; signed afresh it runs.
        #[cfg(target_os = "macos")]
        {
            let signed = Command::new("/usr/bin/codesign")
                .args(["--sign", "-", "--force"])
                .arg(&native)
                .output()
                .expect("run codesign");
            assert!(
                signed.status.success(),
                "sign the copy: {}: {}",
                signed.status,
                String::from_utf8_lossy(&signed.stderr)
            );
        }
        let mut command = Command::new(&native);
        command.arg0("2.1.232").arg("-c").arg(SLEEP);
        let tree = Tree::of(command);
        assert_eq!(
            process::arguments(tree.top()).and_then(|argv| argv.into_iter().next()),
            Some("2.1.232".to_string())
        );
        assert_eq!(
            coding_agent_among([tree.sleep, tree.top()]),
            Some("claude".to_string())
        );
    }

    /// Only the commands a person alone may run are refused, never a subcommand of one, and only
    /// with a coding agent above; the message names the agent and what to ask the user.
    #[test]
    fn only_a_guarded_command_under_a_coding_agent_is_refused() {
        let claude = || Some("claude".to_string());
        let error = refusal("delete", "delete", false, claude).expect("refused");
        assert_eq!(error.kind, Kind::NeedsTheUser);
        assert_eq!(
            error.message,
            "`workroom delete` deletes a workroom, which only the user may do, and it ran under \
             a coding agent (claude). Nothing was deleted. Ask the user to delete the workroom \
             in the Workroom app, or to run `workroom delete` themselves in their own terminal."
        );
        assert!(refusal("trust", "trust", false, claude).is_some());
        assert!(refusal("delete-project", "delete-project", false, claude).is_some());
        assert!(refusal("trust", "status", false, claude).is_none());
        assert!(refusal("untrust", "untrust", false, claude).is_none());
        assert!(refusal("create", "create", false, claude).is_none());
        assert!(refusal("delete", "delete", false, || None).is_none());
        // A delete's dry run changes nothing, so it goes on (`delete-project`'s since #798);
        // `trust`'s doesn't.
        assert!(refusal("delete", "delete", true, claude).is_none());
        assert!(refusal("delete-project", "delete-project", true, claude).is_none());
        assert!(refusal("trust", "trust", true, claude).is_some());
        // A create's prompt, and every approval or removal, whatever command got there.
        let create = create_refusal("scripts/workroom_setup", claude).expect("refused");
        assert_eq!(create.kind, Kind::NeedsTheUser);
        assert!(
            create.message.contains("--skip-setup"),
            "{}",
            create.message
        );
        assert!(create_refusal("scripts/workroom_setup", || None).is_none());
        assert!(approval_refusal(claude).is_some() && approval_refusal(|| None).is_none());
        assert!(
            deletion_refusal(true, claude)
                .unwrap()
                .message
                .contains("removes a project")
        );
        assert!(deletion_refusal(false, || None).is_none());
    }
}
