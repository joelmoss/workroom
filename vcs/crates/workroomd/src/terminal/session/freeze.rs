//! A hand-off's freeze of every session, and adopting one in the next program.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::reader::read_session;
use super::{
    Attached, FrozenSession, Metadata, NEXT_SESSION, Session, SessionError, SessionId,
    SessionParts, SessionStore, TERMINATING, until,
};
use crate::terminal::images::ImageRef;
use crate::terminal::pty::{Pty, Size};
use crate::terminal::shadow::Shadow;
use crate::util::{lock_or_recover, try_recover};

impl SessionStore {
    /// Runs `f` with every session's output stopped and its screen captured, for a hand-off.
    ///
    /// Holds the store lock, so no session is created or ended meanwhile, and then every session's
    /// attachment lock, which its reader takes around each read (`read_session`). So no byte leaves
    /// any pty while `f` runs, and every byte already read is in the screen `f` is given. `f` may
    /// replace the program. If it returns instead, the locks drop and every reader carries on with
    /// nothing lost.
    ///
    /// Store before attachment, the same order `Session::info` takes them in under `list`.
    ///
    /// `None` when the locks are not all taken `within`. A session being killed holds
    /// `TERMINATING` through its SIGHUP grace, and an attach holds its attachment lock for as long
    /// as a slow client takes its repaint, while every other session waits behind the store lock
    /// held here. So the wait is bounded, and a busy moment refuses the hand-off.
    ///
    /// Each screen is the newest history that fits its share of `HANDOFF_TOTAL_BYTES`, captured
    /// within `HANDOFF_FORMAT_DEADLINE` (`frozen_formatting`).
    pub fn frozen<T>(&self, within: Duration, f: impl FnOnce(&[FrozenSession]) -> T) -> Option<T> {
        self.frozen_formatting(within, HANDOFF_FORMAT_DEADLINE, f)
    }

    /// `frozen`, capturing the screens within `format_within` of taking the locks.
    ///
    /// Every session's screen is formatted while every session is stopped, so that time is
    /// bounded too. Each session gets `HANDOFF_TOTAL_BYTES / sessions` (at most a repaint's
    /// `REPAINT_MAX_BYTES`), so the work follows the total, not the count. Past the deadline, the
    /// sessions not yet captured are captured with their screen alone, and one on the alternate
    /// screen without the primary's paint, which costs a copy of its terminal: a hand-off that
    /// runs out of time still happens, and those sessions lose their history once. Refusing it
    /// instead would refuse it again at every launch while the same sessions stayed open.
    pub fn frozen_formatting<T>(
        &self,
        within: Duration,
        format_within: Duration,
        f: impl FnOnce(&[FrozenSession]) -> T,
    ) -> Option<T> {
        let deadline = Instant::now() + within;
        let _no_terminations = until(deadline, || try_recover(TERMINATING.try_write()))?;
        // Within the deadline too: `list` and the end of `attach` hold the store lock while they
        // wait on a session's attachment lock, so a repaint holds the store lock as well.
        let store = until(deadline, || try_recover(self.sessions.try_lock()))?;
        let parts: Vec<(SessionId, SessionParts, Metadata)> = store
            .values()
            .map(|session| {
                (
                    session.id,
                    (
                        Arc::clone(&session.pty),
                        Arc::clone(&session.shadow),
                        Arc::clone(&session.attached),
                    ),
                    session.metadata.clone(),
                )
            })
            .collect();
        let mut held = Vec::with_capacity(parts.len());
        for (_, (_, _, attached), _) in &parts {
            held.push(until(deadline, || try_recover(attached.try_lock()))?);
        }
        let share =
            crate::terminal::shadow::record_budget(HANDOFF_TOTAL_BYTES / parts.len().max(1));
        let started = Instant::now();
        let format_until = started + format_within;
        let mut late = 0;
        let mut sessions: Vec<FrozenSession> = parts
            .iter()
            .map(|(id, (pty, shadow, _), metadata)| {
                // The kernel's size, which is what the shell was last told.
                let (columns, rows) = pty.size().unwrap_or((
                    crate::terminal::pty::DEFAULT_COLUMNS,
                    crate::terminal::pty::DEFAULT_ROWS,
                ));
                if Instant::now() >= format_until {
                    late += 1;
                }
                // One statement per lock: a guard taken inside the struct below would live to the
                // end of it, and the second field would wait on the first's.
                let mut screen = lock_or_recover(shadow).replay_for_within(
                    pty.foreground_pgid(),
                    share,
                    Some(format_until),
                );
                // The live title first, so the screen's own marks come after it (#683). It is the
                // reported title, cut to `shadow::MAX_TITLE_BYTES` (256), so a longer one the
                // program set arrives cut on the other side; no listing showed more than that.
                let title = lock_or_recover(shadow).title();
                if let Some(title) = title {
                    screen.splice(0..0, crate::terminal::shadow::title_sequence(&title));
                }
                let program_status = lock_or_recover(shadow)
                    .status()
                    .cloned()
                    .unwrap_or_default();
                FrozenSession {
                    id: *id,
                    pid: pty.child_pid(),
                    master: pty.master_fd(),
                    columns,
                    rows,
                    // As a client would be shown it. The table carries no owner, so the new daemon
                    // gives any report in it to whoever owns the pty then; a dead sender's report
                    // frozen whole would become the shell's, busy at its prompt (#359). A stopped
                    // sender (^Z) loses its report here and shows idle until its next one.
                    screen,
                    metadata: metadata.clone(),
                    program_status,
                }
            })
            .collect();
        if late > 0 {
            eprintln!(
                "workroomd: hand-off: capturing screens took longer than {} ms; {late} of {} \
                 sessions carried their screen without history",
                format_within.as_millis(),
                sessions.len()
            );
        }
        let shadows: Vec<_> = parts.iter().map(|(_, (_, shadow, _), _)| shadow).collect();
        carry_images(
            &shadows,
            &mut sessions,
            Instant::now() + HANDOFF_IMAGE_DEADLINE,
            HANDOFF_IMAGE_BYTES,
        );
        let result = f(&sessions);
        drop(held);
        drop(store);
        Some(result)
    }

    /// Takes over a session an earlier program in this process was running
    /// (`crate::daemon::handoff`): its pty (made from `frozen`'s descriptor), and a fresh shadow
    /// painted with the screen that program captured.
    ///
    /// No client comes with it, so nobody owns the size: the first client to attach with one takes
    /// it, as on a new session.
    ///
    /// Its program status records come with it, revision and episodes included, so the app sees
    /// one store continue. Nothing is published: a program that just started has no subscriber,
    /// and the first one's snapshot carries them.
    pub fn adopt(&self, pty: Pty, frozen: FrozenSession) -> Result<(), SessionError> {
        self.adopt_parked(pty, frozen).map(Parked::start)
    }

    /// Adopts every session a hand-off carried, then has the terminal API's events take in what
    /// was adopted (`events::Hub::reconcile`, `events_carried` when the table carried them), and
    /// only then starts the sessions' readers. A shell that ended during the hand-off is seen
    /// ending by its reader, after the events know it, so its end is one event like any other,
    /// with its exit code, never a session the events go on holding. A session that can't be
    /// adopted is reported and dropped, which closes its pty and hangs up its shell.
    pub fn adopt_all(&self, sessions: Vec<(Pty, FrozenSession)>, events_carried: bool) {
        let mut parked = Vec::with_capacity(sessions.len());
        for (pty, session) in sessions {
            let id = session.id;
            match self.adopt_parked(pty, session) {
                Ok(reader) => parked.push(reader),
                Err(e) => crate::note!(
                    "error: session {} could not be adopted, so its shell is hung up: {e}",
                    id.to_hyphenated()
                ),
            }
        }
        let live = self
            .described()
            .iter()
            .map(|session| (session.info.id, crate::terminal::api::session_json(session)))
            .collect();
        self.hooks.events.reconcile(live, events_carried);
        for reader in parked {
            reader.start();
        }
    }

    /// [`SessionStore::adopt`], its reader started but waiting until [`Parked::start`]: a
    /// hand-off's next program holds every reader until the terminal API's events know what was
    /// adopted (`events::Hub::reconcile`), so a shell that ended meanwhile is an end those events
    /// tell, not one they miss.
    pub fn adopt_parked(&self, pty: Pty, frozen: FrozenSession) -> Result<Parked, SessionError> {
        let FrozenSession {
            id,
            columns,
            rows,
            screen,
            metadata,
            program_status,
            ..
        } = frozen;
        let mut shadow = Shadow::new(columns, rows);
        // Before the screen, so an image in it takes the rows it took for the client.
        if let Ok((x_pixels, y_pixels)) = pty.pixels() {
            shadow.resize(Size {
                columns,
                rows,
                x_pixels,
                y_pixels,
            });
        }
        // A hand-off keeps the processes, so whoever owns the pty now sent any report in `screen`.
        // The screen is the old program's paint, not the program's output: it asks nothing.
        let _ = shadow.write_from_pty(&screen, || pty.foreground_pgid());
        // After the screen, whose prompt marks would otherwise end the run they describe.
        if let Some(status) = shadow.status() {
            *status = program_status;
        }
        let session = Session {
            id,
            pty: Arc::new(pty),
            shadow: Arc::new(Mutex::new(shadow)),
            attached: Arc::new(Mutex::new(Attached::unrecorded())),
            number: NEXT_SESSION.fetch_add(1, Ordering::Relaxed),
            // A hand-off carries no such flag, and the app makes only shells and run sessions,
            // which say which they are in their metadata (#522).
            interactive: !crate::terminal::run::is_run(&metadata),
            metadata,
        };
        let number = session.number;
        let pty = Arc::clone(&session.pty);
        let shadow = Arc::clone(&session.shadow);
        let attached = Arc::clone(&session.attached);
        let store = self.clone();
        {
            let mut sessions = lock_or_recover(&self.sessions);
            if sessions.contains_key(&id) {
                return Err(SessionError::AlreadyExists(id.to_hyphenated()));
            }
            sessions.insert(id, session);
        }
        let pid = pty.child_pid();
        // Spawned now, so a thread that can't start fails the adoption, and parked until `start`:
        // a sender dropped unsent starts it too, as `create_then`'s does.
        let (go, parked) = std::sync::mpsc::channel::<()>();
        let spawned = std::thread::Builder::new().spawn(move || {
            let _ = parked.recv();
            read_session(id, number, pty, shadow, attached, store)
        });
        if spawned.is_err() {
            self.kill(id);
            return Err(SessionError::ReaderFailed(id.to_hyphenated()));
        }
        crate::note!("session {} adopted: shell pid {pid}", id.to_hyphenated());
        Ok(Parked(go))
    }
}

/// An adopted session whose reader waits to be started (`SessionStore::adopt_parked`). Dropped, it
/// starts too.
pub struct Parked(std::sync::mpsc::Sender<()>);

impl Parked {
    pub fn start(self) {
        let _ = self.0.send(());
    }
}

/// What a hand-off's screens share between them (`frozen_formatting`). Formatting runs at about
/// 6.7 ms a MiB, so the whole is about 0.2 s at two formats a session; four sessions or fewer each
/// get a full repaint's `REPAINT_MAX_BYTES`, sixteen get 1 MiB.
pub(super) const HANDOFF_TOTAL_BYTES: usize = 16 << 20;

/// How long a hand-off spends capturing screens, with every session stopped, before the rest are
/// captured with their screen alone (`frozen_formatting`). Counted in the hand-off's timeout sum
/// (`handoff.rs`).
pub(crate) const HANDOFF_FORMAT_DEADLINE: Duration = Duration::from_millis(250);

/// How long a hand-off spends encoding images, after every screen's text, with every session still
/// stopped. Counted in the hand-off's timeout sum too.
pub(crate) const HANDOFF_IMAGE_DEADLINE: Duration = Duration::from_millis(250);

/// What a hand-off's images share between them, encoded. A session past this or the deadline keeps
/// its text and loses its images.
pub(super) const HANDOFF_IMAGE_BYTES: usize = 32 << 20;

/// Adds each session's visible images to its frozen screen, newest first, ahead of the parser
/// continuation. Nothing can interleave with a frozen screen, so they travel whole.
pub(super) fn carry_images(
    shadows: &[&Arc<Mutex<Shadow>>],
    sessions: &mut [FrozenSession],
    until: Instant,
    budget: usize,
) {
    let mut images: Vec<(usize, ImageRef)> = Vec::new();
    for (index, shadow) in shadows.iter().enumerate() {
        let visible = lock_or_recover(shadow).visible_images();
        images.extend(visible.into_iter().map(|i| (index, i)));
    }
    images.sort_by_key(|(_, image)| std::cmp::Reverse(image.generation));
    carry_listed(shadows, sessions, images, until, budget);
}

pub(super) fn carry_listed(
    shadows: &[&Arc<Mutex<Shadow>>],
    sessions: &mut [FrozenSession],
    images: Vec<(usize, ImageRef)>,
    until: Instant,
    budget: usize,
) {
    let mut left = budget;
    for (index, image) in images {
        if Instant::now() >= until {
            return;
        }
        let shadow = lock_or_recover(shadows[index]);
        let Some(bytes) = shadow.hand_off_image(image) else {
            continue;
        };
        // Past the total, the rest would be encoded only to be refused, with every session stopped.
        let Some(remaining) = left.checked_sub(bytes.len()) else {
            return;
        };
        left = remaining;
        let screen = &mut sessions[index].screen;
        let at = screen.len().saturating_sub(shadow.continuation_len());
        screen.splice(at..at, bytes);
    }
}
