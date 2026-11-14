//! The one surface through which the store tells what observes its sessions about each point in a
//! session's life: kept screens (`crate::terminal::screens`), run sessions (`crate::terminal::run`)
//! and program status (`crate::terminal::program_status`). Each observer's state is its own; the
//! store holds them only here, and calls them only through the methods below.

use std::sync::{Arc, Mutex};

use super::SessionId;
use crate::terminal::program_status::{Hub, Store};
use crate::terminal::run::Runs;
use crate::terminal::screens::KeptScreens;
use crate::terminal::shadow::Shadow;
use crate::util::lock_or_recover;

/// What observes a store's sessions.
///
/// **Every hook is a direct call, on the thread that reached that point, never a queue or a
/// channel.** Output and a session's end are reached on the session's reader, which is the only
/// thread that knows where a client's stream stands: the shadow leads the client by one read, and a
/// pty read can end mid-CSI, mid-UTF-8 or inside a string, so anything put into a client's stream
/// between reads must wait for the parser's ground (learning `pty-reads-split-sequences`). An
/// observer that queued its work would act on a stream position it cannot see. The others are
/// reached on a connection's thread (create, attach, resize, signal, kill) or a kill's own thread,
/// and none of them writes to a client's stream.
#[derive(Default)]
pub struct Hooks {
    pub screens: KeptScreens,
    pub runs: Runs,
    /// Publishes each session's program status to subscribed connections (#358). Its boot names
    /// the store.
    pub program_status: Arc<Hub>,
    /// What a remote pane's session attached from the Mac is built from (ADR 0074).
    pub host: crate::terminal::host_session::HostSource,
}

impl Hooks {
    /// A new session is about to take `id`, under the store's lock: it supersedes whatever record
    /// its id had, or a shell that exits before its first record would leave the old one to be
    /// shown as its last screen. Whether there was one; the directory is synced in `created`.
    pub(super) fn creating(&self, id: SessionId) -> bool {
        self.screens
            .get()
            .is_some_and(|screens| screens.remove_unsynced(id))
    }

    /// The new session is in the store and the store's lock is released. `superseded` is what
    /// `creating` said.
    pub(super) fn created(&self, run: bool, superseded: bool) {
        if run {
            self.runs.raise();
        }
        if superseded && let Some(screens) = self.screens.get() {
            let _ = screens.sync();
        }
    }

    /// A session's screen may have changed, or its record is still owed: output, a resize, a
    /// repaint that re-inflated its history, `mark_changed`, or a record left for the next pass.
    pub(super) fn screen_changed(&self) {
        self.screens.raise();
    }

    /// A run session's supervisor was signalled, so it is about to write a new status; the runs
    /// watcher may be asleep on a finished one.
    pub(super) fn run_signalled(&self) {
        self.runs.raise();
    }

    /// The reader removed its session from the store, under `TERMINATING`: its record goes on the
    /// screens thread's next pass, and a run's status file on the runs watcher's.
    pub(super) fn ended(&self, run: bool) {
        self.screens.raise();
        if run {
            self.runs.raise();
        }
    }

    /// A client killed `id`, after it left the store: killing is how the app says its user closed
    /// the pane, and that ends its record too.
    pub(super) fn killed(&self, id: SessionId) {
        if let Some(screens) = self.screens.get() {
            screens.remove(id);
        }
    }

    /// A client killed every session, after they left the store.
    pub(super) fn killed_all(&self) {
        if let Some(screens) = self.screens.get() {
            screens.remove_all();
        }
    }

    /// A killed run session's shell is gone: its status file goes on the runs watcher's next pass.
    pub(super) fn run_killed(&self) {
        self.runs.raise();
    }

    /// The boot a status event names, for an event built under a session's shadow lock.
    pub(super) fn boot(&self) -> SessionId {
        self.program_status.boot()
    }

    /// A read changed `id`'s program status: published, with every session lock released.
    pub(super) fn status_changed(&self, id: SessionId, event: Vec<u8>, blocked: bool) {
        self.program_status.publish(id, event, blocked);
    }

    /// A program status probe's answer did not fit the pty's input queue.
    pub(super) fn reply_dropped(&self) {
        self.program_status.reply_dropped();
    }

    /// Applies `change` to the session's program status under its shadow lock, and publishes the
    /// result, with the lock released, if it changed anything.
    pub(super) fn change_program_status(
        &self,
        id: SessionId,
        shadow: &Mutex<Shadow>,
        change: impl FnOnce(&mut Store),
    ) {
        let published = {
            let mut shadow = lock_or_recover(shadow);
            shadow.status().and_then(|status| {
                change(status);
                let blocked = status.commit()?;
                Some((status.event(self.boot(), id), blocked))
            })
        };
        if let Some((event, blocked)) = published {
            self.status_changed(id, event, blocked);
        }
    }

    /// The session's program has exited: its running records go, and every subscriber is told so,
    /// then that the session has ended.
    pub(super) fn program_ended(&self, id: SessionId, shadow: &Mutex<Shadow>) {
        self.change_program_status(id, shadow, Store::drop_on_exit);
        self.program_status.ended(id);
    }
}
