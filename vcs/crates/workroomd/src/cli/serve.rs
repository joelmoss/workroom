//! `workroomd serve`: the daemon itself, on a socket or on stdin/stdout.
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use crate::daemon::handoff;
use crate::daemon::serve::{self, BUILD, DEFAULT_IDLE_TIMEOUT, Daemon};

/// Serves exactly one connection over stdin/stdout, then exits.
///
/// A transport test entry point: `ssh host workroomd serve --stdio` has the shape of the driver
/// contract's `openStream`, and so does a provider SDK's exec call. There is no socket, no listener
/// and no single-instance lock, because the caller already decided which machine and which
/// process — the stream IS the session's address.
///
/// Note what this deliberately does NOT do: outlive the connection. Production reaches a supervised
/// `serve --idle-timeout never` through `relay` instead (see `run_relay`), because a remote session
/// must survive a dropped link and these die with it.
pub fn run_serve_stdio() -> ExitCode {
    let sessions = crate::terminal::session::SessionStore::new();
    let result = crate::daemon::serve::handle_connection(
        crate::daemon::transport::StdioTransport,
        sessions.clone(),
    );
    // Nothing else can reach these sessions: the stream was their only route in.
    sessions.kill_all();
    // A kill still on its own thread took its session out of the store before `kill_all` looked,
    // and exiting now would cut it off between its SIGHUP and its SIGKILL. Waited for after
    // `kill_all`, so no other session's SIGHUP waits on it.
    sessions.wait_for_kills(std::time::Instant::now() + crate::terminal::session::KILL_EXIT_WAIT);
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `serve --user` and its `--own` folders: who a container's daemon becomes (#308).
#[derive(Debug, Default)]
pub struct Become {
    pub user: Option<String>,
    pub own: Vec<PathBuf>,
}

pub fn run_serve(
    socket: PathBuf,
    idle: Option<String>,
    handoff: Option<PathBuf>,
    mut screens: Option<PathBuf>,
    as_user: Become,
) -> ExitCode {
    // Reported once the log exists, below: a spawned daemon's stderr is /dev/null until then.
    let timeout = idle_timeout(idle.as_deref());
    // This is Workroom's existing local/remote lifetime distinction: every remote driver starts
    // `serve --idle-timeout never`, while the Mac's app and attach client use the idle default.
    // Choose before any request threads start, and reselect from the carried argv after hand-off.
    crate::host::environment::configure_read_environment(timeout == Ok(Duration::MAX));
    // Before anything is made, so all of it is the user's: a container's entrypoint starts as root.
    if let Some(user) = as_user.user {
        let account = match crate::host::account::lookup(&user) {
            Ok(account) => account,
            Err(e) => {
                eprintln!("error: serve --user {user}: {e}");
                return ExitCode::FAILURE;
            }
        };
        screens = screens.map(|dir| crate::host::account::expand_home(&dir, &account.home));
        let mut folders: Vec<(PathBuf, bool)> = socket
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .map(|parent| vec![(parent.to_path_buf(), true)])
            .unwrap_or_default();
        folders.extend(as_user.own.into_iter().map(|dir| (dir, false)));
        if let Err(e) = crate::host::account::become_user(&account, &folders) {
            eprintln!("error: serve could not become {user}: {e}");
            return ExitCode::FAILURE;
        }
    }
    // Before anything can fail, so every line below and every session's end has somewhere to go.
    // The log lives beside the socket, so its folder comes first; the lock reports a failure.
    let _ = serve::make_socket_folder(&socket);
    crate::daemon::log::redirect_stderr(&socket);
    // Every way out from here writes a line: a return below, a panic, or a signal that ends it.
    crate::daemon::log::note_panics();
    crate::daemon::log::note_fatal_signals();
    let timeout = match timeout {
        Ok(timeout) => timeout,
        Err(e) => {
            crate::note!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    // First, before an update can replace the file at this path: see `handoff::Context::digest`.
    let digest = handoff::own_binary()
        .and_then(|path| handoff::digest(&path))
        .ok();
    let mut daemon = Daemon::new();
    let (lock, listener) = match handoff {
        Some(table) => match adopt(&daemon, &table) {
            Ok(carried) => {
                crate::note!(
                    "serving {} as the program handed to ({BUILD})",
                    socket.display()
                );
                carried
            }
            Err(e) => {
                crate::note!("error: could not take over from the program handed off: {e}");
                return ExitCode::FAILURE;
            }
        },
        None => {
            // The lock, not the bind, is what guarantees a single daemon — see serve.rs. Losing the
            // race is a normal outcome (two clients spawning at once), not an error worth a
            // non-zero exit: the other daemon is serving, which is all the caller wanted.
            let lock = match serve::acquire_instance_lock(&socket) {
                Ok(lock) => lock,
                Err(serve::ServeError::AlreadyRunning(_)) => {
                    crate::note!(
                        "not serving {}: another daemon already is",
                        socket.display()
                    );
                    return ExitCode::SUCCESS;
                }
                Err(e) => {
                    crate::note!("error: {e}");
                    return ExitCode::FAILURE;
                }
            };
            // A table left by a program that died before it could read one (see `handoff`)
            // holds the screens of sessions that are gone.
            let _ = std::fs::remove_file(handoff::table_path(&socket));
            match serve::bind(&socket) {
                Ok(listener) => {
                    crate::note!("serving {} ({BUILD})", socket.display());
                    (lock, listener)
                }
                Err(e) => {
                    crate::note!("error: could not serve {}: {e}", socket.display());
                    return ExitCode::FAILURE;
                }
            }
        }
    };
    // A directory that cannot be used costs the records, never the daemon: a supervisor with a bad
    // path must still get terminals. The flag is in `arguments` below, so a hand-off keeps it.
    if let Some(dir) = screens {
        match crate::terminal::screens::Screens::open(&dir) {
            Ok(screens) => {
                daemon.sessions.keep_screens(screens);
                // Each workroom's layout (#255), on the same disk as the screens.
                let layouts = crate::host::layout::dir_beside(&dir);
                match crate::host::layout::Layouts::open(&layouts) {
                    Ok(layouts) => crate::host::layout::keep(layouts),
                    Err(e) => eprintln!(
                        "workroomd: not keeping layouts in {}: {e}",
                        layouts.display()
                    ),
                }
            }
            Err(e) => eprintln!(
                "workroomd: not keeping screens in {}: {e}",
                dir.to_string_lossy()
            ),
        }
    }
    // Every daemon, with screens or without: the same thread compresses every shadow's history
    // (#463). After `keep_screens`, so a daemon with screens writes them from its first tick.
    crate::terminal::screens::spawn(daemon.sessions.clone());
    // In both cases: the program handed off, or one that idled out or crashed, left its refusals
    // here, and an attach still on its way to it must not start a session it was told to end.
    daemon
        .sessions
        .keep_refusals(crate::terminal::session::refusals_path(&socket));
    daemon
        .sessions
        .keep_runs(crate::terminal::run::dir_beside(&socket));
    crate::terminal::run::spawn_watcher(daemon.sessions.clone());
    handoff::install(handoff::Context {
        socket: socket.clone(),
        listener: listener.as_raw_fd(),
        lock: lock.fd(),
        digest,
        arguments: std::env::args_os().skip(1).collect(),
    });
    // The lock this program holds, taken or carried over by a hand-off, and the log stderr is.
    daemon.keep_fresh(lock.fd(), libc::STDERR_FILENO, serve::FRESHEN_EVERY);
    match daemon.run(listener, &socket, timeout) {
        Ok(()) => {
            crate::note!("exiting: no session or client for {}s", timeout.as_secs());
            ExitCode::SUCCESS
        }
        Err(e) => {
            crate::note!("error: stopped serving {}: {e}", socket.display());
            ExitCode::FAILURE
        }
    }
}

/// Takes over what the program a hand-off replaced was holding: its lock, its listening socket
/// and its sessions (`crate::daemon::handoff`). A session that cannot be adopted is reported and
/// dropped, which closes its pty and hangs up its shell; the rest carry on.
fn adopt(
    daemon: &Daemon,
    table: &std::path::Path,
) -> Result<(serve::InstanceLock, UnixListener), String> {
    let table = handoff::take_table(table).map_err(|e| e.to_string())?;
    // SAFETY: the table names descriptors the outgoing program carried across the exec for this
    // and nothing else, and nothing in this process has touched them.
    let lock = unsafe { serve::InstanceLock::adopt(table.lock) };
    // SAFETY: as above; the listening socket is one of those descriptors.
    let listener = unsafe { UnixListener::from_raw_fd(table.listener) };
    wr_exec::set_cloexec(table.listener, true);
    // The same store of program status, so the app keeps what it knows (#358). A table from
    // before version 3 has none, and the fresh boot tells the app it starts over.
    if let Some(boot) = table.boot {
        daemon.sessions.program_status().set_boot(boot);
    }
    for session in table.sessions {
        let pty = crate::terminal::pty::Pty::adopt(session.master, session.pid);
        let id = session.id;
        if let Err(e) = daemon.sessions.adopt(pty, session) {
            crate::note!(
                "error: session {} could not be adopted, so its shell is hung up: {e}",
                id.to_hyphenated()
            );
        }
    }
    Ok((lock, listener))
}

/// `--idle-timeout`: seconds, or `never` for a supervised remote daemon (issue #228).
///
/// A value that does not parse is an error, not the default. A supervisor that asked for `never`
/// and got 30 seconds would see its daemon exit 30 seconds after the last client left, which looks
/// like a crash, and its detached sessions would die with it.
fn idle_timeout(value: Option<&str>) -> Result<Duration, String> {
    match value {
        None => Ok(DEFAULT_IDLE_TIMEOUT),
        // `serve` compares elapsed idle time with `>=`, and no elapsed time reaches this.
        Some("never") => Ok(Duration::MAX),
        Some(text) => text
            .parse::<u64>()
            .map(Duration::from_secs)
            .map_err(|_| format!("--idle-timeout takes seconds or `never`, not {text:?}")),
    }
}

#[cfg(test)]
mod tests;
