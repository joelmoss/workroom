//! Ending sessions: kills, the SIGHUP grace and the SIGKILL sweep.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use super::{Ending, Session, SessionId, SessionStore, TERMINATING};
use crate::terminal::pty::Pty;
use crate::util::{lock_or_recover, recover};

/// How long a session's processes get to exit on SIGHUP before `terminate` sends SIGKILL.
pub const SIGHUP_GRACE: Duration = Duration::from_millis(500);

/// How often `terminate` checks, within `SIGHUP_GRACE`, whether they have.
const SIGHUP_POLL: Duration = Duration::from_millis(10);

/// How long `serve --stdio` waits, as it exits, for kills still in flight: well past
/// `SIGHUP_GRACE`, and a shell stuck in the kernel is not waited out.
pub const KILL_EXIT_WAIT: Duration = SIGHUP_GRACE.saturating_mul(4);

impl Drop for Ending<'_> {
    fn drop(&mut self) {
        let (ending, ended) = &*self.store.ending;
        let mut ending = lock_or_recover(ending);
        for id in &self.ids {
            if let Some(count) = ending.get_mut(id) {
                *count -= 1;
                if *count == 0 {
                    ending.remove(id);
                }
            }
        }
        ended.notify_all();
    }
}

/// One kill counted in `SessionStore::is_killing`, given back when dropped: when its thread ends,
/// panics included, or when the thread could not be started and the closure holding it was dropped
/// unrun.
pub struct KillInFlight(Arc<AtomicUsize>);

impl Drop for KillInFlight {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
        crate::daemon::serve::wake_idle();
    }
}

impl SessionStore {
    /// Whether a kill is still running on a thread of its own. Its session has left the map before
    /// its shell is gone, so the idle-exit check and `serve --stdio`'s exit consult this as well
    /// as the map: either would otherwise end the process between the SIGHUP and the SIGKILL. A
    /// hand-off is kept out of that grace by `TERMINATING` instead, and waits on this only for the
    /// kill's acknowledgement, which an exec would lose.
    pub fn is_killing(&self) -> bool {
        self.kills_in_flight.load(Ordering::Acquire) > 0
    }

    /// Counts a kill in `is_killing` until the returned guard is dropped.
    pub fn kill_in_flight(&self) -> KillInFlight {
        self.kills_in_flight.fetch_add(1, Ordering::AcqRel);
        KillInFlight(Arc::clone(&self.kills_in_flight))
    }

    /// Marks `ids` as being ended. Called with the session map still locked, as they leave it, so
    /// a session is always in one or the other while its shell lives.
    pub(super) fn mark_ending(&self, ids: Vec<SessionId>) -> Ending<'_> {
        let (ending, _) = &*self.ending;
        let mut ending = lock_or_recover(ending);
        for id in &ids {
            *ending.entry(*id).or_default() += 1;
        }
        drop(ending);
        Ending { store: self, ids }
    }

    /// Whether `id` has left the map and its shell is still being ended.
    pub fn is_ending(&self, id: SessionId) -> bool {
        let (ending, _) = &*self.ending;
        lock_or_recover(ending).contains_key(&id)
    }

    /// Waits until no kill is in flight, or `deadline` passes: true if none is.
    pub fn wait_for_kills(&self, deadline: Instant) -> bool {
        while self.is_killing() {
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(SIGHUP_POLL);
        }
        true
    }

    /// Ends what is left of `id` when it is neither a live session nor one being ended, which is at
    /// most its screen record, and says so; false leaves it to `kill`, which has a shell to end or
    /// wait for. Decided in one look under the map's lock, where a session leaving it is marked as
    /// being ended, so a caller that must not wait on a shell (`serve`'s reader) never does.
    pub fn end_if_absent(&self, id: SessionId) -> bool {
        let _terminating = recover(TERMINATING.read());
        {
            let sessions = lock_or_recover(&self.sessions);
            if sessions.contains_key(&id) || self.is_ending(id) {
                return false;
            }
        }
        if let Some(screens) = self.screens.get() {
            screens.remove(id);
        }
        crate::daemon::serve::wake_idle();
        true
    }

    /// Ends a session and its pty. Returns whether there was one to end.
    ///
    /// The session leaves the map first and the killing happens with the lock released: a
    /// termination now scans the process table and waits out a shell's exit traps, and holding the
    /// store lock across that would stall every `list` and `attach` for the duration.
    pub fn kill(&self, id: SessionId) -> bool {
        let _terminating = recover(TERMINATING.read());
        let (session, _ending) = {
            let mut sessions = lock_or_recover(&self.sessions);
            let session = sessions.remove(&id);
            let ending = session.as_ref().map(|_| self.mark_ending(vec![id]));
            (session, ending)
        };
        // Killing is how the app says its user closed the pane, and that ends a record too: of a
        // session that ended with its host, or of this one. After the session leaves the map, so
        // the screens thread cannot take it as live and write the record back.
        if let Some(screens) = self.screens.get() {
            screens.remove(id);
        }
        match session {
            Some(session) => {
                crate::note!(
                    "session {} killed: hanging up shell pid {}",
                    id.to_hyphenated(),
                    session.pty.child_pid()
                );
                terminate(&[&session.pty]);
                // What a run left outside its supervisor's tree: see `sweep_run_session`.
                if crate::terminal::run::is_run(&session.metadata) {
                    self.runs_wake.raise(); // its status file goes on the watcher's next pass
                    sweep_run_session(id, session.pty.child_pid());
                }
                true
            }
            None => {
                // Another kill took it out of the map first and may still be ending its shell.
                // Returning now would have this kill acknowledged while the shell lives (#283).
                let (ending, ended) = &*self.ending;
                let ending = lock_or_recover(ending);
                drop(recover(
                    ended.wait_while(ending, |ending| ending.contains_key(&id)),
                ));
                false
            }
        }
    }

    /// One sweep for every session rather than a loop of single kills, so the process-table scan
    /// happens once and every shell gets its hangup at the same moment instead of each waiting out
    /// the one before it. That matters on quit, where this runs with the user watching.
    pub fn kill_all(&self) -> usize {
        let _terminating = recover(TERMINATING.read());
        let (ending, _ending) = {
            let mut sessions = lock_or_recover(&self.sessions);
            let ending: Vec<Session> = sessions.drain().map(|(_, session)| session).collect();
            let marked = self.mark_ending(ending.iter().map(|s| s.id).collect());
            (ending, marked)
        };
        if let Some(screens) = self.screens.get() {
            screens.remove_all();
        }
        crate::daemon::serve::wake_idle();
        if !ending.is_empty() {
            let ids: Vec<String> = ending.iter().map(|s| s.id.to_hyphenated()).collect();
            crate::note!("killing all {} sessions: {}", ids.len(), ids.join(", "));
        }
        let ptys: Vec<&Arc<Pty>> = ending.iter().map(|session| &session.pty).collect();
        terminate(&ptys);
        let mut runs = false;
        for session in ending
            .iter()
            .filter(|s| crate::terminal::run::is_run(&s.metadata))
        {
            runs = true;
            sweep_run_session(session.id, session.pty.child_pid());
        }
        if runs {
            self.runs_wake.raise(); // their status files go on the watcher's next pass
        }
        ending.len()
    }
}

/// How long what a run left behind gets to exit on SIGTERM before `sweep_run_session` sends SIGKILL.
const RUN_SWEEP_GRACE: Duration = Duration::from_secs(2);

/// Ends whatever a run session left running when its supervisor exited (#522, R8): a server its
/// launcher forked into a process group of its own, which the supervisor's group-wide Ctrl-C never
/// reached and its exit then orphaned. Everything still in the session that `sid` led gets SIGTERM,
/// then SIGKILL after `RUN_SWEEP_GRACE`. On a thread of its own, so the reader's end is not held up.
pub(super) fn sweep_run_session(id: SessionId, sid: i32) {
    let spawned = std::thread::Builder::new()
        .name("run-sweep".into())
        .spawn(move || {
            let members = wr_exec::session_members(sid);
            if members.is_empty() {
                return;
            }
            crate::note!(
                "run session {} left {} process(es) running; ending them",
                id.to_hyphenated(),
                members.len()
            );
            for member in &members {
                // SAFETY: `kill` takes no pointers; each pid was read just above.
                unsafe { libc::kill(member.pid, libc::SIGTERM) };
            }
            let deadline = Instant::now() + RUN_SWEEP_GRACE;
            while Instant::now() < deadline && members.iter().any(|m| m.is_running()) {
                std::thread::sleep(Duration::from_millis(50));
            }
            for member in members.iter().filter(|m| m.is_running()) {
                // SAFETY: as above; `is_running` compared start times, so a reused pid is skipped.
                unsafe { libc::kill(member.pid, libc::SIGKILL) };
            }
        });
    if let Err(e) = spawned {
        crate::note!("could not sweep run session {}: {e}", id.to_hyphenated());
    }
}

/// Ends these ptys' shells and everything they started.
///
/// SIGHUP first, which is what a terminal closing means and what a shell expects; SIGKILL only for
/// whatever is still there afterwards. Sending SIGKILL outright would deny a shell the chance to
/// run its exit traps.
///
/// Signalling the shell alone is not enough, and that is the whole reason this takes a descendant
/// snapshot. Killing the shell hangs up the pty, and the kernel delivers SIGHUP to the pty's
/// foreground process group — but a child that called `setsid()` is in neither that group nor the
/// shell's session, so nothing reaches it and it survives the app quitting. See
/// `wr_exec::descendants`.
///
/// Its own sequence, not `wr_exec::end_tree`'s: that signals the group a spawned child leads, and
/// here there are many roots, each a session leader whose hangup goes to every recorded pid in turn,
/// the grace ends as soon as everything is gone, and the roots are reaped with `waitpid`.
///
/// **The snapshot must be taken before anything is signalled.** Once the shell is hung up its
/// children start exiting, and a descendant that has already left the process table is one no
/// later sweep can find — it would be missed precisely in the common case where it exits slowly
/// enough to matter.
pub(super) fn terminate(ptys: &[&Arc<Pty>]) {
    let roots: Vec<i32> = ptys
        .iter()
        .map(|pty| pty.child_pid())
        .filter(|pid| *pid > 0)
        .collect();
    if roots.is_empty() {
        return;
    }
    // Each descendant is recorded with its start time, not just its pid, because the SIGKILL
    // sweep below happens up to `SIGHUP_GRACE` later — long enough for one to exit and its number
    // to be reused. See `wr_exec::Descendant`.
    let descendants = wr_exec::descendants(&roots);

    for pid in roots.iter().chain(descendants.iter().map(|d| &d.pid)) {
        // SAFETY: `kill` takes no pointers. The descendants were read just above, so a reused pid
        // is limited to that short window.
        unsafe { libc::kill(*pid, libc::SIGHUP) };
    }

    // Only the roots are our children, so only they can be reaped; a descendant's exit is observed
    // by probing instead. Both are checked, because the point is that nothing is left.
    let mut unreaped: Vec<i32> = roots.clone();
    for _ in 0..(SIGHUP_GRACE.as_millis() / SIGHUP_POLL.as_millis()) {
        unreaped.retain(|pid| {
            let mut status = 0;
            // SAFETY: `status` is a live local; the roots are this process's own children.
            let rc = unsafe { libc::waitpid(*pid, &mut status, libc::WNOHANG) };
            rc == 0
        });
        if unreaped.is_empty() && !descendants.iter().any(|d| d.is_running()) {
            return;
        }
        std::thread::sleep(SIGHUP_POLL);
    }

    // `SIGHUP_GRACE` of SIGHUP was declined. Anything still running gets SIGKILL — and `is_running`
    // is checked first, and compares start times, so a descendant that has exited cannot cost an
    // unrelated process that inherited its pid a SIGKILL.
    let survivors = descendants
        .iter()
        .filter(|d| d.is_running())
        .map(|d| &d.pid);
    let killing: Vec<i32> = unreaped.iter().chain(survivors).copied().collect();
    if !killing.is_empty() {
        crate::note!("SIGHUP declined for {SIGHUP_GRACE:?}; SIGKILL to pids {killing:?}");
    }
    for pid in &killing {
        // SAFETY: `kill` takes no pointers; `is_running` filtered out reused descendant pids, and
        // the unreaped roots are our own children, so their pids cannot have been reused.
        unsafe { libc::kill(*pid, libc::SIGKILL) };
    }
    for pid in &unreaped {
        let mut status = 0;
        // SAFETY: `status` is a live local, and each pid is an unreaped child just sent SIGKILL.
        unsafe { libc::waitpid(*pid, &mut status, 0) };
    }
}
