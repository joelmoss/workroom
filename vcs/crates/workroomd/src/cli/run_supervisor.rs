//! `workroomd run-supervisor`: what a run session's pty runs (#522). It becomes the run supervisor
//! (`run_supervisor.sh`, carried inside this binary so every host has the version its daemon
//! speaks), around the user's command in the login shell of wherever it runs.
//!
//! The shell is chosen as the app used to choose it for a run tab on this Mac
//! (`ShellEnvironment.loginShellInvocation`), and as `run-script` chooses it on a host: `$SHELL`
//! when it is a POSIX shell, run login and interactive (`-lic`) so it has the user's PATH, aliases
//! and version-manager shims; anything else (fish, nushell, csh) falls back to a login `/bin/sh
//! -lc`, whose interactive rc does not load. The command runs through that shell's `-c`, so a
//! compound command (`cd web && npm run dev`) works, and `exec` keeps one pid for the server.
use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::process::ExitCode;

use super::flag;

const SUPERVISOR: &str = include_str!("../run_supervisor.sh");

/// What `run-supervisor` execs: `/bin/sh -c <supervisor> <name> <status> <child argv…>`.
pub fn invocation(status: &str, command: &str, shell: &str) -> Vec<OsString> {
    let (program, shell_flag) = crate::host::environment::probe_invocation(shell);
    let inner = format!("exec {} -c {}", quoted(program), quoted(command));
    [
        "/bin/sh",
        "-c",
        SUPERVISOR,
        "workroom-run",
        status,
        program,
        shell_flag,
        &inner,
    ]
    .into_iter()
    .map(OsString::from)
    .collect()
}

/// `value` as one POSIX shell word.
fn quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

pub fn run_run_supervisor(args: &[String]) -> ExitCode {
    let Some(status) = flag(args, "--status") else {
        eprintln!("error: run-supervisor needs --status <path> -- <command>");
        return ExitCode::FAILURE;
    };
    let Some(command) = args
        .iter()
        .position(|arg| arg == "--")
        .and_then(|at| args.get(at + 1))
    else {
        eprintln!("error: run-supervisor needs --status <path> -- <command>");
        return ExitCode::FAILURE;
    };
    let shell = crate::terminal::shell::user_shell(std::env::var_os("SHELL"));
    let argv = invocation(&status, command, &shell);
    let error = std::process::Command::new(&argv[0])
        .arg0(&argv[0])
        .args(&argv[1..])
        .exec();
    eprintln!("workroomd: could not start the run supervisor: {error}");
    ExitCode::from(super::DAEMON_UNAVAILABLE)
}

#[cfg(test)]
mod tests;
