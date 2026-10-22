//! `workroomd serve`: the daemon itself, on a socket or on stdin/stdout.
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use crate::handoff;
use crate::serve::{self, BUILD, DEFAULT_IDLE_TIMEOUT, Daemon};

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
    let sessions = crate::session::SessionStore::new();
    let result =
        crate::serve::handle_connection(crate::transport::StdioTransport, sessions.clone());
    // Nothing else can reach these sessions: the stream was their only route in.
    sessions.kill_all();
    // A kill still on its own thread took its session out of the store before `kill_all` looked,
    // and exiting now would cut it off between its SIGHUP and its SIGKILL. Waited for after
    // `kill_all`, so no other session's SIGHUP waits on it.
    sessions.wait_for_kills(std::time::Instant::now() + crate::session::KILL_EXIT_WAIT);
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

pub fn run_serve(
    socket: PathBuf,
    idle: Option<String>,
    handoff: Option<PathBuf>,
    screens: Option<PathBuf>,
) -> ExitCode {
    let timeout = match idle_timeout(idle.as_deref()) {
        Ok(timeout) => timeout,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    // Before anything can fail, so every line below and every session's end has somewhere to go.
    crate::log::redirect_stderr(&socket);
    // First, before an update can replace the file at this path: see `handoff::Context::digest`.
    let digest = handoff::own_binary()
        .and_then(|path| handoff::digest(&path))
        .ok();
    let daemon = Daemon::new();
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
                Err(serve::ServeError::AlreadyRunning(_)) => return ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("error: {e}");
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
        match crate::screens::Screens::open(&dir) {
            Ok(screens) => {
                daemon.sessions.keep_screens(screens);
                // Each workroom's layout (#255), on the same disk as the screens.
                let layouts = crate::layout::dir_beside(&dir);
                match crate::layout::Layouts::open(&layouts) {
                    Ok(layouts) => crate::layout::keep(layouts),
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
    crate::screens::spawn(daemon.sessions.clone());
    // In both cases: the program handed off, or one that idled out or crashed, left its refusals
    // here, and an attach still on its way to it must not start a session it was told to end.
    daemon
        .sessions
        .keep_refusals(crate::session::refusals_path(&socket));
    handoff::install(handoff::Context {
        socket: socket.clone(),
        listener: listener.as_raw_fd(),
        lock: lock.fd(),
        digest,
        arguments: std::env::args_os().skip(1).collect(),
    });
    match daemon.run(listener, &socket, timeout) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Takes over what the program a hand-off replaced was holding: its lock, its listening socket
/// and its sessions (`crate::handoff`). A session that cannot be adopted is reported and
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
    crate::pty::set_cloexec(table.listener, true);
    // The same store of program status, so the app keeps what it knows (#358). A table from
    // before version 3 has none, and the fresh boot tells the app it starts over.
    if let Some(boot) = table.boot {
        daemon.sessions.program_status().set_boot(boot);
    }
    for session in table.sessions {
        let pty = crate::pty::Pty::adopt(session.master, session.pid);
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
mod tests {
    use super::*;

    #[test]
    fn idle_timeout_takes_seconds_or_never_and_rejects_anything_else() {
        assert_eq!(idle_timeout(None), Ok(DEFAULT_IDLE_TIMEOUT));
        assert_eq!(idle_timeout(Some("60")), Ok(Duration::from_secs(60)));
        assert_eq!(idle_timeout(Some("never")), Ok(Duration::MAX));
        for bad in ["", "-1", "1.5", "Never", "forever"] {
            assert!(idle_timeout(Some(bad)).is_err(), "{bad:?}");
        }
    }
}
