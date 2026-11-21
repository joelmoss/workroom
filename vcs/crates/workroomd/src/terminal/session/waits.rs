//! The terminal API's waits on a session (#690): starting one, and telling them what happened. The
//! waiter and what it waits for are `crate::terminal::wait`'s.

use std::sync::{Arc, Mutex};

use super::{Attached, SessionId, SessionStore};
use crate::terminal::shadow::Shadow;
use crate::terminal::wait::Waiter;
use crate::util::lock_or_recover;

/// A session's waiters, in its attachment state.
#[derive(Default)]
pub(super) struct Waiters {
    list: Vec<Arc<Waiter>>,
    /// Set as the session's reader ends, with its shell's exit code when it saw it: a wait that
    /// starts after that, on the session as it was looked up a moment before, ends at once.
    ended: Option<Option<i32>>,
}

impl Waiters {
    /// Whether any wait is listening: the one question a read asks when none is.
    pub(super) fn is_empty(&self) -> bool {
        self.list.is_empty()
    }

    pub(super) fn list(&self) -> Vec<Arc<Waiter>> {
        self.list.clone()
    }
}

impl SessionStore {
    /// Starts a wait on `id`. `make` builds the waiter from the session's shadow as it stands, and
    /// the waits the session holds (so it can refuse one past a limit, or beside another), under
    /// the session's attachment and shadow locks, which every read holds: the waiter hears every
    /// byte read after it is made and none before. `None` when there is no session `id`.
    pub fn add_waiter<E>(
        &self,
        id: SessionId,
        make: impl FnOnce(&mut Shadow, &[Arc<Waiter>]) -> Result<Arc<Waiter>, E>,
    ) -> Option<Result<Arc<Waiter>, E>> {
        let (_, shadow, attached) = self.parts(id)?;
        let mut held = lock_or_recover(&attached);
        let made = make(&mut lock_or_recover(&shadow), &held.waiters.list);
        if let Ok(waiter) = &made {
            match held.waiters.ended {
                Some(exit_code) => waiter.ended(exit_code),
                None if waiter.outcome().is_none() => held.waiters.list.push(Arc::clone(waiter)),
                None => {}
            }
        }
        Some(made)
    }

    /// Ends `waiter`'s hold on `id`, however its wait ended.
    pub fn remove_waiter(&self, id: SessionId, waiter: &Arc<Waiter>) {
        if let Some((_, _, attached)) = self.parts(id) {
            lock_or_recover(&attached)
                .waiters
                .list
                .retain(|held| !Arc::ptr_eq(held, waiter));
        }
    }

    /// How many waits `id` holds.
    #[cfg(test)]
    pub fn waiter_count(&self, id: SessionId) -> usize {
        self.parts(id).map_or(0, |(_, _, attached)| {
            lock_or_recover(&attached).waiters.list.len()
        })
    }

    /// A run session's supervisor wrote `line` (the runs watcher, `crate::terminal::run`): its
    /// `seq`th transition, from its log, or with none, from its status file.
    pub fn run_changed(&self, id: SessionId, line: &str, seq: Option<u64>) {
        let Some((_, _, attached)) = self.parts(id) else {
            return;
        };
        // The terminal API's events too, which tell a logged run's transitions from its log alone.
        self.hooks().events.run(id, line, seq);
        let waiters = lock_or_recover(&attached).waiters.list();
        for waiter in waiters {
            waiter.run(line, seq);
        }
    }

    /// The session's program status changed other than by a read (`update_program_status`): its
    /// waiters see the shadow as it is now.
    pub(super) fn program_status_changed(&self, id: SessionId) {
        let Some((_, shadow, attached)) = self.parts(id) else {
            return;
        };
        let (waiters, seen) = {
            let held = lock_or_recover(&attached);
            if held.waiters.is_empty() {
                return;
            }
            (held.waiters.list(), lock_or_recover(&shadow).seen())
        };
        for waiter in waiters {
            waiter.shadow(&seen);
        }
    }
}

/// The session's reader is ending: each waiter is told, with the shell's exit code when it saw it,
/// and no wait starts on the session after this. With the session's locks released.
pub(super) fn end(attached: &Mutex<Attached>, exit_code: Option<i32>) {
    let waiters = {
        let mut held = lock_or_recover(attached);
        held.waiters.ended = Some(exit_code);
        std::mem::take(&mut held.waiters.list)
    };
    for waiter in waiters {
        waiter.ended(exit_code);
    }
}
