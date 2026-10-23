//! Run sessions (#522): a project's run command in a daemon session of its own, so it survives the
//! app quitting and runs the same way on this Mac and on a host.
//!
//! A run session's pty runs `workroomd run-supervisor` (`cli::run_supervisor`), which writes the
//! run's state to a status file the daemon names by session id, beside its socket, so a hand-off
//! needs to carry nothing to find it again. The daemon reads that file and publishes it with the
//! session's program status, so an app sees how a run ended even when it was closed at the time.
use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::session::{SessionId, SessionStore};

/// How often the watcher reads each run session's status file: the app polled it this often when
/// it read the file itself, and a stop or a crash should show at once. A run's file is one short
/// line, and a Mac or a host runs a handful.
const POLL: Duration = Duration::from_millis(150);

/// How long the watcher keeps polling after a wake with every run finished: the status a create or
/// a signal leads to is written within a moment, but not before the wake.
const WAKE_GRACE: Duration = Duration::from_secs(5);

/// Set in the attach environment, to `1`, for a session that is a run command rather than a
/// shell. One of the session's own variables, so its shell never sees it.
pub const REQUEST_VARIABLE: &str = "WORKROOM_SESSION_RUN";

/// The metadata a run session is listed with, so any app can tell a workroom's run from its
/// shells (#522, D7).
pub const KIND_KEY: &str = "kind";
pub const RUN_KIND: &str = "run";

/// Where a socket's run sessions keep their status files, in the daemon's own directory.
pub fn dir_beside(socket: &Path) -> PathBuf {
    socket.with_extension("runs")
}

/// The status file of run session `id` in `dir`.
pub fn status_file(dir: &Path, id: SessionId) -> PathBuf {
    dir.join(format!("{}.status", id.to_hyphenated()))
}

/// Whether an attach environment asks for a run session.
pub fn is_requested(env: &[(OsString, OsString)]) -> bool {
    env.iter()
        .any(|(key, value)| key == REQUEST_VARIABLE && value == "1")
}

/// Whether a session's metadata says it is a run session.
pub fn is_run(metadata: &[(String, String)]) -> bool {
    metadata
        .iter()
        .any(|(key, value)| key == KIND_KEY && value == RUN_KIND)
}

/// Publishes each run session's status as its supervisor writes it, and removes a status file once
/// its session has gone. A store that keeps no run sessions starts nothing.
pub fn spawn_watcher(sessions: SessionStore) {
    let Some(dir) = sessions.runs_dir().map(Path::to_path_buf) else {
        return;
    };
    // Before the first tick, after any hand-off adopted its sessions: a file whose session is not
    // here was left by a daemon that died or a host that rebooted, and must never be read as a run's.
    remove_stale(&dir, &sessions.run_session_ids());
    let spawned = std::thread::Builder::new()
        .name("runs".into())
        .spawn(move || {
            let mut published = HashMap::new();
            // Polled until here whatever the statuses say: a run just created or signalled has a
            // new status on its way that the file does not show yet.
            let mut poll_until = Instant::now();
            loop {
                // Counted before the tick looks, so a run created or signalled between the look
                // and the wait still wakes it.
                let seen = sessions.runs_wake();
                let running = tick(&sessions, &dir, &mut published);
                if running || Instant::now() < poll_until {
                    std::thread::sleep(POLL);
                } else {
                    // Every run has finished, or there is none: sleep until one is created or
                    // signalled, rather than read finished runs' files seven times a second (an
                    // idle daemon's whole cost with a stopped run tab open, 2026-10-23).
                    sessions.wait_for_runs_wake(seen);
                    poll_until = Instant::now() + WAKE_GRACE;
                }
            }
        });
    if let Err(e) = spawned {
        eprintln!("workroomd: run sessions' state will not be published: no thread for it: {e}");
    }
}

/// One pass: each live run's status, published when it changed, and the files of runs that ended.
/// Whether any live run is still running, or has no status yet, so the next pass is owed soon.
fn tick(sessions: &SessionStore, dir: &Path, published: &mut HashMap<SessionId, String>) -> bool {
    let live = sessions.run_session_ids();
    for &id in &live {
        let Ok(raw) = std::fs::read_to_string(status_file(dir, id)) else {
            continue;
        };
        let line = raw.trim();
        if line.is_empty() || published.get(&id).map(String::as_str) == Some(line) {
            continue;
        }
        let line = line.to_string();
        if sessions.update_program_status(id, |status| status.set_run(line.clone())) {
            published.insert(id, line);
        }
    }
    published.retain(|id, _| {
        let alive = live.contains(id);
        if !alive {
            let _ = std::fs::remove_file(status_file(dir, *id));
        }
        alive
    });
    live.iter()
        .any(|id| published.get(id).is_none_or(|status| still_running(status)))
}

/// Whether a supervisor's status line can still change on its own: `running <pid>` or
/// `restarting …` can, `exited …` and `stopped …` only after a signal (`run_supervisor.sh`).
fn still_running(status: &str) -> bool {
    !matches!(
        status.split_whitespace().next(),
        Some("exited") | Some("stopped")
    )
}

/// Removes every status file in `dir`, and every temporary one its supervisor left, whose session
/// is not in `live`.
fn remove_stale(dir: &Path, live: &[SessionId]) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let kept: Vec<String> = live
        .iter()
        .map(|id| format!("{}.status", id.to_hyphenated()))
        .collect();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !kept.contains(&name) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::still_running;

    /// The watcher polls a run whose status can still change on its own and sleeps on one that
    /// only a signal moves; a run without a status yet is polled.
    #[test]
    fn a_finished_run_is_not_polled_and_a_running_one_is() {
        assert!(still_running("running 11853"));
        assert!(still_running("restarting 2"));
        assert!(still_running(""));
        assert!(!still_running("exited 0 3"));
        assert!(!still_running("exited 130 1"));
        assert!(!still_running("stopped 1"));
    }
}
