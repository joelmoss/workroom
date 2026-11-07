//! `workroomd run-script`: a remote workroom's setup or teardown script, run on its host the way the
//! Mac's CLI runs one locally (`internal/script`), so the two behave the same
//! (`docs/designs/scripts-on-every-workroom.md`).
//!
//! The environment is what the host user's login shell sets up in the script's directory, as a
//! terminal opened there would (#560), read by `host::environment::login_environment`. The script
//! runs in a process group of its own, its output going straight to this process's stdout and
//! stderr, so the app reads it as it is printed. A wall clock, or a SIGTERM, SIGHUP or SIGINT to
//! this process, ends the whole tree the way the exec service ends a command (`wr_exec::end_tree`:
//! the group and the descendants recorded before it, SIGKILL two seconds later).
use std::collections::BTreeMap;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, ExitCode, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

use super::flag;
use crate::host::environment::{PROBE_TIMEOUT, login_environment};

/// The exit status of a script stopped by the wall clock, as coreutils' `timeout` uses.
pub const TIMED_OUT: u8 = 124;
/// What a script that could not be started exits with, as a shell reports one.
pub const NOT_STARTED: u8 = 126;
const KILL_GRACE: Duration = Duration::from_secs(2);

/// The signal that asked this process to stop, 0 until one does.
static SIGNALLED: AtomicI32 = AtomicI32::new(0);

extern "C" fn record_signal(signal: libc::c_int) {
    SIGNALLED.store(signal, Ordering::SeqCst);
}

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
    install_signal_handlers();
    let shell = crate::terminal::shell::user_shell(std::env::var_os("SHELL"));
    // The app has passed the script's trust check before it runs this, so the rc may read the
    // directory's local tool config: the script is about to run there anyway.
    let env = login_environment(&shell, Path::new(&dir), PROBE_TIMEOUT, |reason| {
        eprintln!(
            "workroomd run-script: couldn't read the login shell's environment ({reason}); using the daemon's own"
        );
    });
    ExitCode::from(run(
        Path::new(script),
        Path::new(&dir),
        env,
        &extra,
        Duration::from_secs(timeout),
    ))
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

fn install_signal_handlers() {
    for signal in [libc::SIGTERM, libc::SIGHUP, libc::SIGINT] {
        // SAFETY: the handler only stores into an atomic, which is async-signal-safe.
        unsafe { libc::signal(signal, record_signal as *const () as libc::sighandler_t) };
    }
}

/// Runs `script` in `dir` with `env` and `extra` on top, and returns its exit status: the script's
/// own, 128 plus the signal that ended it, `TIMED_OUT`, or `NOT_STARTED`.
pub fn run(
    script: &Path,
    dir: &Path,
    env: BTreeMap<String, String>,
    extra: &[(String, String)],
    timeout: Duration,
) -> u8 {
    let mut command = Command::new(script);
    command
        .current_dir(dir)
        .env_clear()
        .envs(&env)
        .envs(extra.iter().map(|(name, value)| (name, value)))
        .stdin(Stdio::null())
        .process_group(0);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!(
                "workroomd run-script: {} could not be started: {error}",
                script.display()
            );
            return NOT_STARTED;
        }
    };
    let start = Instant::now();
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return exit_status(status);
        }
        let signalled = SIGNALLED.load(Ordering::SeqCst);
        if signalled != 0 || start.elapsed() >= timeout {
            // SIGTERM to the group, with its tree recorded first so a `setsid` escaper is still
            // reached; then, after the whole grace (even once the leader has gone: its group may
            // still be cleaning up), SIGKILL to what was recorded and to the group.
            wr_exec::end_tree(&mut child, libc::SIGTERM, KILL_GRACE);
            if signalled != 0 {
                return 128u8.saturating_add(signalled as u8);
            }
            eprintln!(
                "workroomd run-script: {} timed out after {} s",
                script.display(),
                timeout.as_secs()
            );
            return TIMED_OUT;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn exit_status(status: ExitStatus) -> u8 {
    match (status.code(), status.signal()) {
        (Some(code), _) => code as u8,
        (None, Some(signal)) => 128u8.saturating_add(signal as u8),
        (None, None) => 1,
    }
}

#[cfg(test)]
mod tests;
