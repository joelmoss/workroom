//! Sessions: a pty plus the identity a client reattaches by.
//!
//! **Identity is client-minted**, as it already is today — `TerminalSessions.swift` stores a
//! 16-byte UUID per pane and hands it over on attach. The agent does not invent ids; it only
//! remembers which pty belongs to which one, which is what lets a client that quit and came back
//! find the same shell.
//!
//! **What this deliberately does not do is restore the screen.** A session surviving a detach and
//! a screen being repainted on reattach are separate problems, and the design doc is explicit that
//! `libghostty-vt`'s snapshot replaces the old replay buffer rather than being ported alongside
//! it — so building a ring buffer here would be building something already scheduled for
//! deletion. Reattach therefore resumes the live byte stream; painting what came before is the
//! terminal-state work that follows.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::protocol::envelope::{Envelope, Service};
use crate::protocol::frame::{Frame, FrameKind};
use crate::pty::{Pty, PtyError};
use crate::shadow::Shadow;

/// A connection's write half, shared with whichever session it is attached to.
///
/// Boxed because the reader below holds it for the session's life and must not be generic over the
/// transport — a session outlives the connection that created it, and the next one may arrive over
/// a different kind of stream entirely.
pub type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;

/// Who is currently attached. At most one, by construction.
struct Client {
    writer: SharedWriter,
    stream: u32,
    /// Distinguishes THIS attachment from a later one on the same session. Without it a client
    /// whose connection ends after being superseded detaches the client that replaced it.
    token: u64,
}

/// Hands out attachment tokens. Process-wide and monotonic; the value means nothing but "later".
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

/// The client-minted session id: 16 bytes, matching `SessionIdentifier`'s UUID.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(pub [u8; 16]);

impl SessionId {
    pub fn from_slice(bytes: &[u8]) -> Option<SessionId> {
        (bytes.len() == 16).then(|| {
            let mut id = [0u8; 16];
            id.copy_from_slice(bytes);
            SessionId(id)
        })
    }

    /// Lowercase hyphenated UUID, so agent logs and the app's own logs can be grepped together.
    pub fn to_hyphenated(self) -> String {
        let h: Vec<String> = self.0.iter().map(|b| format!("{b:02x}")).collect();
        format!(
            "{}-{}-{}-{}-{}",
            h[0..4].concat(),
            h[4..6].concat(),
            h[6..8].concat(),
            h[8..10].concat(),
            h[10..16].concat()
        )
    }
}

/// What a client needs to know about a session it is not attached to, for the session list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionInfo {
    pub id: SessionId,
    /// The pty child's pid — the shell, not the foreground program. The app reports it in session
    /// listings and crash diagnostics.
    pub pid: i32,
    pub attached: bool,
    /// The foreground command, resolved at read time rather than stored — a session's foreground
    /// process changes without the agent being told, so a cached value is wrong more often than
    /// it is right.
    pub foreground: Option<String>,
    pub cwd: Option<String>,
}

pub struct Session {
    pub id: SessionId,
    /// Shared with the session's reader thread, which outlives any one connection. The `Arc` is
    /// also what keeps the master descriptor open until that thread has finished with it, so
    /// killing a session cannot pull the fd out from under a read in progress.
    pty: Arc<Pty>,
    /// The emulator shadowing this session's screen, so a client that attaches later can be shown
    /// what is on it. Behind its own lock rather than the store's: the reader writes to it on
    /// every read, and holding the whole store for that would serialise every session's output
    /// behind every other session's.
    shadow: Arc<Mutex<Shadow>>,
    /// The attached client, or none. Shared with the reader, which forwards to it when there is
    /// one and to the shadow alone when there is not.
    client: Arc<Mutex<Option<Client>>>,
}

impl Session {
    pub fn pty(&self) -> &Pty {
        &self.pty
    }

    pub fn info(&self) -> SessionInfo {
        let foreground = self.pty.foreground_pgid();
        SessionInfo {
            id: self.id,
            pid: self.pty.child_pid(),
            attached: self
                .client
                .lock()
                .map(|client| client.is_some())
                .unwrap_or(false),
            foreground: foreground.and_then(crate::process::executable_name),
            cwd: foreground.and_then(crate::process::working_directory),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("session {0} already exists")]
    AlreadyExists(String),
    #[error("no session {0}")]
    NotFound(String),
    #[error(transparent)]
    Pty(#[from] PtyError),
}

/// Owns every live session. Cheap to clone; all clones share one map.
#[derive(Clone, Default)]
pub struct SessionStore {
    sessions: Arc<Mutex<HashMap<SessionId, Session>>>,
}

/// How a session's pty should be started. Grouped into one struct because the list is long enough
/// that positional arguments stop being readable, and every field is required.
pub struct SessionSpec<'a> {
    pub id: SessionId,
    pub program: &'a OsStr,
    /// What the child sees as `argv[0]`. `None` repeats `program`, which is the ordinary
    /// convention; a login shell needs its own name prefixed with `-` here instead.
    pub argv0: Option<&'a OsStr>,
    pub args: &'a [OsString],
    pub env: &'a [(OsString, OsString)],
    pub cwd: Option<&'a OsStr>,
    pub columns: u16,
    pub rows: u16,
}

impl SessionStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates a session, or fails if the id is taken.
    ///
    /// Taking the lock across the spawn is deliberate: two clients racing to create the same id
    /// must not both fork a shell, and the window is a single `forkpty`.
    pub fn create(&self, spec: SessionSpec<'_>) -> Result<SessionInfo, SessionError> {
        let mut sessions = self.sessions.lock().expect("session store poisoned");
        if sessions.contains_key(&spec.id) {
            return Err(SessionError::AlreadyExists(spec.id.to_hyphenated()));
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
            crate::pty::DEFAULT_COLUMNS
        } else {
            spec.columns
        };
        let rows = if spec.rows == 0 {
            crate::pty::DEFAULT_ROWS
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
        let session = Session {
            id: spec.id,
            pty: Arc::new(pty),
            shadow: Arc::new(Mutex::new(Shadow::new(columns, rows))),
            client: Arc::new(Mutex::new(None)),
        };
        let info = session.info();
        let pty = Arc::clone(&session.pty);
        let shadow = Arc::clone(&session.shadow);
        let client = Arc::clone(&session.client);
        let store = Arc::clone(&self.sessions);
        sessions.insert(spec.id, session);
        // Drop the store lock before the reader starts, or its first `ended` removal deadlocks
        // against this very lock.
        drop(sessions);
        std::thread::spawn(move || read_session(spec.id, pty, shadow, client, store));
        Ok(info)
    }

    /// Attaches a client, replacing whoever held the session, and repaints it.
    ///
    /// The replay is written HERE, under the client-slot lock, rather than by the caller after
    /// this returns. That ordering is the point: the reader takes the same lock around every
    /// write, so a repaint cannot be overtaken by output that arrives between registering and
    /// painting, and cannot duplicate output that the shadow has already absorbed.
    ///
    /// Returns the session's info and the attachment's token — hand that token back to `detach`.
    pub fn attach(
        &self,
        id: SessionId,
        writer: SharedWriter,
        stream: u32,
    ) -> Result<(SessionInfo, u64), SessionError> {
        let (shadow, slot) = {
            let sessions = self.sessions.lock().expect("session store poisoned");
            let session = sessions
                .get(&id)
                .ok_or_else(|| SessionError::NotFound(id.to_hyphenated()))?;
            (Arc::clone(&session.shadow), Arc::clone(&session.client))
        };

        let token = NEXT_TOKEN.fetch_add(1, Ordering::SeqCst);
        {
            let mut slot = slot.lock().expect("client slot poisoned");
            let replay = shadow.lock().map(|s| s.replay()).unwrap_or_default();
            if !replay.is_empty() {
                let bytes = terminal_envelope(stream, Frame::new(FrameKind::Output, replay));
                if let Ok(mut writer) = writer.lock() {
                    let _ = writer.write_all(&bytes).and_then(|()| writer.flush());
                }
            }
            *slot = Some(Client {
                writer,
                stream,
                token,
            });
        }

        let sessions = self.sessions.lock().expect("session store poisoned");
        let session = sessions
            .get(&id)
            .ok_or_else(|| SessionError::NotFound(id.to_hyphenated()))?;
        Ok((session.info(), token))
    }

    /// The client went away. The session and its pty keep running — that is the entire point, and
    /// the reader keeps draining the pty so a detached job neither stalls nor goes unrecorded.
    ///
    /// Only clears the slot if `token` still holds it: a superseded client's connection ending
    /// must not detach the client that superseded it.
    pub fn detach(&self, id: SessionId, token: u64) {
        let slot = {
            let sessions = match self.sessions.lock() {
                Ok(sessions) => sessions,
                Err(_) => return,
            };
            match sessions.get(&id) {
                Some(session) => Arc::clone(&session.client),
                None => return,
            }
        };
        let mut held = match slot.lock() {
            Ok(held) => held,
            Err(_) => return,
        };
        if held.as_ref().is_some_and(|client| client.token == token) {
            *held = None;
        }
    }

    pub fn contains(&self, id: SessionId) -> bool {
        self.sessions
            .lock()
            .map(|s| s.contains_key(&id))
            .unwrap_or(false)
    }

    /// Sorted by id so the list is stable between calls — an unordered list makes a UI reorder
    /// itself for no reason.
    pub fn list(&self) -> Vec<SessionInfo> {
        let sessions = self.sessions.lock().expect("session store poisoned");
        let mut out: Vec<SessionInfo> = sessions.values().map(Session::info).collect();
        out.sort_by_key(|info| info.id);
        out
    }

    pub fn with_pty<T>(&self, id: SessionId, f: impl FnOnce(&Pty) -> T) -> Option<T> {
        let sessions = self.sessions.lock().expect("session store poisoned");
        sessions.get(&id).map(|session| f(&session.pty))
    }

    /// The session's shadow terminal, taken out of the store so the caller can hold it across a
    /// read without keeping the store locked.
    pub fn shadow(&self, id: SessionId) -> Option<Arc<Mutex<Shadow>>> {
        let sessions = self.sessions.lock().expect("session store poisoned");
        sessions.get(&id).map(|session| Arc::clone(&session.shadow))
    }

    /// What a client attaching to this session should be sent before anything else, so it sees
    /// the screen rather than waiting for the next keystroke to produce output.
    pub fn replay_bytes(&self, id: SessionId) -> Vec<u8> {
        match self.shadow(id) {
            Some(shadow) => shadow.lock().map(|s| s.replay()).unwrap_or_default(),
            None => Vec::new(),
        }
    }

    /// Ends a session and its pty. Returns whether there was one to end.
    pub fn kill(&self, id: SessionId) -> bool {
        let mut sessions = self.sessions.lock().expect("session store poisoned");
        match sessions.remove(&id) {
            Some(session) => {
                terminate(&session.pty);
                true
            }
            None => false,
        }
    }

    pub fn kill_all(&self) -> usize {
        let mut sessions = self.sessions.lock().expect("session store poisoned");
        let count = sessions.len();
        for (_, session) in sessions.drain() {
            terminate(&session.pty);
        }
        count
    }

    pub fn is_empty(&self) -> bool {
        self.sessions.lock().map(|s| s.is_empty()).unwrap_or(true)
    }
}

/// Whether the pty's child has actually exited, reaping it if so.
///
/// `WNOHANG`, because the read can end a moment before the exit is reapable and telling the client
/// promptly matters more than the exact status. A negative return is `ECHILD` — already reaped by
/// someone else, which is equally gone.
fn child_gone(pid: i32, status: &mut i32) -> bool {
    if pid <= 0 {
        return true;
    }
    let rc = unsafe { libc::waitpid(pid, status, libc::WNOHANG) };
    rc != 0
}

fn terminal_envelope(stream: u32, frame: Frame) -> Vec<u8> {
    Envelope::new(Service::Terminal, stream, frame.encode()).encode()
}

/// Reads a session's pty for the session's whole life — attached or not.
///
/// **Owned by the session, not by the connection, and that is the fix for a real bug.** While the
/// reader belonged to the connection, a detached session had NO reader: its output never reached
/// the shadow, so a reattaching client was repainted with a stale screen, and — worse — once the
/// pty's output queue filled, the shell BLOCKED on write. A background job in a pane you had
/// closed the app on would simply stop, and only start again when you came back. The Swift daemon
/// polled every pty regardless of attachment; this restores that.
///
/// It also ends the session when the shell exits, whether or not anyone is watching. Previously a
/// shell that died while detached left a session in the list that nothing could ever be attached
/// to.
fn read_session(
    id: SessionId,
    pty: Arc<Pty>,
    shadow: Arc<Mutex<Shadow>>,
    client: Arc<Mutex<Option<Client>>>,
    store: Arc<Mutex<HashMap<SessionId, Session>>>,
) {
    let mut buffer = [0u8; 8192];
    loop {
        let read = pty.read(&mut buffer);

        // "The child is gone" looks different on each platform: reading a pty master whose child
        // has exited yields EOF on Darwin and **EIO** on Linux. Deciding it once, here, is what
        // stops the rest of this loop from having to know that — and matching only on EOF meant
        // the branch below never ran on Linux at all, while macOS exercised it and made the code
        // look correct. Found by running the suite in a Linux container.
        let ended = match &read {
            Ok(0) => true,
            Err(e) => matches!(e.raw_os_error(), Some(libc::EIO) | Some(libc::EBADF)),
            _ => false,
        };

        // A read saying "ended" is not proof, so confirm it against the CHILD before tearing a
        // session down. macOS returns a transient `read == 0` on a freshly forked master while the
        // shell is alive and merely has nothing to say — believing it ends the session moments
        // after creating it. The old pump never saw this because it only existed once a client had
        // attached, by which time the window had passed; a reader owned by the session starts
        // inside it.
        let mut status = 0;
        if ended && !child_gone(pty.child_pid(), &mut status) {
            std::thread::sleep(Duration::from_millis(5));
            continue;
        }

        if ended {
            if let Ok(slot) = client.lock() {
                if let Some(attached) = slot.as_ref() {
                    let bytes = terminal_envelope(
                        attached.stream,
                        Frame::new(FrameKind::Exited, status.to_be_bytes().to_vec()),
                    );
                    if let Ok(mut writer) = attached.writer.lock() {
                        let _ = writer.write_all(&bytes).and_then(|()| writer.flush());
                    }
                }
            }
            // The shell IS the session; with it gone there is nothing left to reattach to.
            if let Ok(mut store) = store.lock() {
                store.remove(&id);
            }
            return;
        }

        match read {
            Ok(n) => {
                // One lock around both writes. The shadow must absorb these bytes and the client
                // must be told about them as one step, or an attach landing between the two either
                // misses output or replays it twice.
                let slot = client.lock().expect("client slot poisoned");
                if let Ok(mut shadow) = shadow.lock() {
                    shadow.write(&buffer[..n]);
                }
                if let Some(attached) = slot.as_ref() {
                    let bytes = terminal_envelope(
                        attached.stream,
                        Frame::new(FrameKind::Output, buffer[..n].to_vec()),
                    );
                    if let Ok(mut writer) = attached.writer.lock() {
                        let _ = writer.write_all(&bytes).and_then(|()| writer.flush());
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(_) => return,
        }
    }
}

/// SIGHUP first, which is what a terminal closing means and what a shell expects; SIGKILL only if
/// it is ignored. Sending SIGKILL outright would deny a shell the chance to run its exit traps.
fn terminate(pty: &Pty) {
    let pid = pty.child_pid();
    unsafe {
        libc::kill(pid, libc::SIGHUP);
    }
    for _ in 0..50 {
        let mut status = 0;
        let rc = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if rc == pid || rc < 0 {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    unsafe {
        libc::kill(pid, libc::SIGKILL);
        let mut status = 0;
        libc::waitpid(pid, &mut status, 0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn id(byte: u8) -> SessionId {
        SessionId([byte; 16])
    }

    fn env() -> Vec<(OsString, OsString)> {
        vec![
            (OsString::from("TERM"), OsString::from("xterm-256color")),
            (OsString::from("PATH"), OsString::from("/usr/bin:/bin")),
        ]
    }

    fn spec<'a>(
        session: SessionId,
        args: &'a [OsString],
        env: &'a [(OsString, OsString)],
    ) -> SessionSpec<'a> {
        SessionSpec {
            id: session,
            program: OsStr::new("/bin/sh"),
            argv0: None,
            args,
            env,
            cwd: None,
            columns: 80,
            rows: 24,
        }
    }

    /// Everything the session sent to its attached client.
    ///
    /// Tests read through this rather than off the pty, because the pty has exactly one reader now
    /// — the session's own — and a test competing with it for bytes would make both flaky.
    #[derive(Clone, Default)]
    struct Capture(Arc<Mutex<Vec<u8>>>);

    impl Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().expect("capture").extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl Capture {
        fn text(&self) -> String {
            String::from_utf8_lossy(&self.0.lock().expect("capture")).into_owned()
        }
    }

    /// Attaches a capturing client, returning it and the attachment's token.
    fn attach_capture(store: &SessionStore, session: SessionId) -> (Capture, u64) {
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (_, token) = store.attach(session, writer, 1).expect("attach");
        (capture, token)
    }

    /// Polls a capture until the needle shows up. The bytes carry envelope and frame headers
    /// around the payload, and a substring search sees straight through them.
    fn wait_for(capture: &Capture, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        loop {
            let seen = capture.text();
            if seen.contains(needle) || Instant::now() >= deadline {
                return seen;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn creates_and_lists_a_session() {
        let store = SessionStore::new();
        let args = [OsString::from("-c"), OsString::from("sleep 2")];
        let e = env();
        store.create(spec(id(1), &args, &e)).expect("create");

        let listed = store.list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, id(1));
        // Created, but nobody is holding it yet: the session exists and its pty is already being
        // drained, and a client becomes attached only by attaching.
        assert!(!listed[0].attached);

        let (_client, _) = attach_capture(&store, id(1));
        assert!(store.list()[0].attached);
        store.kill_all();
    }

    #[test]
    fn refuses_a_duplicate_id() {
        let store = SessionStore::new();
        let args = [OsString::from("-c"), OsString::from("sleep 2")];
        let e = env();
        store.create(spec(id(2), &args, &e)).expect("create");
        assert!(matches!(
            store.create(spec(id(2), &args, &e)),
            Err(SessionError::AlreadyExists(_))
        ));
        store.kill_all();
    }

    /// The property the whole feature exists for: a client going away must not take the shell
    /// with it, and coming back must find the same one still running.
    #[test]
    fn a_session_survives_detach_and_reattach() {
        let store = SessionStore::new();
        let args = [
            OsString::from("-c"),
            OsString::from("echo ready; sleep 5; echo done"),
        ];
        let e = env();
        store.create(spec(id(3), &args, &e)).expect("create");
        let (first, token) = attach_capture(&store, id(3));
        let before = wait_for(&first, "ready", Duration::from_secs(5));
        assert!(before.contains("ready"), "got {before:?}");

        let pid_before = store.with_pty(id(3), |pty| pty.child_pid()).expect("pty");
        store.detach(id(3), token);
        assert!(store.contains(id(3)), "detaching must not end the session");
        assert!(!store.list()[0].attached);

        std::thread::sleep(Duration::from_millis(300));

        let (_second, _) = attach_capture(&store, id(3));
        assert!(store.list()[0].attached);
        let pid_after = store.with_pty(id(3), |pty| pty.child_pid()).expect("pty");
        assert_eq!(
            pid_before, pid_after,
            "must be the SAME shell, not a new one"
        );
        store.kill_all();
    }

    /// A sentinel typed before the detach must still reach the shell that comes back — the
    /// integration property the design doc names for Phase 1.
    #[test]
    fn input_survives_a_detach() {
        let store = SessionStore::new();
        let args = [
            OsString::from("-c"),
            OsString::from("read line; sleep 1; echo got:$line; sleep 5"),
        ];
        let e = env();
        store.create(spec(id(4), &args, &e)).expect("create");
        let (_first, token) = attach_capture(&store, id(4));
        std::thread::sleep(Duration::from_millis(200));

        store
            .with_pty(id(4), |pty| pty.write_all(b"sentinel\n"))
            .expect("session")
            .expect("write");
        store.detach(id(4), token);
        std::thread::sleep(Duration::from_millis(400));
        let (second, _) = attach_capture(&store, id(4));

        let after = wait_for(&second, "got:sentinel", Duration::from_secs(5));
        assert!(after.contains("got:sentinel"), "got {after:?}");
        store.kill_all();
    }

    /// A zero size means "the client has no size yet", and the pty and the shadow must resolve it
    /// the same way. They did not: the pty substituted 80x24 while the shadow clamped to 1x1, so a
    /// repaint came back with one character per line. Anything that applies its own fallback to
    /// this input reintroduces that.
    #[test]
    fn a_zero_size_resolves_to_one_default_for_everything() {
        let store = SessionStore::new();
        let args = [OsString::from("-c"), OsString::from("stty size; sleep 2")];
        let e = env();
        store
            .create(SessionSpec {
                id: id(6),
                program: OsStr::new("/bin/sh"),
                argv0: None,
                args: &args,
                env: &e,
                cwd: None,
                columns: 0,
                rows: 0,
            })
            .expect("create");

        let (capture, _) = attach_capture(&store, id(6));
        let seen = wait_for(&capture, "24 80", Duration::from_secs(5));
        assert!(
            seen.contains("24 80"),
            "the pty did not get the default size: {seen:?}"
        );
        store.kill_all();
    }

    #[test]
    fn attaching_an_unknown_session_is_an_error() {
        let store = SessionStore::new();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(Capture::default())));
        assert!(matches!(
            store.attach(id(9), writer, 1),
            Err(SessionError::NotFound(_))
        ));
    }

    #[test]
    fn kill_removes_the_session_and_reaps_the_child() {
        let store = SessionStore::new();
        let args = [OsString::from("-c"), OsString::from("sleep 30")];
        let e = env();
        store.create(spec(id(5), &args, &e)).expect("create");
        let pid = store.with_pty(id(5), |pty| pty.child_pid()).expect("pty");

        assert!(store.kill(id(5)));
        assert!(!store.contains(id(5)));
        assert!(!store.kill(id(5)), "killing twice reports nothing to kill");

        // The child must be gone, not a zombie: signal 0 probes for existence.
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1, "child should be reaped");
    }

    #[test]
    fn kill_all_reports_how_many_it_ended() {
        let store = SessionStore::new();
        let args = [OsString::from("-c"), OsString::from("sleep 30")];
        let e = env();
        for n in 10..13 {
            store.create(spec(id(n), &args, &e)).expect("create");
        }
        assert_eq!(store.kill_all(), 3);
        assert!(store.is_empty());
    }

    #[test]
    fn session_ids_render_as_uuids() {
        let bytes = [
            0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44,
            0x00, 0x00,
        ];
        assert_eq!(
            SessionId(bytes).to_hyphenated(),
            "550e8400-e29b-41d4-a716-446655440000"
        );
    }

    #[test]
    fn session_ids_must_be_exactly_sixteen_bytes() {
        assert!(SessionId::from_slice(&[0u8; 16]).is_some());
        assert!(SessionId::from_slice(&[0u8; 15]).is_none());
        assert!(SessionId::from_slice(&[0u8; 17]).is_none());
    }

    #[test]
    fn listing_is_stable_between_calls() {
        let store = SessionStore::new();
        let args = [OsString::from("-c"), OsString::from("sleep 5")];
        let e = env();
        for n in [7u8, 3, 9, 1] {
            store.create(spec(id(n), &args, &e)).expect("create");
        }
        let first: Vec<SessionId> = store.list().into_iter().map(|i| i.id).collect();
        let second: Vec<SessionId> = store.list().into_iter().map(|i| i.id).collect();
        assert_eq!(first, second);
        assert_eq!(first, vec![id(1), id(3), id(7), id(9)]);
        store.kill_all();
    }
}
