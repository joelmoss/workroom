//! `workroomd credential`: git's credential helper for a local container workroom (#309).
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use super::flag;

/// `workroomd credential relay --port <port> [--socket <path>]`, the secret on stdin (#309): has a
/// container workroom ask the Mac for git's GitHub credentials, through `port` on this box's
/// loopback, and points git at `workroomd credential`. The relay file goes beside `--socket`, else
/// beside this binary (#308). Run on every connect, so it is idempotent.
fn run_credential_relay(args: &[String], socket: Option<&Path>) -> ExitCode {
    let Some(port) = flag(args, "--port").and_then(|p| p.parse::<u16>().ok()) else {
        eprintln!("error: credential relay needs --port <port>, and the secret on stdin");
        return ExitCode::FAILURE;
    };
    let mut secret = String::new();
    if std::io::stdin().read_line(&mut secret).is_err() {
        eprintln!("error: could not read the relay's secret from stdin");
        return ExitCode::FAILURE;
    }
    let result = crate::credential::directory(socket)
        .map_err(crate::credential::CredentialError::from)
        .and_then(|dir| crate::credential::install_relay(&dir, port, &secret))
        .and_then(|()| {
            let binary = std::env::current_exe()?;
            let helper = crate::credential::helper_command(&binary, socket);
            Ok(crate::credential::configure_git(
                || std::process::Command::new("git"),
                &helper,
            )?)
        });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// git's credential helper. A failure is reported on stderr, which git shows beside its own
/// "Authentication failed", and answers nothing, so git falls through as it would for no helper.
/// git appends the action after whatever the helper string holds (`--socket <path>`).
pub fn run_credential(args: &[String]) -> ExitCode {
    let socket = flag(args, "--socket").map(PathBuf::from);
    let action = action(args);
    if action == "relay" {
        return run_credential_relay(args, socket.as_deref());
    }
    let result = crate::credential::directory(socket.as_deref())
        .map_err(crate::credential::CredentialError::from)
        .and_then(|dir| {
            crate::credential::credential(&dir, action, std::io::stdin().lock(), std::io::stdout())
        });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Workroom: {e}");
            ExitCode::FAILURE
        }
    }
}

/// The first argument after `credential` that is neither a flag nor a flag's value.
fn action(args: &[String]) -> &str {
    let mut rest = args.iter().skip(1);
    while let Some(arg) = rest.next() {
        if arg.starts_with("--") {
            rest.next();
            continue;
        }
        return arg;
    }
    ""
}

#[cfg(test)]
mod tests {
    use super::action;

    #[test]
    fn the_action_is_found_after_the_socket_git_was_given() {
        let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(action(&args(&["credential", "get"])), "get");
        assert_eq!(
            action(&args(&["credential", "--socket", "/run/w.sock", "get"])),
            "get"
        );
        assert_eq!(
            action(&args(&["credential", "relay", "--port", "1"])),
            "relay"
        );
        assert_eq!(action(&args(&["credential"])), "");
    }
}
