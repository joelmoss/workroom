//! The session map's lifecycle: creating sessions, and what the screens thread, the runs watcher
//! and program status read of them.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::reader::read_session;
use super::refusals::wall_now;
use super::{
    Attached, CREATED_KEY, ClientInfo, Described, Foreground, Hooks, NEXT_SESSION, RunSignalError,
    Session, SessionError, SessionId, SessionInfo, SessionParts, SessionSpec, SessionStore,
    TakenScreen, until,
};
use crate::terminal::program_status::Store;
use crate::terminal::pty::Pty;
use crate::terminal::shadow::Shadow;
use crate::util::{lock_or_recover, try_recover};

impl SessionStore {
    /// What observes this store's sessions: its kept screens, run sessions and program status.
    pub fn hooks(&self) -> &Hooks {
        &self.hooks
    }

    /// Builds host-environment sessions from `origin`, not this process's environment and account,
    /// so a test never starts the developer's own shell in their own home.
    #[cfg(any(test, feature = "test-support"))]
    pub fn set_host_origin(&self, origin: crate::terminal::host_session::HostOrigin) {
        self.hooks.host.fix(origin);
    }

    /// Looks for Ghostty's resources in `dir` for host-environment sessions, as a daemon serving a
    /// socket does beside it.
    #[cfg(any(test, feature = "test-support"))]
    pub fn keep_host_resources(&self, dir: std::path::PathBuf) {
        self.hooks.host.keep_resources(dir);
    }

    /// Serves `socket` from now on: the path each new session's shell is given as
    /// `WORKROOM_DAEMON`. Once per store.
    pub fn serve_socket(&self, socket: std::path::PathBuf) {
        let _ = self.socket.set(socket);
    }

    /// The socket this store's daemon serves, if it serves one.
    pub fn socket(&self) -> Option<&std::path::Path> {
        self.socket.get().map(std::path::PathBuf::as_path)
    }

    /// The session whose pty child (its shell, or a run's supervisor) is `pid` or one of its
    /// ancestors, nearest first (#684): what a process in a pane is known by, whatever pane its
    /// variables name.
    pub fn session_of_process(&self, pid: i32) -> Option<SessionId> {
        let shells: std::collections::HashMap<i32, SessionId> = lock_or_recover(&self.sessions)
            .values()
            .map(|session| (session.pty.child_pid(), session.id))
            .collect();
        wr_exec::ancestry(pid)
            .into_iter()
            .find_map(|pid| shells.get(&pid).copied())
    }

    /// Keeps what `id`'s shell was built from (#693), forgetting every session's that has ended.
    pub fn remember_recipe(&self, id: SessionId, recipe: super::Recipe) {
        let live: std::collections::HashSet<SessionId> =
            lock_or_recover(&self.sessions).keys().copied().collect();
        let mut recipes = lock_or_recover(&self.recipes);
        recipes.retain(|kept, _| live.contains(kept));
        if live.contains(&id) {
            recipes.insert(id, Arc::new(recipe));
        }
    }

    /// What `id`'s shell was built from, when this program created it and it is live.
    pub fn recipe(&self, id: SessionId) -> Option<Arc<super::Recipe>> {
        if !self.contains(id) {
            return None;
        }
        lock_or_recover(&self.recipes).get(&id).cloned()
    }

    /// The live run sessions.
    pub fn run_session_ids(&self) -> Vec<SessionId> {
        lock_or_recover(&self.sessions)
            .values()
            .filter(|session| crate::terminal::run::is_run(&session.metadata))
            .map(|session| session.id)
            .collect()
    }

    /// Sends a run session's supervisor `signal` (#522): it serializes its command's stop and start
    /// itself. Only to a run session, whose pty child is the supervisor; a shell is never sent one.
    pub fn signal_run(
        &self,
        id: SessionId,
        signal: wr_protocol::frame::RunSignal,
    ) -> Result<(), RunSignalError> {
        use wr_protocol::frame::RunSignal;
        let sessions = lock_or_recover(&self.sessions);
        let session = sessions.get(&id).ok_or(RunSignalError::NotFound)?;
        if !crate::terminal::run::is_run(&session.metadata) {
            return Err(RunSignalError::NotARun);
        }
        let number = match signal {
            RunSignal::Restart => libc::SIGUSR1,
            RunSignal::Stop => libc::SIGUSR2,
            RunSignal::Quit => libc::SIGTERM,
        };
        // Accepted limit: the reader reaps the child a moment before it takes this lock to remove the
        // session, so in that window the pid is free. Reusing it needs another process started in
        // those microseconds, while a client signals a run that has just ended.
        // SAFETY: `kill` takes no pointers.
        if unsafe { libc::kill(session.pty.child_pid(), number) } != 0 {
            return Err(RunSignalError::Failed(std::io::Error::last_os_error()));
        }
        self.hooks.run_signalled();
        Ok(())
    }

    /// Re-tags a live session with another workroom: replaces its `workroom` metadata (or adds it)
    /// and leaves every other key alone. The list and a hand-off both read `Session::metadata`, so
    /// the new tag shows in the next of either. `false` when there is no such session.
    pub fn set_workroom(&self, id: SessionId, workroom: &str) -> bool {
        let mut sessions = lock_or_recover(&self.sessions);
        let Some(session) = sessions.get_mut(&id) else {
            return false;
        };
        match session
            .metadata
            .iter_mut()
            .find(|(key, _)| key == "workroom")
        {
            Some((_, value)) => *value = workroom.to_string(),
            None => session
                .metadata
                .push(("workroom".to_string(), workroom.to_string())),
        }
        drop(sessions);
        // Its events from here on carry the new scope, and its filters keep to it.
        self.hooks
            .events
            .rescoped(id, serde_json::json!({"kind": "workroom", "id": workroom}));
        true
    }

    /// Names a live session `label`, its tab's name in the app (#694): replaces its `title`
    /// metadata, or removes it for `None`, and leaves every other key alone. The list and a
    /// hand-off both read `Session::metadata`, so the name shows in the next of either. Its
    /// `session.labelled` is told under the store's lock, so of two names set at once the last
    /// told is the one kept. `None` when there is no such session; else whether the name changed,
    /// since setting the one it has tells nothing.
    pub fn set_label(&self, id: SessionId, label: Option<&str>) -> Option<bool> {
        let mut sessions = lock_or_recover(&self.sessions);
        let session = sessions.get_mut(&id)?;
        let at = session.metadata.iter().position(|(key, _)| key == "title");
        let current = at.map(|at| session.metadata[at].1.as_str());
        if current == label {
            return Some(false);
        }
        match (at, label) {
            (Some(at), Some(label)) => session.metadata[at].1 = label.to_string(),
            (None, Some(label)) => session
                .metadata
                .push(("title".to_string(), label.to_string())),
            (Some(at), None) => {
                session.metadata.remove(at);
            }
            (None, None) => {}
        }
        self.hooks.events.labelled(id, label);
        Some(true)
    }

    pub fn new() -> Self {
        Self::default()
    }

    /// Creates a session, or fails if the id is taken.
    ///
    /// Taking the lock across the spawn is deliberate: two clients racing to create the same id
    /// must not both fork a shell, and the window is a single `forkpty`.
    #[cfg(any(test, feature = "test-support"))]
    pub fn create(&self, spec: SessionSpec<'_>) -> Result<SessionInfo, SessionError> {
        self.create_then(spec, Ok)
    }

    /// Registers the initial client before the reader can drain and retire a short-lived command.
    /// The callback runs without the store lock. Even if it fails, start draining the session so a
    /// failed handshake cannot block the child on a full pty and strand an entry that would
    /// otherwise retire. A session that survives a failed handshake is not stranded: it is the same
    /// detached state a crashed client leaves, reattachable by the id the client persists, and
    /// visible to `list` and `kill`.
    pub(crate) fn create_then<T>(
        &self,
        spec: SessionSpec<'_>,
        register: impl FnOnce(SessionInfo) -> Result<T, SessionError>,
    ) -> Result<T, SessionError> {
        let mut sessions = lock_or_recover(&self.sessions);
        if sessions.contains_key(&spec.id) {
            return Err(SessionError::AlreadyExists(spec.id.to_hyphenated()));
        }
        if self.is_refused(spec.id) {
            return Err(SessionError::Ended(spec.id.to_hyphenated()));
        }
        // Resolve the size ONCE, here, and hand the same numbers to both the pty and the shadow.
        //
        // Zero means "the client has no size yet" — a relay forked into a pipe rather than a
        // terminal reports it, and so does an attach that arrives before the surface is laid out.
        // `Pty::spawn` substitutes 80x24 for it; the shadow, clamping independently, ended up 1x1,
        // and a 1-column emulator wraps every character onto its own line. The repaint that came
        // back was one letter per row. Two components applying their own fallback to the same
        // input is the bug, so there is now one fallback.
        let columns = if spec.columns == 0 {
            crate::terminal::pty::DEFAULT_COLUMNS
        } else {
            spec.columns
        };
        let rows = if spec.rows == 0 {
            crate::terminal::pty::DEFAULT_ROWS
        } else {
            spec.rows
        };

        let pty = Pty::spawn(
            spec.program,
            spec.argv0,
            spec.args,
            spec.env,
            spec.cwd,
            columns,
            rows,
        )?;
        // Only once the session exists, so a create that loses a race or fails to spawn leaves
        // its id's record alone, and before it enters the map, so the screens thread cannot write
        // its record first and have it removed here. The directory is synced after the store lock
        // is released (`Hooks::created`), so no other session waits on the disk.
        let superseded = self.hooks.creating(spec.id);
        let mut metadata = spec.metadata.to_vec();
        metadata.push((CREATED_KEY.to_string(), wall_now().as_millis().to_string()));
        let is_run = crate::terminal::run::is_run(&metadata);
        // Its resume state, for the token `dispatch` gave its shell (ADR 0082).
        let resume = spec
            .interactive
            .then(|| crate::terminal::resume::Resume::for_session(spec.env))
            .flatten()
            .map(|mut resume| {
                resume.set_root(pty.child_pid());
                resume
            });
        let session = Session {
            resume: Arc::new(Mutex::new(resume)),
            id: spec.id,
            pty: Arc::new(pty),
            shadow: Arc::new(Mutex::new(Shadow::new(columns, rows))),
            attached: Arc::new(Mutex::new(Attached::unrecorded())),
            number: NEXT_SESSION.fetch_add(1, Ordering::Relaxed),
            metadata,
            interactive: spec.interactive,
        };
        let info = session.info();
        let number = session.number;
        let pty = Arc::clone(&session.pty);
        let shadow = Arc::clone(&session.shadow);
        let attached = Arc::clone(&session.attached);
        let store = self.clone();
        sessions.insert(spec.id, session);
        self.hooks.announce(info.clone());
        // Drop the store lock before the reader starts, or its first `ended` removal deadlocks
        // against this very lock.
        drop(sessions);
        crate::note!(
            "session {} started: shell pid {}",
            spec.id.to_hyphenated(),
            pty.child_pid()
        );
        self.hooks.created(is_run, superseded);
        // `std::thread::spawn` panics when the OS cannot create a thread. Reachable here on the
        // connection's own dispatch thread (this runs inside `handle_connection`), so the panic
        // would unwind past `Server::serve`'s `connections.fetch_sub` exactly as an unhandled
        // `forward.rs` spawn failure does — and leave this session in the map forever with a real
        // forked pty and nothing left to ever drain, notice it exit, or let `read_session`'s `ended`
        // cleanup remove it. `Builder::spawn` turns that into an `Err`; retire the session the same
        // way `kill` ends any other one rather than leave a permanently undrained entry behind.
        //
        // Spawned BEFORE `register`, parked until it returns: registering first is what keeps a
        // short-lived command from being drained and retired before its client is attached, and
        // spawning first is what lets a failed spawn fail the request before any client has been
        // told `Attached` (which would be followed by a `Failure` and no session to ever close).
        let (go, start) = std::sync::mpsc::channel::<()>();
        let spawned = std::thread::Builder::new().spawn(move || {
            // An `Err` is the sender dropped without a send, which only a panicking `register` can
            // do; draining anyway is what that case needs too.
            let _ = start.recv();
            read_session(spec.id, number, pty, shadow, attached, store)
        });
        if spawned.is_err() {
            self.kill(spec.id);
            return Err(SessionError::ReaderFailed(spec.id.to_hyphenated()));
        }
        let result = register(info);
        let _ = go.send(());
        result
    }

    /// The three pieces an operation on a live session needs, taken out of the store so nothing
    /// below holds the store lock while touching a pty, a shadow or a client.
    pub(super) fn parts(&self, id: SessionId) -> Option<SessionParts> {
        let sessions = lock_or_recover(&self.sessions);
        let session = sessions.get(&id)?;
        Some((
            Arc::clone(&session.pty),
            Arc::clone(&session.shadow),
            Arc::clone(&session.attached),
        ))
    }

    pub fn contains(&self, id: SessionId) -> bool {
        lock_or_recover(&self.sessions).contains_key(&id)
    }

    /// Sorted by id so the list is stable between calls — an unordered list makes a UI reorder
    /// itself for no reason.
    pub fn list(&self) -> Vec<SessionInfo> {
        let sessions = lock_or_recover(&self.sessions);
        let mut out: Vec<SessionInfo> = sessions.values().map(Session::info).collect();
        out.sort_by_key(|info| info.id);
        out
    }

    #[cfg(any(test, feature = "test-support"))]
    pub fn with_pty<T>(&self, id: SessionId, f: impl FnOnce(&Pty) -> T) -> Option<T> {
        let sessions = lock_or_recover(&self.sessions);
        sessions.get(&id).map(|session| f(&session.pty))
    }

    /// The session's pty's columns and rows, from the kernel: what `terminal.command` (#691)
    /// renders its command's output at. `None` when the session has gone or the size can't be
    /// read.
    pub fn pty_size(&self, id: SessionId) -> Option<(u16, u16)> {
        let pty = lock_or_recover(&self.sessions)
            .get(&id)
            .map(|session| Arc::clone(&session.pty))?;
        pty.size().ok()
    }

    /// Whether the session's shell has its terminal: its pty's foreground process group is the
    /// shell's own, so no program it started is running in the foreground. What `terminal.command`
    /// (#691) asks when the shell's marks can't say. `None` when the session has gone.
    pub fn shell_in_foreground(&self, id: SessionId) -> Option<bool> {
        let pty = lock_or_recover(&self.sessions)
            .get(&id)
            .map(|session| Arc::clone(&session.pty))?;
        Some(pty.foreground_pgid() == Some(pty.child_pid()))
    }

    /// The session's shadow terminal, taken out of the store so the caller can hold it across a
    /// read without keeping the store locked: the terminal API's capture (#686), and tests.
    pub fn shadow(&self, id: SessionId) -> Option<Arc<Mutex<Shadow>>> {
        let sessions = lock_or_recover(&self.sessions);
        sessions.get(&id).map(|session| Arc::clone(&session.shadow))
    }

    /// What the terminal API's `terminal.send` types (#689), written to the session's pty as no
    /// client: nothing an attach does happens, so no repaint, no client counted as attached, no
    /// size claimed or arbitrated (ADR 0042) and no keepalive probes. Its attachment lock is never
    /// taken, so the reader's echo of a long paste is never held up behind the write. `paste` is
    /// the range of `bytes` that is a bracketed paste, and `until` the send's deadline
    /// (`Pty::send`). `None` when the session has gone.
    pub fn send_input(
        &self,
        id: SessionId,
        bytes: &[u8],
        paste: Option<std::ops::Range<usize>>,
        until: Instant,
    ) -> Option<Result<(), crate::terminal::pty::Stopped>> {
        let pty = lock_or_recover(&self.sessions)
            .get(&id)
            .map(|session| Arc::clone(&session.pty))?;
        Some(pty.send(bytes, paste, until))
    }

    /// [`SessionStore::send_input`], then `then`'s bytes its pause after `bytes`, in the same turn
    /// of the pty's input, if its `before` still says so then (`Pty::send_then`): a prompt's Enter
    /// (#692), which no other input lands before, kept out of the read that takes its paste.
    /// Whether they were written.
    pub fn send_input_then(
        &self,
        id: SessionId,
        bytes: &[u8],
        paste: Option<std::ops::Range<usize>>,
        then: crate::terminal::pty::Then<'_>,
        until: Instant,
    ) -> Option<Result<bool, crate::terminal::pty::Stopped>> {
        let pty = lock_or_recover(&self.sessions)
            .get(&id)
            .map(|session| Arc::clone(&session.pty))?;
        Some(pty.send_then(bytes, paste, then, until))
    }

    /// What runs in session `id`'s foreground now (#692): its process group, the name a user would
    /// know its program by (`process::executable_name`, the exec-time argv a self-renaming CLI
    /// can't change), and whether that group is the session's interactive shell. `None` when the
    /// session has gone.
    pub fn foreground(&self, id: SessionId) -> Option<Foreground> {
        let (pty, interactive) = lock_or_recover(&self.sessions)
            .get(&id)
            .map(|session| (Arc::clone(&session.pty), session.interactive))?;
        let group = pty.foreground_pgid();
        Some(Foreground {
            group,
            name: group.and_then(crate::terminal::process::executable_name),
            shell: interactive && group == Some(pty.child_pid()),
        })
    }

    /// For a hand-off: each session's paste a send left open closed, if its program takes the
    /// end by `until` (`Pty::close_owed_paste`). Whether every one was.
    pub fn close_owed_pastes(&self, until: Instant) -> bool {
        let ptys: Vec<Arc<Pty>> = lock_or_recover(&self.sessions)
            .values()
            .map(|session| Arc::clone(&session.pty))
            .collect();
        // Every one tried, the first left open stopping none after it.
        ptys.iter()
            .filter(|pty| !pty.close_owed_paste(until))
            .count()
            == 0
    }

    pub fn is_empty(&self) -> bool {
        lock_or_recover(&self.sessions).is_empty()
    }

    /// `(id, columns, rows, record)` for each session whose screen changed since it was last
    /// taken. Read under the session's attachment lock, as `frozen` reads a screen, so the size is
    /// the one the screen was drawn at.
    ///
    /// A session whose lock is not free by `RECORD_WAIT` from the start of the call is left for the
    /// next call, still marked changed. An attach holds that lock for as long as a slow client
    /// takes its repaint, and such sessions must not hold up every other session's record, however
    /// many there are.
    pub fn changed_screens(&self) -> Vec<TakenScreen> {
        let parts: Vec<(SessionId, u64, SessionParts)> = {
            let sessions = lock_or_recover(&self.sessions);
            sessions
                .values()
                .map(|session| {
                    (
                        session.id,
                        session.number,
                        (
                            Arc::clone(&session.pty),
                            Arc::clone(&session.shadow),
                            Arc::clone(&session.attached),
                        ),
                    )
                })
                .collect()
        };
        let shared = Instant::now() + RECORD_WAIT;
        parts
            .into_iter()
            .filter_map(|(id, number, (pty, shadow, attached))| {
                // `RECORD_WAIT` is the whole pass's budget, so busy sessions cannot add up to a pass
                // longer than the screens thread's interval. Every session still gets at least
                // `RECORD_GRACE`: a session in a long repaint, visited first in the map's arbitrary
                // order, used to spend the whole budget and leave each session after it a single
                // attempt, which lost its record whenever it met that session's reader mid-read.
                let deadline = shared.max(Instant::now() + RECORD_GRACE);
                let Some(mut held) = until(deadline, || try_recover(attached.try_lock())) else {
                    // Left changed for the next pass, which the screens thread must come back for:
                    // a session that has gone quiet raises nothing more.
                    self.hooks.screen_changed();
                    return None;
                };
                if !std::mem::take(&mut held.changed) {
                    return None;
                }
                let (columns, rows) = pty.size().unwrap_or((
                    crate::terminal::pty::DEFAULT_COLUMNS,
                    crate::terminal::pty::DEFAULT_ROWS,
                ));
                // Compressed in the same hold, so the pages the record re-inflated are not kept
                // through the disk writes and syncs of every record this pass takes.
                let record = {
                    let mut shadow = lock_or_recover(&shadow);
                    let record = shadow.record();
                    shadow.compress();
                    record
                };
                Some(TakenScreen {
                    id,
                    session: number,
                    columns,
                    rows,
                    record,
                })
            })
            .collect()
    }

    /// Whether `id` is still the session `changed_screens` took a screen of (`TakenScreen::session`)
    /// rather than a later one under the same id, or none.
    pub fn still_holds(&self, id: SessionId, session: u64) -> bool {
        lock_or_recover(&self.sessions)
            .get(&id)
            .is_some_and(|s| s.number == session)
    }

    /// Takes this session's screen again on the next `changed_screens`.
    pub fn mark_changed(&self, id: SessionId) {
        if let Some((_, _, attached)) = self.parts(id) {
            lock_or_recover(&attached).changed = true;
            self.hooks.screen_changed();
        }
    }

    pub fn ids(&self) -> Vec<SessionId> {
        lock_or_recover(&self.sessions).keys().copied().collect()
    }

    /// Compresses every shadow's history (#463): what output wrote, and what an attach or a
    /// hand-off's read re-inflated, since the last pass. `screens::tick` runs it every
    /// `screens::INTERVAL`, after the records.
    ///
    /// The store lock is released first, then each shadow's is taken on its own, never a
    /// session's attachment lock: the reader, an attach or a hand-off waits at most one shadow's
    /// pass, on a lock it takes anyway. An already compressed shadow costs about 0.001 ms. A
    /// poisoned shadow is still compressed, as `program_status_events` still reads one.
    pub fn compress_shadows(&self) {
        let shadows: Vec<Arc<Mutex<Shadow>>> = {
            let sessions = lock_or_recover(&self.sessions);
            sessions
                .values()
                .map(|session| Arc::clone(&session.shadow))
                .collect()
        };
        for shadow in shadows {
            lock_or_recover(&shadow).compress();
        }
    }

    /// Lets each unprobed request alert whose sender is still running in the foreground a grace
    /// after it blocked, and is not the session's interactive shell (#481). `screens::tick` runs
    /// it every `screens::INTERVAL`; as `compress_shadows`, it takes each shadow's lock on its own.
    /// Only a session with an unprobed request has its attachment lock taken after, released, to
    /// tell its waits (`program_status_changed`).
    pub fn promote_unprobed(&self, now: Instant) -> bool {
        let mut pending = false;
        let sessions: Vec<_> = {
            let sessions = lock_or_recover(&self.sessions);
            sessions
                .values()
                .map(|s| {
                    (
                        s.id,
                        Arc::clone(&s.pty),
                        Arc::clone(&s.shadow),
                        s.interactive,
                    )
                })
                .collect()
        };
        for (id, pty, shadow, interactive) in sessions {
            let mut looked = false;
            self.hooks.change_program_status(id, &shadow, |status| {
                if !status.has_unprobed_request() {
                    return;
                }
                pending = true;
                looked = true;
                let foreground = pty.foreground_pgid();
                let shell = interactive.then(|| pty.child_pid());
                status.promote_unprobed(now, |group| {
                    Some(group) == foreground
                        && Some(group) != shell
                        && crate::terminal::program_status::group_alive(group)
                });
            });
            // A promoted request is the one `sessions` reports, which a wait for `blocked` is
            // waiting to see (#690); with the shadow's lock released, as a read tells them.
            if looked {
                self.program_status_changed(id);
            }
        }
        pending
    }

    /// Session `id` was just started to resume `record` (#825): its status carries the record from
    /// its first event, so the app keeps it until the program reports itself in the new session,
    /// and its resume state knows what it resumes, and since when. The locks are taken in the
    /// reader's order, with the map released.
    pub(crate) fn resuming(&self, id: SessionId, record: crate::terminal::resume::Whole) {
        let Some((resume, attached, shadow)) =
            lock_or_recover(&self.sessions).get(&id).map(|session| {
                (
                    Arc::clone(&session.resume),
                    Arc::clone(&session.attached),
                    Arc::clone(&session.shadow),
                )
            })
        else {
            return;
        };
        let _held = lock_or_recover(&attached);
        if let Some(state) = lock_or_recover(&resume).as_mut() {
            state.resuming(
                crate::terminal::resume::program_name(&record.argv),
                Instant::now(),
            );
        }
        if let Some(status) = lock_or_recover(&shadow).status() {
            status.set_resume(Some(record));
        }
    }

    /// Clears each resume record whose owner has been gone for `resume::EXIT_GRACE` while its
    /// session's shell runs on (ADR 0082, #823), looking at `now`; `screens::tick` runs it every
    /// `screens::INTERVAL`. Each session's resume lock is taken on its own, with the map released,
    /// as `described` takes it. A session whose record cleared publishes its status (#824), with
    /// the record read again under its attachment lock, as its reader reads it, so a report fed
    /// meanwhile is never overwritten by the record before it. Whether a session still has a
    /// record to look at again.
    pub fn watch_resume_owners(&self, now: Instant) -> bool {
        use crate::terminal::resume::SharedResume;
        type Parts = (
            SessionId,
            SharedResume,
            Arc<Mutex<Attached>>,
            Arc<Mutex<Shadow>>,
        );
        let resumes: Vec<Parts> = {
            let sessions = lock_or_recover(&self.sessions);
            sessions
                .values()
                .map(|session| {
                    (
                        session.id,
                        Arc::clone(&session.resume),
                        Arc::clone(&session.attached),
                        Arc::clone(&session.shadow),
                    )
                })
                .collect()
        };
        let mut watching = false;
        for (id, resume, attached, shadow) in resumes {
            let watched = crate::terminal::resume::watch_owners(
                &resume,
                now,
                crate::terminal::process::identity,
            );
            watching |= watched.watching;
            if watched.cleared.is_empty() {
                continue;
            }
            for program in &watched.cleared {
                crate::note!(
                    "session {}: {program} exited, so its resume record is cleared",
                    id.to_hyphenated()
                );
            }
            let published = {
                let _held = lock_or_recover(&attached);
                let record = lock_or_recover(&resume)
                    .as_ref()
                    .and_then(crate::terminal::resume::Resume::whole);
                let mut shadow = lock_or_recover(&shadow);
                shadow.status().and_then(|status| {
                    status.set_resume(record);
                    let blocked = status.commit()?;
                    Some(super::hooks::Published::of(
                        status,
                        self.hooks.boot(),
                        id,
                        blocked,
                    ))
                })
            };
            if let Some(published) = published {
                self.hooks.status_changed(id, published);
            }
        }
        watching
    }

    /// Every live session's `status` event, in id order, for a new subscriber's snapshot. Each is
    /// read under its own shadow lock, never the store's.
    pub fn program_status_events(&self) -> Vec<(SessionId, Vec<u8>)> {
        let shadows: Vec<(SessionId, Arc<Mutex<Shadow>>)> = {
            let sessions = lock_or_recover(&self.sessions);
            sessions
                .values()
                .map(|session| (session.id, Arc::clone(&session.shadow)))
                .collect()
        };
        let boot = self.hooks.boot();
        let mut events: Vec<(SessionId, Vec<u8>)> = shadows
            .into_iter()
            .map(|(id, shadow)| {
                let mut shadow = lock_or_recover(&shadow);
                let event = shadow.status().map_or_else(
                    || Store::default().event(boot, id),
                    |status| status.event(boot, id),
                );
                (id, event)
            })
            .collect();
        events.sort_by_key(|(id, _)| *id);
        events
    }

    /// Every live session as the terminal API lists it (#683), in id order: what `list` reports,
    /// then its live title and coding agent, each read under its own shadow lock once the store's
    /// is released.
    pub fn described(&self) -> Vec<Described> {
        type Parts = (
            SessionInfo,
            Vec<ClientInfo>,
            Arc<Mutex<Shadow>>,
            crate::terminal::resume::SharedResume,
        );
        let sessions: Vec<Parts> = {
            let sessions = lock_or_recover(&self.sessions);
            sessions
                .values()
                .map(|session| {
                    let clients = lock_or_recover(&session.attached).listed();
                    (
                        session.info(),
                        clients,
                        Arc::clone(&session.shadow),
                        Arc::clone(&session.resume),
                    )
                })
                .collect()
        };
        let mut described: Vec<Described> = sessions
            .into_iter()
            .map(|(info, clients, shadow, resume)| {
                let resume = lock_or_recover(&resume)
                    .as_ref()
                    .and_then(|resume| resume.recorded());
                let mut shadow = lock_or_recover(&shadow);
                Described {
                    title: shadow.title(),
                    coding_agent: shadow.status().and_then(|status| status.coding_agent()),
                    resume,
                    info,
                    clients,
                }
            })
            .collect();
        described.sort_by_key(|session| session.info.id);
        described
    }

    /// Applies `change` to `id`'s program status and publishes what it changed. False when there
    /// is no session `id`.
    pub fn update_program_status(&self, id: SessionId, change: impl FnOnce(&mut Store)) -> bool {
        let Some((_, shadow, _)) = self.parts(id) else {
            return false;
        };
        self.hooks.change_program_status(id, &shadow, change);
        self.program_status_changed(id);
        true
    }
}

/// How long one `changed_screens` pass waits, in all, for sessions' attachment locks. The reader
/// holds one only around each read, so a busy session frees it within milliseconds; a repaint to a
/// slow client can hold it for seconds.
pub(super) const RECORD_WAIT: Duration = Duration::from_millis(100);

/// The least wait any one session gets in a pass, once `RECORD_WAIT` is spent: a few of `until`'s
/// attempts, which is plenty to get past a reader's single read.
pub(super) const RECORD_GRACE: Duration = Duration::from_millis(10);
