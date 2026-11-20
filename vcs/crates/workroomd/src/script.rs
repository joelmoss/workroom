//! The one runner for setup and teardown scripts (#676): `workroomd run-script` uses it on a host,
//! and the CLI's `create` and `delete` call it in-process for a local workroom. Where the Go CLI's
//! `internal/script` and the daemon's runner differed, `docs/designs/one-script-runner.md` lists
//! each difference and which behaviour this keeps.
//!
//! A script runs in its directory, with what the user's login shell sets up there, as a terminal
//! opened there would (#560, `host::environment::probe`), the caller's variables on top (the
//! `WORKROOM_*` contract, `testdata/script-env`), and a process group of its own. A wall clock, or
//! a SIGTERM, SIGHUP or SIGINT to this process, ends the whole tree the way the exec service ends a
//! command (`wr_exec::end_tree`: the group and the descendants recorded before it, SIGKILL after a
//! grace). A signal this process was started ignoring (nohup's SIGHUP, a background job's SIGINT)
//! is no cancel. The runner prints nothing of its own except the probe's fallback note: each
//! caller words an [`Outcome`] its own way.
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

use crate::host::environment::{PROBE_TIMEOUT, fallback, floor_path, merge, probe_until};
use crate::util::lock_or_recover;

/// The exit status of a script stopped by the wall clock, as coreutils' `timeout` uses.
pub const TIMED_OUT: u8 = 124;
/// What a script that could not be started exits with, as a shell reports one.
pub const NOT_STARTED: u8 = 126;
/// How long a tree has between the SIGTERM and the SIGKILL, as the exec service gives a command.
pub const KILL_GRACE: Duration = Duration::from_secs(2);
/// How long output is still read once the script has exited, for a background job it left holding
/// the pipe: what it prints later is lost, where the Go CLI waited for it however long it took.
pub const DRAIN_GRACE: Duration = Duration::from_secs(1);
const POLL: Duration = Duration::from_millis(20);

/// One script to run.
pub struct Script<'a> {
    pub path: &'a Path,
    /// Where it runs, and where the login shell is read.
    pub dir: &'a Path,
    /// Set on top of the login environment, in order: the `WORKROOM_*` contract and any extras.
    pub variables: &'a [(String, String)],
    /// The wall clock, or none. A host's script always has one; a local script has none, as the
    /// Go CLI's had none: the app's own deadline ends the CLI, and a terminal's user waits.
    pub timeout: Option<Duration>,
    /// The user's shell, whose login environment the script gets (`probe_invocation` decides how).
    pub shell: String,
    /// How long the login shell may take to print its environment.
    pub probe_timeout: Duration,
    /// Between the SIGTERM and the SIGKILL when the tree is ended. A local caller the app SIGKILLs
    /// two seconds after its SIGTERM wants less, so it can still report.
    pub kill_grace: Duration,
}

impl<'a> Script<'a> {
    /// `path` in `dir`, with `variables`, the user's `$SHELL` (else the passwd shell), and the
    /// probe and kill bounds `run-script` has always had.
    pub fn new(
        path: &'a Path,
        dir: &'a Path,
        variables: &'a [(String, String)],
        timeout: Option<Duration>,
    ) -> Self {
        Script {
            path,
            dir,
            variables,
            timeout,
            shell: crate::terminal::shell::user_shell(std::env::var_os("SHELL")),
            probe_timeout: PROBE_TIMEOUT,
            kill_grace: KILL_GRACE,
        }
    }
}

/// The variables a local workroom's script gets (`testdata/script-env/local.txt`): a host's are
/// the app's to pass, since a host has no root project.
pub fn local_variables(name: &str, path: &Path, root: &Path) -> Vec<(String, String)> {
    let (path, root) = (path.display().to_string(), root.display().to_string());
    vec![
        ("WORKROOM_NAME".into(), name.into()),
        ("WORKROOM_PATH".into(), path),
        ("WORKROOM_ROOT_PATH".into(), root.clone()),
        // Deprecated: superseded by WORKROOM_ROOT_PATH; kept so existing scripts keep working.
        ("WORKROOM_PARENT_DIR".into(), root),
        ("WORKROOM_HOST".into(), "local".into()),
    ]
}

/// Where the script's output goes.
pub enum Output<'a> {
    /// Its stdout and stderr are this process's own, so a reader sees each line as it is printed
    /// and the two streams apart: `run-script`, which the app reads over the host connection.
    Inherit,
    /// Both into one pipe, written to the sink as they arrive, in the order printed: the CLI's log
    /// panel and NDJSON stream, which show and keep one combined output.
    Combined(&'a mut dyn Write),
}

/// How a run ended.
#[derive(Debug)]
pub enum Outcome {
    /// No file at the path: nothing ran, and no login shell was read for it.
    Absent,
    /// It couldn't be started (no execute bit, a missing interpreter): the script's failure.
    NotStarted(std::io::Error),
    /// It exited, or a signal not of our sending ended it.
    Exited(ExitStatus),
    /// The wall clock ran out and its tree was ended.
    TimedOut,
    /// This signal asked this process to stop, and the tree was ended, or the script never started.
    Cancelled(libc::c_int),
}

impl Outcome {
    /// Whether the script ran and passed: a missing script passes, as nothing was asked of it.
    pub fn passed(&self) -> bool {
        match self {
            Outcome::Absent => true,
            Outcome::Exited(status) => status.success(),
            _ => false,
        }
    }

    /// The exit status `run-script` reports: the script's own, 128 plus the signal that ended it
    /// (its own or ours), 124 for the wall clock, 126 when it never started.
    pub fn exit_code(&self) -> u8 {
        match self {
            Outcome::Absent | Outcome::NotStarted(_) => NOT_STARTED,
            Outcome::TimedOut => TIMED_OUT,
            Outcome::Cancelled(signal) => 128u8.saturating_add(*signal as u8),
            Outcome::Exited(status) => match (status.code(), status.signal()) {
                (Some(code), _) => code as u8,
                (None, Some(signal)) => 128u8.saturating_add(signal as u8),
                (None, None) => 1,
            },
        }
    }
}

/// Runs `script` with what the login shell sets up in its directory. `fallback_note` words the
/// line written when that can't be read (it gets the reason) and the script runs with this
/// process's environment instead: to stderr under [`Output::Inherit`], else to the sink, before
/// the script's own output.
///
/// Only for a script that has passed the trust check: the rc can read the directory's local tool
/// config, and no login shell is read for a script that isn't there.
pub fn run(script: &Script, mut output: Output, fallback_note: impl FnOnce(&str) -> String) -> Outcome {
    if std::fs::metadata(script.path)
        .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
    {
        return Outcome::Absent;
    }
    let signals = Signals::watch();
    let probed = probe_until(&script.shell, script.dir, script.probe_timeout, &|| {
        signals.received().is_some()
    });
    if let Some(signal) = signals.received() {
        return Outcome::Cancelled(signal);
    }
    let env = match probed {
        Ok(probed) => merge(probed, &floor_path()),
        Err(reason) => {
            let note = fallback_note(reason);
            match &mut output {
                Output::Inherit => {
                    let _ = std::io::stderr().write_all(note.as_bytes());
                }
                Output::Combined(sink) => {
                    let _ = sink.write_all(note.as_bytes());
                }
            }
            fallback()
        }
    };
    run_in(script, env, output)
}

/// Runs `script` with `env` as its whole environment, `script.variables` on top, reading no login
/// shell: [`run`] once it has the environment, and a test's seam.
pub fn run_in(script: &Script, env: BTreeMap<String, String>, output: Output) -> Outcome {
    let signals = Signals::watch();
    if let Some(signal) = signals.received() {
        return Outcome::Cancelled(signal);
    }
    let mut command = Command::new(script.path);
    command
        .current_dir(script.dir)
        .env_clear()
        .envs(&env)
        .envs(script.variables.iter().map(|(name, value)| (name, value)))
        .stdin(Stdio::null())
        .process_group(0);
    let mut sink = match output {
        Output::Inherit => None,
        Output::Combined(sink) => {
            let (reader, writer) = match std::io::pipe() {
                Ok(pipe) => pipe,
                Err(error) => return Outcome::NotStarted(error),
            };
            match writer.try_clone() {
                Ok(second) => command.stdout(writer).stderr(second),
                Err(error) => return Outcome::NotStarted(error),
            };
            Some(Drain { reader, sink, open: true })
        }
    };
    let spawned = command.spawn();
    // The write ends are the child's now: held here too, the pipe would never reach EOF.
    drop(command);
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => return Outcome::NotStarted(error),
    };
    let start = Instant::now();
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            if let Some(drain) = &mut sink {
                drain.until(Instant::now() + DRAIN_GRACE);
            }
            return Outcome::Exited(status);
        }
        let signalled = signals.received();
        let timed_out = script.timeout.is_some_and(|timeout| start.elapsed() >= timeout);
        if signalled.is_some() || timed_out {
            end(&mut child, script.kill_grace, sink.as_mut());
            return match signalled {
                Some(signal) => Outcome::Cancelled(signal),
                None => Outcome::TimedOut,
            };
        }
        match &mut sink {
            Some(drain) => drain.once(POLL),
            None => std::thread::sleep(POLL),
        }
    }
}

/// SIGTERM to the group, with its tree recorded first so a `setsid` escaper is still reached; then,
/// after the whole grace (even once the leader has gone: its group may still be cleaning up),
/// SIGKILL to what was recorded and to the group. What it printed meanwhile is read afterwards.
fn end(child: &mut Child, grace: Duration, sink: Option<&mut Drain>) {
    wr_exec::end_tree(child, libc::SIGTERM, grace);
    if let Some(drain) = sink {
        drain.until(Instant::now() + DRAIN_GRACE);
    }
}

/// The read end of a combined output's pipe, copied to its sink as it fills.
struct Drain<'a> {
    reader: std::io::PipeReader,
    sink: &'a mut dyn Write,
    open: bool,
}

impl Drain<'_> {
    /// Copies what arrives within `wait`, if anything.
    fn once(&mut self, wait: Duration) {
        if !self.open {
            std::thread::sleep(wait);
            return;
        }
        let mut poll = libc::pollfd {
            fd: self.reader.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid pollfd, for a descriptor this owns.
        let ready = unsafe { libc::poll(&mut poll, 1, wait.as_millis() as libc::c_int) };
        if ready <= 0 {
            return;
        }
        let mut chunk = [0u8; 65536];
        match self.reader.read(&mut chunk) {
            Ok(0) => self.open = false,
            Ok(count) => {
                let _ = self.sink.write_all(&chunk[..count]);
                let _ = self.sink.flush();
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => self.open = false,
        }
    }

    /// Copies until the pipe closes or `deadline` passes.
    fn until(&mut self, deadline: Instant) {
        while self.open {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            self.once(left.min(POLL));
        }
    }
}

/// The signals that cancel a run.
const CANCELLING: [libc::c_int; 3] = [libc::SIGTERM, libc::SIGHUP, libc::SIGINT];

/// The signal that asked this process to stop, 0 until one does.
static SIGNALLED: AtomicI32 = AtomicI32::new(0);

/// How many runs are watching, and the dispositions the first replaced, which the last restores.
static WATCHING: Mutex<(usize, Vec<(libc::c_int, libc::sigaction)>)> =
    Mutex::new((0, Vec::new()));

extern "C" fn record_signal(signal: libc::c_int) {
    SIGNALLED.store(signal, Ordering::SeqCst);
}

/// The cancelling signals, caught for as long as a run lasts and then handled as before: an
/// in-process caller carries on after the script (a delete removes the worktree), and a SIGTERM
/// then must end it as usual. Runs may nest or overlap; the first installs and the last restores.
struct Signals;

impl Signals {
    fn watch() -> Signals {
        let mut watching = lock_or_recover(&WATCHING);
        if watching.0 == 0 {
            SIGNALLED.store(0, Ordering::SeqCst);
            for signal in CANCELLING {
                // SAFETY: zeroed is a valid sigaction; `sigaction` only reads and writes these two.
                let mut handler: libc::sigaction = unsafe { std::mem::zeroed() };
                handler.sa_sigaction = record_signal as *const () as libc::sighandler_t;
                handler.sa_flags = libc::SA_RESTART;
                let mut previous: libc::sigaction = unsafe { std::mem::zeroed() };
                // SAFETY: as above; a null new action only reads the current one.
                unsafe { libc::sigaction(signal, std::ptr::null(), &mut previous) };
                if previous.sa_sigaction == libc::SIG_IGN {
                    continue;
                }
                // SAFETY: the handler only stores into an atomic, which is async-signal-safe.
                unsafe { libc::sigaction(signal, &handler, &mut previous) };
                watching.1.push((signal, previous));
            }
        }
        watching.0 += 1;
        Signals
    }

    fn received(&self) -> Option<libc::c_int> {
        Some(SIGNALLED.load(Ordering::SeqCst)).filter(|&signal| signal != 0)
    }
}

impl Drop for Signals {
    fn drop(&mut self) {
        let mut watching = lock_or_recover(&WATCHING);
        watching.0 -= 1;
        if watching.0 == 0 {
            for (signal, previous) in watching.1.drain(..) {
                // SAFETY: restores the disposition read when the first run began.
                unsafe { libc::sigaction(signal, &previous, std::ptr::null_mut()) };
            }
        }
    }
}
