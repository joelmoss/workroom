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
//!
//! The supervisor starts that shell through `run-supervisor --child`, which puts SIGINT and SIGQUIT
//! back to their defaults first. The supervisor ignores INT, and a shell starts a background job
//! with both ignored, so without it the command inherited INT ignored: bash and sh never take INT
//! back, and a Stop, Restart or Quit reached a command run in them only as the SIGKILL six seconds
//! later, never as the Ctrl-C a server shuts down cleanly on (#681).
use std::ffi::{OsStr, OsString};
use std::os::unix::process::CommandExt;
use std::process::ExitCode;

use super::flag;

const SUPERVISOR: &str = include_str!("../run_supervisor.sh");

/// What `run-supervisor` execs: `/bin/sh -c <supervisor> <name> <status> <launcher> run-supervisor
/// --child -- <child argv…>`, `launcher` being this binary.
pub fn invocation(status: &str, command: &str, shell: &str, launcher: &OsStr) -> Vec<OsString> {
    let (program, shell_flag) = crate::host::environment::probe_invocation(shell);
    let inner = format!("exec {} -c {}", quoted(program), quoted(command));
    let mut argv: Vec<OsString> = ["/bin/sh", "-c", SUPERVISOR, "workroom-run", status]
        .into_iter()
        .map(OsString::from)
        .collect();
    argv.push(launcher.to_os_string());
    argv.extend(
        [
            "run-supervisor",
            "--child",
            "--",
            program,
            shell_flag,
            &inner,
        ]
        .into_iter()
        .map(OsString::from),
    );
    argv
}

/// `value` as one POSIX shell word.
fn quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// The argv after `--child --`, when that is how this was run.
fn child_argv(args: &[String]) -> Option<&[String]> {
    let at = args.iter().position(|arg| arg == "--")?;
    (at > 0 && args[at - 1] == "--child" && at + 1 < args.len()).then(|| &args[at + 1..])
}

pub fn run_run_supervisor(args: &[String]) -> ExitCode {
    if let Some(child) = child_argv(args) {
        return run_child(child);
    }
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
    let launcher = match std::env::current_exe() {
        Ok(path) => path,
        Err(e) => {
            eprintln!("workroomd: could not start the run supervisor: no path to this binary: {e}");
            return ExitCode::from(super::DAEMON_UNAVAILABLE);
        }
    };
    let shell = crate::terminal::shell::user_shell(std::env::var_os("SHELL"));
    let argv = invocation(&status, command, &shell, launcher.as_os_str());
    let error = std::process::Command::new(&argv[0])
        .arg0(&argv[0])
        .args(&argv[1..])
        .exec();
    eprintln!("workroomd: could not start the run supervisor: {error}");
    ExitCode::from(super::DAEMON_UNAVAILABLE)
}

/// The supervisor's child: the command's shell, with SIGINT and SIGQUIT at their defaults.
fn run_child(argv: &[String]) -> ExitCode {
    for signal in [libc::SIGINT, libc::SIGQUIT] {
        // SAFETY: `signal` with `SIG_DFL` installs no handler, so nothing runs on a signal, and
        // this process is single-threaded here, about to exec.
        unsafe {
            libc::signal(signal, libc::SIG_DFL);
        }
    }
    let error = std::process::Command::new(&argv[0])
        .arg0(&argv[0])
        .args(&argv[1..])
        .exec();
    eprintln!("workroomd: could not start the run's command: {error}");
    ExitCode::from(super::DAEMON_UNAVAILABLE)
}

#[cfg(test)]
mod tests;
