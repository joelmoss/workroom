//! `workroomd credential`: git's credential helper for a local container workroom (#309).
use std::process::ExitCode;

use super::flag;

/// `workroomd credential relay --port <port>`, the secret on stdin (#309): has a container workroom
/// ask the Mac for git's GitHub credentials, through `port` on this box's loopback, and points git
/// at `workroomd credential`. Run on every connect, so it is idempotent.
fn run_credential_relay(args: &[String]) -> ExitCode {
    let Some(port) = flag(args, "--port").and_then(|p| p.parse::<u16>().ok()) else {
        eprintln!("error: credential relay needs --port <port>, and the secret on stdin");
        return ExitCode::FAILURE;
    };
    let mut secret = String::new();
    if std::io::stdin().read_line(&mut secret).is_err() {
        eprintln!("error: could not read the relay's secret from stdin");
        return ExitCode::FAILURE;
    }
    let result = crate::credential::directory()
        .map_err(crate::credential::CredentialError::from)
        .and_then(|dir| crate::credential::install_relay(&dir, port, &secret))
        .and_then(|()| {
            let binary = std::env::current_exe()?;
            let helper = crate::credential::helper_command(&binary);
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
pub fn run_credential(args: &[String]) -> ExitCode {
    let action = args.get(1).map(String::as_str).unwrap_or("");
    if action == "relay" {
        return run_credential_relay(args);
    }
    let result = crate::credential::directory()
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
