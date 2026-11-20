//! `workroomd run-script`: a remote workroom's setup or teardown script, run on its host through
//! the same runner the CLI runs a local one with (`crate::script`), so the two behave the same
//! (`docs/designs/scripts-on-every-workroom.md`, `docs/designs/one-script-runner.md`).
//!
//! This is the command line, the wording and the exit codes the app relies on (ADR 0057 pins the
//! `workroomd run-script: ` prefix, which it parses): the script's output goes straight to this
//! process's stdout and stderr, so the app reads it as it is printed, and the status is the
//! script's own, 128 plus a signal, `TIMED_OUT` or `NOT_STARTED`.
use std::collections::BTreeMap;
use std::path::Path;
use std::process::ExitCode;
use std::time::Duration;
// The unit tests' `use super::*` has always found these here.
#[cfg(test)]
use std::process::Command;
#[cfg(test)]
use std::time::Instant;

use super::flag;
pub use crate::script::{NOT_STARTED, TIMED_OUT};
use crate::script::{Outcome, Output, Script};

/// `workroomd run-script --dir <dir> --timeout <secs> [--env NAME=VALUE]... -- <script>`.
pub fn run_run_script(args: &[String]) -> ExitCode {
    let split = args.iter().position(|a| a == "--");
    let options = &args[..split.unwrap_or(args.len())];
    let script = split.and_then(|i| args.get(i + 1));
    let timeout = flag(options, "--timeout").and_then(|t| t.parse::<u64>().ok());
    let (Some(dir), Some(timeout), Some(script)) = (flag(options, "--dir"), timeout, script) else {
        eprintln!(
            "error: run-script needs --dir <dir> --timeout <secs> [--env NAME=VALUE]... -- <script>"
        );
        return ExitCode::FAILURE;
    };
    let extra = env_flags(options);
    let timeout = Duration::from_secs(timeout);
    let script = Script::new(Path::new(script), Path::new(&dir), &extra, Some(timeout));
    // The app has passed the script's trust check before it runs this, so the rc may read the
    // directory's local tool config: the script is about to run there anyway.
    let outcome = crate::script::run(&script, Output::Inherit, |reason| {
        format!(
            "workroomd run-script: couldn't read the login shell's environment ({reason}); using the daemon's own\n"
        )
    });
    ExitCode::from(report(script.path, timeout, outcome))
}

/// Every `--env NAME=VALUE` in `options`, in order.
fn env_flags(options: &[String]) -> Vec<(String, String)> {
    options
        .windows(2)
        .filter(|pair| pair[0] == "--env")
        .filter_map(|pair| pair[1].split_once('='))
        .map(|(name, value)| (name.to_string(), value.to_string()))
        .collect()
}

/// Runs `script` in `dir` with `env` and `extra` on top, reading no login shell, and returns its
/// exit status: the script's own, 128 plus the signal that ended it, `TIMED_OUT`, or `NOT_STARTED`.
pub fn run(
    script: &Path,
    dir: &Path,
    env: BTreeMap<String, String>,
    extra: &[(String, String)],
    timeout: Duration,
) -> u8 {
    let request = Script::new(script, dir, extra, Some(timeout));
    report(
        script,
        timeout,
        crate::script::run_in(&request, env, Output::Inherit),
    )
}

/// Says on stderr why a script didn't run to its end, and returns the status to exit with.
fn report(script: &Path, timeout: Duration, outcome: Outcome) -> u8 {
    match &outcome {
        Outcome::NotStarted(error) => {
            eprintln!(
                "workroomd run-script: {} could not be started: {error}",
                script.display()
            );
        }
        // Said as spawning it would have: the app checks for the script first, so this is a race.
        Outcome::Absent => {
            eprintln!(
                "workroomd run-script: {} could not be started: {}",
                script.display(),
                std::io::Error::from_raw_os_error(libc::ENOENT)
            );
        }
        Outcome::TimedOut => {
            eprintln!(
                "workroomd run-script: {} timed out after {} s",
                script.display(),
                timeout.as_secs()
            );
        }
        Outcome::Exited(_) | Outcome::Cancelled(_) => {}
    }
    outcome.exit_code()
}

#[cfg(test)]
mod tests;
