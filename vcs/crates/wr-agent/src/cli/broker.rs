//! `wr-agent enrol` and `wr-agent credential`: the credential broker client's commands.
use std::process::ExitCode;

use super::flag;

/// Enrols with the credential broker (#251), then points git at `wr-agent credential`. The code
/// arrives on stdin, never in argv, where `ps` would show it.
pub fn run_enrol(args: &[String]) -> ExitCode {
    let (Some(workroom), Some(broker)) = (flag(args, "--workroom"), flag(args, "--broker")) else {
        eprintln!("error: enrol needs --workroom <id> and --broker <url>, and the code on stdin");
        return ExitCode::FAILURE;
    };
    let mut code = String::new();
    if std::io::stdin().read_line(&mut code).is_err() {
        eprintln!("error: could not read the enrolment code from stdin");
        return ExitCode::FAILURE;
    }
    // git only after the broker enrolled the key: a failed enrolment must leave whatever helper
    // already worked (a provider's own) in place. If git then fails, the command fails, the Mac
    // cancels the grant, and a retry enrols a fresh key.
    let result = crate::broker::directory()
        .map_err(crate::broker::BrokerError::from)
        .and_then(|dir| crate::broker::enrol(&dir, &workroom, &broker, &code))
        .and_then(|()| {
            let binary = std::env::current_exe()?;
            let helper = crate::broker::helper_command(&binary);
            Ok(crate::broker::configure_git(
                || std::process::Command::new("git"),
                &helper,
            )?)
        });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        // The refusal's code on its own line, for the app to switch on.
        Err(crate::broker::BrokerError::Refused { code, message, .. }) => {
            eprintln!("error: {message}");
            eprintln!("refusal: {code}");
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `wr-agent credential relay --port <port>`, the secret on stdin (#309): has a workroom that never
/// enrolled ask the Mac for git's GitHub credentials, through `port` on this box's loopback, and
/// points git at `wr-agent credential`. Run on every connect, so it is idempotent.
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
    let result = crate::broker::directory()
        .map_err(crate::broker::BrokerError::from)
        .and_then(|dir| crate::broker::install_relay(&dir, port, &secret))
        .and_then(|()| {
            let binary = std::env::current_exe()?;
            let helper = crate::broker::helper_command(&binary);
            Ok(crate::broker::configure_git(
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
    let result = crate::broker::directory()
        .map_err(crate::broker::BrokerError::from)
        .and_then(|dir| {
            crate::broker::credential(&dir, action, std::io::stdin().lock(), std::io::stdout())
        });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Workroom: {e}");
            ExitCode::FAILURE
        }
    }
}
