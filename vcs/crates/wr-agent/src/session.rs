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
use std::sync::{Arc, Mutex};

use crate::pty::{Pty, PtyError};
use crate::shadow::Shadow;

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
    pub attached: bool,
    /// The foreground command, resolved at read time rather than stored — a session's foreground
    /// process changes without the agent being told, so a cached value is wrong more often than
    /// it is right.
    pub foreground: Option<String>,
    pub cwd: Option<String>,
}

pub struct Session {
    pub id: SessionId,
    pty: Pty,
    /// The emulator shadowing this session's screen, so a client that attaches later can be shown
    /// what is on it. Behind its own lock rather than the store's: the output pump writes to it on
    /// every read, and holding the whole store for that would serialise every session's output
    /// behind every other session's.
    shadow: Arc<Mutex<Shadow>>,
    /// Whether a client currently holds this session. The daemon detaches the previous client on
    /// a new attach (`SessionDaemon.swift` does the same), so this is single-client by
    /// construction; the size-owner policy the design doc describes is what generalises it.
    attached: bool,
}

impl Session {
    pub fn pty(&self) -> &Pty {
        &self.pty
    }

    pub fn info(&self) -> SessionInfo {
        let foreground = self.pty.foreground_pgid();
        SessionInfo {
            id: self.id,
            attached: self.attached,
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
        let pty = Pty::spawn(
            spec.program,
            spec.args,
            spec.env,
            spec.cwd,
            spec.columns,
            spec.rows,
        )?;
        let session = Session {
            id: spec.id,
            pty,
            shadow: Arc::new(Mutex::new(Shadow::new(spec.columns, spec.rows))),
            attached: true,
        };
        let info = session.info();
        sessions.insert(spec.id, session);
        Ok(info)
    }

    /// Marks a session attached, detaching whichever client held it. Returns the session's info.
    pub fn attach(&self, id: SessionId) -> Result<SessionInfo, SessionError> {
        let mut sessions = self.sessions.lock().expect("session store poisoned");
        let session = sessions
            .get_mut(&id)
            .ok_or_else(|| SessionError::NotFound(id.to_hyphenated()))?;
        session.attached = true;
        Ok(session.info())
    }

    /// The client went away. The session and its pty keep running — that is the entire point.
    pub fn detach(&self, id: SessionId) {
        if let Ok(mut sessions) = self.sessions.lock() {
            if let Some(session) = sessions.get_mut(&id) {
                session.attached = false;
            }
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
            args,
            env,
            cwd: None,
            columns: 80,
            rows: 24,
        }
    }

    fn read_until(
        store: &SessionStore,
        session: SessionId,
        needle: &str,
        timeout: Duration,
    ) -> String {
        let deadline = Instant::now() + timeout;
        let mut seen = String::new();
        let mut buffer = [0u8; 4096];
        while Instant::now() < deadline {
            let read = store.with_pty(session, |pty| pty.read(&mut buffer));
            match read {
                Some(Ok(0)) | None => break,
                Some(Ok(n)) => {
                    seen.push_str(&String::from_utf8_lossy(&buffer[..n]));
                    if seen.contains(needle) {
                        break;
                    }
                }
                Some(Err(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Some(Err(_)) => break,
            }
        }
        seen
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
        assert!(listed[0].attached);
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
        let before = read_until(&store, id(3), "ready", Duration::from_secs(5));
        assert!(before.contains("ready"), "got {before:?}");

        let pid_before = store.with_pty(id(3), |pty| pty.child_pid()).expect("pty");
        store.detach(id(3));
        assert!(store.contains(id(3)), "detaching must not end the session");
        assert!(!store.list()[0].attached);

        std::thread::sleep(Duration::from_millis(300));

        let info = store.attach(id(3)).expect("reattach");
        assert!(info.attached);
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
            OsString::from("read line; sleep 0.3; echo got:$line"),
        ];
        let e = env();
        store.create(spec(id(4), &args, &e)).expect("create");
        std::thread::sleep(Duration::from_millis(200));

        store
            .with_pty(id(4), |pty| pty.write(b"sentinel\n"))
            .expect("session")
            .expect("write");
        store.detach(id(4));
        std::thread::sleep(Duration::from_millis(400));
        store.attach(id(4)).expect("reattach");

        let after = read_until(&store, id(4), "got:sentinel", Duration::from_secs(5));
        assert!(after.contains("got:sentinel"), "got {after:?}");
        store.kill_all();
    }

    #[test]
    fn attaching_an_unknown_session_is_an_error() {
        let store = SessionStore::new();
        assert!(matches!(
            store.attach(id(9)),
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
