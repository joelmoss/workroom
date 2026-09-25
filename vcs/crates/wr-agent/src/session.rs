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
use std::time::{Duration, Instant};

use crate::input::InputClassifier;
use crate::protocol::envelope::{Envelope, Service};
use crate::protocol::frame::{Frame, FrameKind};
use crate::pty::{Pty, PtyError};
use crate::shadow::Shadow;
use crate::transport::WRITE_TIMEOUT;

/// A connection's write half, shared with whichever session it is attached to.
///
/// Boxed because the reader below holds it for the session's life and must not be generic over the
/// transport — a session outlives the connection that created it, and the next one may arrive over
/// a different kind of stream entirely.
pub type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;

/// One attached client.
struct Client {
    writer: SharedWriter,
    stream: u32,
    /// Distinguishes THIS attachment from a later one on the same session. Without it a client
    /// whose connection ends after being superseded detaches the client that replaced it.
    token: u64,
    /// The size this client last advertised. Recorded whether or not it is applied — that is what
    /// lets a client that claims ownership later have its size take effect at once.
    columns: u16,
    rows: u16,
    /// Per-client, because it holds the tail of an unfinished escape sequence.
    classifier: InputClassifier,
}

impl Client {
    /// Whether this client is allowed to own the size. A client that has not advertised one yet
    /// cannot: a relay forked into a pipe rather than a terminal reports 0x0, and letting that own
    /// would resize every other viewer's pty to nothing.
    fn may_own(&self) -> bool {
        self.columns > 0 && self.rows > 0
    }
}

/// Every client attached to a session, and which of them the pty follows.
///
/// **The size-owner policy, from the design doc.** Two clients will not agree on a window size and
/// last-write-wins makes the pty thrash, so exactly one of them owns it at a time. Ownership is
/// claimed by ACTING — typing, or clicking — never by merely attaching, resizing in the background,
/// or having a terminal answer a query. See `crate::input`.
#[derive(Default)]
struct Attached {
    clients: Vec<Client>,
    /// The token of the client whose size the pty follows, if any.
    owner: Option<u64>,
}

impl Attached {
    fn client(&mut self, token: u64) -> Option<&mut Client> {
        self.clients.iter_mut().find(|client| client.token == token)
    }

    /// The size the pty should be at, or none if nobody owns it.
    fn owned_size(&self) -> Option<(u16, u16)> {
        let owner = self.owner?;
        self.clients
            .iter()
            .find(|client| client.token == owner)
            .filter(|client| client.may_own())
            .map(|client| (client.columns, client.rows))
    }

    /// Gives `token` the size, if it is allowed to have it. Returns the size to apply.
    fn claim(&mut self, token: u64) -> Option<(u16, u16)> {
        let eligible = self.client(token).is_some_and(|client| client.may_own());
        if !eligible {
            return None;
        }
        self.owner = Some(token);
        self.owned_size()
    }
}

/// Hands out attachment tokens. Process-wide and monotonic; the value means nothing but "later".
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

/// The pty, the shadow and the attachments of one session — everything an operation needs, lifted
/// out of the store so no store lock is held while any of them is touched.
type SessionParts = (Arc<Pty>, Arc<Mutex<Shadow>>, Arc<Mutex<Attached>>);

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

/// One session as a hand-off carries it to the next program: what that program needs to adopt it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrozenSession {
    pub id: SessionId,
    pub pid: i32,
    /// The pty master's descriptor number in this process.
    pub master: i32,
    pub columns: u16,
    pub rows: u16,
    /// The screen as VT bytes (`Shadow::replay`), never a snapshot: two agent revisions share no
    /// snapshot format, and they do share VT.
    pub screen: Vec<u8>,
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
    /// Every attached client and the size owner among them. Shared with the reader, which
    /// forwards to all of them and to the shadow alone when there are none.
    attached: Arc<Mutex<Attached>>,
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
                .attached
                .lock()
                .map(|attached| !attached.clients.is_empty())
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
    /// The client could not take its repaint whole, so it was not attached at all.
    ///
    /// A PARTIAL repaint is worse than none: a chunk boundary can fall inside an escape sequence,
    /// so the client's parser is left mid-sequence and the next live output completes it as
    /// garbage. That is the exact failure the chunking comment cites as the reason not to
    /// truncate, and stopping early is truncating. Failing the attach instead means no half-painted
    /// pane and no client left registered on a writer that cannot keep up — the caller gets a
    /// `Failure` frame and can retry from a clean terminal.
    #[error("session {0} could not be repainted")]
    RepaintFailed(String),
    /// The OS could not start the session's reader thread, so the session was ended again at once.
    #[error("session {0} could not start: no thread for its output")]
    ReaderFailed(String),
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
            attached: Arc::new(Mutex::new(Attached::default())),
        };
        let info = session.info();
        let pty = Arc::clone(&session.pty);
        let shadow = Arc::clone(&session.shadow);
        let attached = Arc::clone(&session.attached);
        let store = Arc::clone(&self.sessions);
        sessions.insert(spec.id, session);
        // Drop the store lock before the reader starts, or its first `ended` removal deadlocks
        // against this very lock.
        drop(sessions);
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
            read_session(spec.id, pty, shadow, attached, store)
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
    fn parts(&self, id: SessionId) -> Option<SessionParts> {
        let sessions = self.sessions.lock().expect("session store poisoned");
        let session = sessions.get(&id)?;
        Some((
            Arc::clone(&session.pty),
            Arc::clone(&session.shadow),
            Arc::clone(&session.attached),
        ))
    }

    /// Attaches a client and repaints it. Other clients keep their attachment.
    ///
    /// The repaint is written HERE, under the attachment lock, rather than by the caller after this
    /// returns. That ordering is the point: the reader takes the same lock around every write, so a
    /// repaint cannot be overtaken by output that arrives between registering and painting, and
    /// cannot duplicate output the shadow has already absorbed.
    ///
    /// `columns`/`rows` are what this client's window is; zero means it has none yet. A brand new
    /// session is unowned, so the first client to advertise a size takes it — otherwise a session
    /// would sit at its creation geometry until somebody typed.
    ///
    /// Returns the session's info and the attachment's token — hand that token back to `detach`.
    pub fn attach(
        &self,
        id: SessionId,
        writer: SharedWriter,
        stream: u32,
        columns: u16,
        rows: u16,
    ) -> Result<(SessionInfo, u64), SessionError> {
        let (pty, shadow, attached) = self
            .parts(id)
            .ok_or_else(|| SessionError::NotFound(id.to_hyphenated()))?;

        let token = NEXT_TOKEN.fetch_add(1, Ordering::SeqCst);
        // Whether the repaint reached the client WHOLE. A client that only got part of one is not
        // registered below — see `SessionError::RepaintFailed`.
        let mut painted = true;
        let size = {
            let mut attached = attached.lock().expect("attachment lock poisoned");
            let replay = shadow.lock().map(|s| s.replay()).unwrap_or_default();
            if !replay.is_empty() {
                if let Ok(mut writer) = writer.lock() {
                    // CHUNKED, because `replay()` has no size bound and `Frame::encode` PANICS
                    // above the 1 MiB cap rather than truncating.
                    //
                    // A repaint is two full screens — `primary_screen()` plus the active one, each
                    // with per-cell SGR runs, palette, modes and tabstops — so a large window
                    // showing a heavily-styled TUI crosses the cap. The panic would unwind out of
                    // here still holding this guard, poisoning the mutex; `read_session` then hits
                    // its own `.expect` on the next chunk and dies, so the pty is never drained
                    // again and the shell blocks on write. One oversized repaint would take the
                    // whole session down for every client on it, permanently.
                    //
                    // Chunking rather than truncating: terminal output is a byte stream, the live
                    // path already delivers it in arbitrary `READ_CHUNK`-sized pieces, and the
                    // envelope codec is explicitly built to survive a stream that chunks
                    // arbitrarily. A truncated repaint would instead leave the client's parser
                    // mid-sequence with the continuation record never arriving.
                    // ONE budget for the whole repaint, not one timeout per chunk.
                    //
                    // These writes happen under the attachment lock, which the reader takes around
                    // every delivery — so while this runs, the pty is not drained for ANY client
                    // on the session. Holding it is deliberate (the ordering note above) but it
                    // has to be BOUNDED, and `SO_SNDTIMEO` bounds a single `write`, not a loop of
                    // them: a peer reading just slowly enough that each chunk succeeds just under
                    // the limit would hold the lock for chunks × timeout. Chunking is what made
                    // that reachable, so the bound lands with it.
                    //
                    // A client too slow to take its own repaint inside the budget is not attached
                    // at all — see `SessionError::RepaintFailed`. The budget is enforced BETWEEN
                    // chunks, so a single `write_all` already in progress can overshoot it by up to
                    // one `WRITE_TIMEOUT`; bounding that too would mean a non-blocking writer, and
                    // one chunk of overshoot is the same bound the unchunked version had.
                    //
                    // Removing the lock-hold entirely, as the live path does, needs a per-client
                    // pending queue: releasing it here reverses the repaint against output that
                    // arrives mid-paint, and painting before registering misses that output
                    // instead. Bounded, not eliminated.
                    // The budget SCALES with the payload, and that is not a detail.
                    //
                    // `WRITE_TIMEOUT` means "the peer made no progress for this long" everywhere
                    // else — `FdStream::write` resets it per call. Reusing it as a flat wall-clock
                    // budget for the whole repaint turned it into a THROUGHPUT FLOOR: a peer that
                    // is healthy and reading continuously, but slower than `replay.len()` per ten
                    // seconds, failed deterministically. On the stated remote transport (`serve
                    // --stdio` over ssh) with a large styled screen that is a real link, and the
                    // penalty is not slowness but a permanently unattachable session, since every
                    // retry repeats it.
                    //
                    // So: `WRITE_TIMEOUT` of slack, plus the time the payload needs at a floor
                    // throughput. Still bounded — that is what keeps the lock hold finite — but the
                    // bound is one a working peer cannot trip.
                    let deadline = Instant::now() + repaint_budget(replay.len());
                    for chunk in replay.chunks(READ_CHUNK) {
                        if Instant::now() >= deadline {
                            painted = false;
                            break;
                        }
                        let bytes = terminal_envelope(
                            stream,
                            Frame::new(FrameKind::Output, chunk.to_vec()),
                        );
                        if writer
                            .write_all(&bytes)
                            .and_then(|()| writer.flush())
                            .is_err()
                        {
                            painted = false;
                            break;
                        }
                    }
                    // A partial repaint is bytes the client has ALREADY rendered, mid-escape-
                    // sequence at an arbitrary chunk boundary. Failing the attach stops it
                    // receiving more, but it does not un-draw what arrived — the comment on
                    // `RepaintFailed` used to claim otherwise, and that claim was simply wrong.
                    //
                    // RIS puts the terminal back to a known state, so the pane the caller falls
                    // back to starts clean instead of inheriting a half-parsed escape. Best
                    // effort: if this write fails too, the peer is gone and there is nothing left
                    // to reset.
                    if !painted {
                        let reset = terminal_envelope(
                            stream,
                            Frame::new(FrameKind::Output, b"\x1bc".to_vec()),
                        );
                        let _ = writer.write_all(&reset).and_then(|()| writer.flush());
                    }
                } else {
                    // The writer's lock is poisoned: nothing was painted, so do not register.
                    painted = false;
                }
            }
            if painted {
                attached.clients.push(Client {
                    writer,
                    stream,
                    token,
                    columns,
                    rows,
                    classifier: InputClassifier::new(),
                });
                // Attaching does not TAKE the size from a client that has it — that needs an act.
                // It only fills a vacancy.
                match attached.owner {
                    Some(_) => None,
                    None => attached.claim(token),
                }
            } else {
                // Not registered, so it owns no size and receives no live output. The caller turns
                // this into a `Failure` frame.
                None
            }
        };
        // Checked after the lock is released, so the early `return None` above leaves nothing
        // registered and nothing half-owned.
        if !painted {
            return Err(SessionError::RepaintFailed(id.to_hyphenated()));
        }
        apply_size(&pty, &shadow, size);

        let sessions = self.sessions.lock().expect("session store poisoned");
        let session = sessions
            .get(&id)
            .ok_or_else(|| SessionError::NotFound(id.to_hyphenated()))?;
        Ok((session.info(), token))
    }

    /// The client went away. The session and its pty keep running — that is the entire point, and
    /// the reader keeps draining the pty so a detached job neither stalls nor goes unrecorded.
    ///
    /// Only removes the client holding `token`: a superseded client's connection ending must not
    /// detach the client that superseded it.
    ///
    /// **If exactly one client is left, it takes the size immediately** rather than waiting to be
    /// claimed. Closing one laptop must not strand the terminal at the geometry of the window that
    /// just went away.
    pub fn detach(&self, id: SessionId, token: u64) {
        let Some((pty, shadow, attached)) = self.parts(id) else {
            return;
        };
        let size = {
            let mut attached = attached.lock().expect("attachment lock poisoned");
            attached.clients.retain(|client| client.token != token);
            if attached.owner == Some(token) {
                attached.owner = None;
            }
            match attached.clients.as_slice() {
                [only] => {
                    let last = only.token;
                    attached.claim(last)
                }
                _ => None,
            }
        };
        apply_size(&pty, &shadow, size);
    }

    /// A client's window changed size.
    ///
    /// Always recorded, applied only if that client owns the size or nobody does. A background
    /// window resizing must not move the pty out from under the person typing in another one.
    pub fn resize(&self, id: SessionId, token: u64, columns: u16, rows: u16) {
        let Some((pty, shadow, attached)) = self.parts(id) else {
            return;
        };
        let size = {
            let mut attached = attached.lock().expect("attachment lock poisoned");
            let Some(client) = attached.client(token) else {
                return;
            };
            client.columns = columns;
            client.rows = rows;
            match attached.owner {
                Some(owner) if owner == token => attached.owned_size(),
                Some(_) => None,
                None => attached.claim(token),
            }
        };
        apply_size(&pty, &shadow, size);
    }

    /// Input from a client: claims the size if it is the USER acting, then goes to the pty.
    ///
    /// Typing or clicking in a pane is what makes it yours. A terminal answering a query is not —
    /// see `crate::input` for why that distinction needs a parser.
    pub fn write_input(&self, id: SessionId, token: u64, bytes: &[u8]) {
        let Some((pty, shadow, attached)) = self.parts(id) else {
            return;
        };
        let (size, acted) = {
            let mut attached = attached.lock().expect("attachment lock poisoned");
            let acted = attached
                .client(token)
                .is_some_and(|client| client.classifier.is_user_input(bytes));
            let size = if acted && attached.owner != Some(token) {
                attached.claim(token)
            } else {
                None
            };
            (size, acted)
        };
        apply_size(&pty, &shadow, size);
        // The keystroke grace (OQ19's S5) needs the moment the user last ACTED, and this is the one
        // place input reaches a pty. Gated on the classifier above for the same reason the size
        // claim is: a TUI polling its terminal (cursor position, device attributes) writes to the
        // pty every few seconds with nobody there, and counting those would renew a 10 s grace
        // forever on a detached session.
        if acted {
            crate::wakefulness::count_pty_input();
        }
        let _ = pty.write_all(bytes);
    }

    /// Who owns the size, for tests and diagnostics.
    pub fn size_owner(&self, id: SessionId) -> Option<u64> {
        let (_, _, attached) = self.parts(id)?;
        let owner = attached.lock().ok()?.owner;
        owner
    }

    pub fn contains(&self, id: SessionId) -> bool {
        self.sessions
            .lock()
            .map(|s| s.contains_key(&id))
            .unwrap_or(false)
    }

    /// The pty children's pids and nothing else, for the wakefulness tick. `list()` resolves each
    /// session's foreground program with an ioctl and two `/proc` readlinks UNDER the store lock;
    /// paying that once a second, blocking every attach and keystroke meanwhile, for a field the
    /// classifier never reads would be the service's own cost dwarfing the sampler's. A poisoned
    /// lock is read through rather than panicked on: this runs on a thread nothing restarts.
    pub fn pids(&self) -> Vec<i32> {
        self.sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .map(|session| session.pty.child_pid())
            .collect()
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

    /// Runs `f` with every session's output stopped and its screen captured, for a hand-off.
    ///
    /// Holds the store lock, so no session is created or ended meanwhile, and then every session's
    /// attachment lock, which its reader takes around each read (`read_session`). So no byte leaves
    /// any pty while `f` runs, and every byte already read is in the screen `f` is given. `f` may
    /// replace the program. If it returns instead, the locks drop and every reader carries on with
    /// nothing lost.
    ///
    /// Store before attachment, the same order `Session::info` takes them in under `list`.
    pub fn frozen<T>(&self, f: impl FnOnce(&[FrozenSession]) -> T) -> T {
        let store = self.sessions.lock().expect("session store poisoned");
        let parts: Vec<(SessionId, SessionParts)> = store
            .values()
            .map(|session| {
                (
                    session.id,
                    (
                        Arc::clone(&session.pty),
                        Arc::clone(&session.shadow),
                        Arc::clone(&session.attached),
                    ),
                )
            })
            .collect();
        let held: Vec<_> = parts
            .iter()
            .map(|(_, (_, _, attached))| attached.lock().expect("attachment lock poisoned"))
            .collect();
        let sessions: Vec<FrozenSession> = parts
            .iter()
            .map(|(id, (pty, shadow, _))| {
                // The kernel's size, which is what the shell was last told.
                let (columns, rows) = pty
                    .size()
                    .unwrap_or((crate::pty::DEFAULT_COLUMNS, crate::pty::DEFAULT_ROWS));
                FrozenSession {
                    id: *id,
                    pid: pty.child_pid(),
                    master: pty.master_fd(),
                    columns,
                    rows,
                    screen: shadow.lock().map(|s| s.replay()).unwrap_or_default(),
                }
            })
            .collect();
        let result = f(&sessions);
        drop(held);
        drop(store);
        result
    }

    /// Takes over a session an earlier program in this process was running (`crate::handoff`):
    /// its pty, and a fresh shadow painted with the screen that program captured.
    ///
    /// No client comes with it, so nobody owns the size: the first client to attach with one takes
    /// it, as on a new session.
    pub fn adopt(
        &self,
        id: SessionId,
        pty: Pty,
        columns: u16,
        rows: u16,
        screen: &[u8],
    ) -> Result<(), SessionError> {
        let mut shadow = Shadow::new(columns, rows);
        shadow.write(screen);
        let session = Session {
            id,
            pty: Arc::new(pty),
            shadow: Arc::new(Mutex::new(shadow)),
            attached: Arc::new(Mutex::new(Attached::default())),
        };
        let pty = Arc::clone(&session.pty);
        let shadow = Arc::clone(&session.shadow);
        let attached = Arc::clone(&session.attached);
        let store = Arc::clone(&self.sessions);
        {
            let mut sessions = self.sessions.lock().expect("session store poisoned");
            if sessions.contains_key(&id) {
                return Err(SessionError::AlreadyExists(id.to_hyphenated()));
            }
            sessions.insert(id, session);
        }
        let spawned = std::thread::Builder::new()
            .spawn(move || read_session(id, pty, shadow, attached, store));
        if spawned.is_err() {
            self.kill(id);
            return Err(SessionError::ReaderFailed(id.to_hyphenated()));
        }
        Ok(())
    }

    /// Ends a session and its pty. Returns whether there was one to end.
    ///
    /// The session leaves the map first and the killing happens with the lock released: a
    /// termination now scans the process table and waits out a shell's exit traps, and holding the
    /// store lock across that would stall every `list` and `attach` for the duration.
    pub fn kill(&self, id: SessionId) -> bool {
        let session = self
            .sessions
            .lock()
            .expect("session store poisoned")
            .remove(&id);
        match session {
            Some(session) => {
                terminate(&[&session.pty]);
                true
            }
            None => false,
        }
    }

    /// One sweep for every session rather than a loop of single kills, so the process-table scan
    /// happens once and every shell gets its hangup at the same moment instead of each waiting out
    /// the one before it. That matters on quit, where this runs with the user watching.
    pub fn kill_all(&self) -> usize {
        let ending: Vec<Session> = {
            let mut sessions = self.sessions.lock().expect("session store poisoned");
            sessions.drain().map(|(_, session)| session).collect()
        };
        let ptys: Vec<&Arc<Pty>> = ending.iter().map(|session| &session.pty).collect();
        terminate(&ptys);
        ending.len()
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

/// Where the reader is sending output, captured so the write can happen outside the lock.
struct Target {
    writer: SharedWriter,
    stream: u32,
    token: u64,
}

impl Client {
    fn target(&self) -> Target {
        Target {
            writer: Arc::clone(&self.writer),
            stream: self.stream,
            token: self.token,
        }
    }
}

/// Every attached client, as detached copies.
fn targets(attached: &Arc<Mutex<Attached>>) -> Vec<Target> {
    match attached.lock() {
        Ok(attached) => attached.clients.iter().map(Client::target).collect(),
        Err(_) => Vec::new(),
    }
}

/// Writes to one client, and EVICTS it if the write fails.
///
/// Eviction is the point. A client that has stopped reading fails its write after the transport's
/// deadline, and leaving it installed means paying that deadline again on the very next chunk of
/// output — the session would spend its life stalling on a peer that is never coming back. Dropping
/// it costs nothing: the session and its pty carry on, and the client reattaches like any other.
///
/// Returns a size to apply if evicting left exactly one client, which then owns it — the same rule
/// `detach` follows, for the same reason: a peer that died must not strand the survivor at a
/// geometry belonging to a window nobody is looking at.
fn deliver(attached: &Arc<Mutex<Attached>>, target: &Target, bytes: &[u8]) -> Option<(u16, u16)> {
    let delivered = match target.writer.lock() {
        Ok(mut writer) => writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .is_ok(),
        Err(_) => false,
    };
    if delivered {
        return None;
    }
    let mut attached = attached.lock().ok()?;
    attached
        .clients
        .retain(|client| client.token != target.token);
    if attached.owner == Some(target.token) {
        attached.owner = None;
    }
    match attached.clients.as_slice() {
        [only] => {
            let last = only.token;
            attached.claim(last)
        }
        _ => None,
    }
}

/// Resizes the pty and the shadow together, if there is a size to apply.
///
/// The shadow has to follow the pty or a reattaching client is repainted at the wrong geometry and
/// every wrapped line is wrong.
fn apply_size(pty: &Pty, shadow: &Mutex<Shadow>, size: Option<(u16, u16)>) {
    let Some((columns, rows)) = size else {
        return;
    };
    let _ = pty.resize(columns, rows);
    if let Ok(mut shadow) = shadow.lock() {
        shadow.resize(columns, rows);
    }
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
/// How much output travels in one frame.
///
/// The pty reader's buffer, and also the repaint's chunk size in `attach` — both must stay under
/// the protocol's 1 MiB frame cap, which `Frame::encode` enforces with a panic rather than a
/// truncation. Sharing one constant means the two paths cannot drift apart.
const READ_CHUNK: usize = 8192;

/// The slowest a peer may take its repaint before the agent gives up on it, in bytes per second.
///
/// Only a floor, not a target: a local socket moves a megabyte in microseconds and an ssh hop in a
/// fraction of a second. It exists so the repaint's budget scales with the screen instead of being
/// a flat wall-clock limit, which made a healthy-but-slow peer permanently unattachable.
const REPAINT_MIN_THROUGHPUT: usize = 64 * 1024;

/// How long a client gets to accept a repaint of `bytes` before the agent gives up on it.
///
/// `WRITE_TIMEOUT` of slack plus the time the payload needs at `REPAINT_MIN_THROUGHPUT`. Pure and
/// named because the SCALING is the part that was wrong: a flat `WRITE_TIMEOUT` for the whole
/// repaint is a throughput floor, and a healthy peer slower than `replay.len()` per ten seconds
/// failed it deterministically — permanently, since every retry repeats it.
fn repaint_budget(bytes: usize) -> Duration {
    WRITE_TIMEOUT + Duration::from_secs((bytes / REPAINT_MIN_THROUGHPUT) as u64)
}

fn read_session(
    id: SessionId,
    pty: Arc<Pty>,
    shadow: Arc<Mutex<Shadow>>,
    attached: Arc<Mutex<Attached>>,
    store: Arc<Mutex<HashMap<SessionId, Session>>>,
) {
    let mut buffer = [0u8; READ_CHUNK];
    loop {
        // Read UNDER the attachment lock, and write to the shadow before releasing it. A byte
        // then leaves the pty only while this lock is held and is in the shadow by the time it is
        // released, so whoever holds every session's lock (`SessionStore::frozen`) holds a shadow
        // with every byte ever read and a pty with every byte not. A hand-off depends on exactly
        // that: a byte read and not yet shadowed when the program is replaced is a byte no client
        // ever sees. The read is non-blocking, so holding the lock across it costs nothing.
        //
        // The shadow absorbs the bytes and the destination is chosen under the same lock, as one
        // step — otherwise an attach landing between the two either misses output or replays it
        // twice. The transport write itself then happens with the lock RELEASED, and that
        // matters: holding it across a write would let one client that has stopped reading stall
        // the pty drain for every byte, which is the very problem this reader exists to prevent.
        //
        // Releasing early is still correct because the destination was captured first. A client
        // that attaches after the capture is painted from the shadow, which already holds these
        // bytes; it cannot receive them twice, and the superseded client's writer is the one this
        // write goes to.
        let (read, clients) = {
            let held = attached.lock().expect("attachment lock poisoned");
            let read = pty.read(&mut buffer);
            let clients = match read {
                Ok(n) if n > 0 => {
                    if let Ok(mut shadow) = shadow.lock() {
                        shadow.write(&buffer[..n]);
                    }
                    held.clients.iter().map(Client::target).collect::<Vec<_>>()
                }
                _ => Vec::new(),
            };
            (read, clients)
        };

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
            for target in targets(&attached) {
                let bytes = terminal_envelope(
                    target.stream,
                    // The code a shell would report, not the raw `waitpid` status: `exit 7` is 7
                    // here, not 1792. See `serve::exit_code`.
                    Frame::new(
                        FrameKind::Exited,
                        crate::serve::exit_code(status).to_be_bytes().to_vec(),
                    ),
                );
                deliver(&attached, &target, &bytes);
            }
            // The shell IS the session; with it gone there is nothing left to reattach to.
            if let Ok(mut store) = store.lock() {
                store.remove(&id);
            }
            return;
        }

        match read {
            Ok(n) => {
                // Counted here rather than at a client, because a DETACHED session's output is
                // exactly the case the wakefulness signal exists for: a busy box with nobody
                // watching.
                crate::wakefulness::count_pty_out(n);
                // Every attached client sees the same bytes — that is what makes two windows on
                // one session show the same terminal rather than half of it each.
                for target in &clients {
                    let bytes = terminal_envelope(
                        target.stream,
                        Frame::new(FrameKind::Output, buffer[..n].to_vec()),
                    );
                    let size = deliver(&attached, target, &bytes);
                    apply_size(&pty, &shadow, size);
                }
            }
            // `Interrupted` is not a failure — a signal arriving mid-read is ordinary, and the
            // agent takes SIGWINCH and SIGCHLD. Treated as fatal it ended the reader on a read
            // that had not actually failed.
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::Interrupted =>
            {
                std::thread::sleep(Duration::from_millis(5));
            }
            // A genuinely fatal read. The session goes with the reader: this was the one exit that
            // did not remove it from the store, so the entry outlived the only thread that drains
            // it — `list` still advertised it, `attach` still succeeded, and nothing read the pty
            // again, so the shell blocked on a full output queue. It also kept `sessions` non-empty
            // forever, so the agent never idled out.
            //
            // Torn down the same way the `ended` branch above does, because a client that is told
            // nothing keeps a pane that looks live over a session that no longer exists, and its
            // input then vanishes into a `parts(id)` that returns `None`. The child is terminated
            // too: closing the master alone hangs up the pty's foreground group and leaves exactly
            // the `setsid()` descendants `terminate`'s snapshot exists to reach.
            Err(_) => {
                for target in targets(&attached) {
                    let framed = terminal_envelope(
                        target.stream,
                        Frame::new(
                            FrameKind::Failure,
                            b"the session's pty could not be read".to_vec(),
                        ),
                    );
                    deliver(&attached, &target, &framed);
                }
                terminate(&[&pty]);
                if let Ok(mut store) = store.lock() {
                    store.remove(&id);
                }
                return;
            }
        }
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
/// `process::descendants`.
///
/// **The snapshot must be taken before anything is signalled.** Once the shell is hung up its
/// children start exiting, and a descendant that has already left the process table is one no
/// later sweep can find — it would be missed precisely in the common case where it exits slowly
/// enough to matter.
fn terminate(ptys: &[&Arc<Pty>]) {
    let roots: Vec<i32> = ptys
        .iter()
        .map(|pty| pty.child_pid())
        .filter(|pid| *pid > 0)
        .collect();
    if roots.is_empty() {
        return;
    }
    // Each descendant is recorded with its start time, not just its pid, because the SIGKILL
    // sweep below happens up to half a second later — long enough for one to exit and its number
    // to be reused. See `process::Descendant`.
    let descendants = crate::process::descendants(&roots);

    for pid in roots.iter().chain(descendants.iter().map(|d| &d.pid)) {
        unsafe { libc::kill(*pid, libc::SIGHUP) };
    }

    // Only the roots are our children, so only they can be reaped; a descendant's exit is observed
    // by probing instead. Both are checked, because the point is that nothing is left.
    let mut unreaped: Vec<i32> = roots.clone();
    for _ in 0..50 {
        unreaped.retain(|pid| {
            let mut status = 0;
            let rc = unsafe { libc::waitpid(*pid, &mut status, libc::WNOHANG) };
            rc == 0
        });
        if unreaped.is_empty() && !descendants.iter().any(|d| d.is_running()) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    // Half a second of SIGHUP was declined. Anything still running gets SIGKILL — and `is_running`
    // is checked first, and compares start times, so a descendant that has exited cannot cost an
    // unrelated process that inherited its pid a SIGKILL.
    let survivors = descendants
        .iter()
        .filter(|d| d.is_running())
        .map(|d| &d.pid);
    for pid in unreaped.iter().chain(survivors) {
        unsafe { libc::kill(*pid, libc::SIGKILL) };
    }
    for pid in &unreaped {
        let mut status = 0;
        unsafe { libc::waitpid(*pid, &mut status, 0) };
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
        let (_, token) = store.attach(session, writer, 1, 80, 24).expect("attach");
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
    fn a_command_that_writes_before_registration_still_delivers_output_and_exit() {
        let store = SessionStore::new();
        let args = [
            OsString::from("-c"),
            OsString::from("echo EARLY-OUTPUT; exit 7"),
        ];
        let e = env();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        store
            .create_then(spec(id(80), &args, &e), |info| {
                // Wait for pending output without consuming it. Waiting for child exit instead
                // deadlocks on macOS, where PTY close can wait for the output to be drained.
                let (pty, _, _) = store.parts(info.id).expect("new session");
                let mut descriptor = libc::pollfd {
                    fd: pty.master_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                let deadline = Instant::now() + Duration::from_secs(5);
                loop {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    assert!(!remaining.is_zero(), "command produced no output");
                    let ready = unsafe {
                        libc::poll(&mut descriptor, 1, remaining.as_millis() as libc::c_int)
                    };
                    if ready < 0
                        && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
                    {
                        continue;
                    }
                    assert!(ready > 0, "command produced no output");
                    break;
                }
                assert_ne!(descriptor.revents & libc::POLLIN, 0, "no pending output");
                store.attach(id(80), writer, 1, 80, 24)
            })
            .expect("create and attach");
        let deadline = Instant::now() + Duration::from_secs(5);
        while store.contains(id(80)) {
            assert!(Instant::now() < deadline, "exited session was not removed");
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(capture.text().contains("EARLY-OUTPUT"));
        let exit = terminal_envelope(
            1,
            Frame::new(FrameKind::Exited, 7i32.to_be_bytes().to_vec()),
        );
        assert!(
            capture.0.lock().unwrap().ends_with(&exit),
            "missing final exit frame"
        );
    }

    #[test]
    fn failed_initial_registration_still_drains_and_retires_the_session() {
        let store = SessionStore::new();
        // More than the PTY buffer: without a reader this child cannot finish.
        let args = [
            OsString::from("-c"),
            OsString::from("head -c 131072 /dev/zero"),
        ];
        let e = env();
        let result: Result<(), SessionError> = store.create_then(spec(id(81), &args, &e), |_| {
            Err(SessionError::RepaintFailed(id(81).to_hyphenated()))
        });
        assert!(matches!(result, Err(SessionError::RepaintFailed(_))));
        let deadline = Instant::now() + Duration::from_secs(5);
        while store.contains(id(81)) {
            assert!(
                Instant::now() < deadline,
                "failed attach stranded its session"
            );
            std::thread::sleep(Duration::from_millis(5));
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

    /// A client whose transport has failed must be dropped, not kept and retried forever.
    ///
    /// Left installed, every subsequent chunk of output pays the transport's write deadline again,
    /// and the session spends its life stalling on a peer that is never coming back — which is the
    /// same "nobody is draining the pty" failure the session-owned reader exists to prevent,
    /// arriving through a different door.
    #[test]
    fn a_client_that_cannot_be_written_to_is_dropped() {
        let store = SessionStore::new();
        // Output must keep coming AFTER the writer breaks: a single echo raced the break, and a
        // fast shell printed it into the healthy writer and then said nothing for five seconds.
        let args = [
            OsString::from("-c"),
            OsString::from("while :; do echo noisy; sleep 0.1; done"),
        ];
        let e = env();
        store.create(spec(id(7), &args, &e)).expect("create");

        // Healthy at attach, broken afterwards — which is what this test is actually about, and
        // what it only accidentally exercised before. It used to attach an ALREADY-broken writer,
        // so with `terminal-state` on it depended on whether the shell had produced output yet: an
        // empty shadow meant no repaint and the attach succeeded, a painted one meant the repaint
        // write failed. That race is now a real distinction — a writer that is dead before the
        // repaint fails the attach outright (`an_unpaintable_client_is_not_attached`), so eviction
        // has to be provoked the way it actually happens, after a working attach.
        let broken = Arc::new(std::sync::atomic::AtomicBool::new(false));
        struct Flaky(Arc<std::sync::atomic::AtomicBool>);
        impl Write for Flaky {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if self.0.load(Ordering::SeqCst) {
                    return Err(std::io::ErrorKind::BrokenPipe.into());
                }
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                if self.0.load(Ordering::SeqCst) {
                    return Err(std::io::ErrorKind::BrokenPipe.into());
                }
                Ok(())
            }
        }

        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(Flaky(Arc::clone(&broken)))));
        store.attach(id(7), writer, 1, 80, 24).expect("attach");
        assert!(store.list()[0].attached);
        broken.store(true, Ordering::SeqCst);

        // The shell's own output is enough to discover the dead transport.
        let deadline = Instant::now() + Duration::from_secs(5);
        while store.list()[0].attached && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            !store.list()[0].attached,
            "a client whose writes fail must be evicted"
        );
        assert!(
            store.contains(id(7)),
            "and the session itself must survive losing its client"
        );
        store.kill_all();
    }

    // MARK: The size-owner policy

    /// Reports the pty's actual geometry, which is what the policy is ultimately about.
    fn pty_size(store: &SessionStore, session: SessionId) -> (u16, u16) {
        store
            .with_pty(session, |pty| pty.size())
            .expect("session")
            .expect("size")
    }

    fn attach_sized(
        store: &SessionStore,
        session: SessionId,
        columns: u16,
        rows: u16,
    ) -> (Capture, u64) {
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (_, token) = store
            .attach(session, writer, 1, columns, rows)
            .expect("attach");
        (capture, token)
    }

    fn sized_session(store: &SessionStore, session: SessionId) {
        let args = [OsString::from("-c"), OsString::from("sleep 30")];
        let e = env();
        store
            .create(SessionSpec {
                id: session,
                program: OsStr::new("/bin/sh"),
                argv0: None,
                args: &args,
                env: &e,
                cwd: None,
                columns: 80,
                rows: 24,
            })
            .expect("create");
    }

    /// Nobody owns a new session, so the first client to bring a size takes it — otherwise a
    /// session would sit at its creation geometry until somebody typed.
    #[test]
    fn the_first_client_with_a_size_takes_it() {
        let store = SessionStore::new();
        sized_session(&store, id(20));
        let (_client, token) = attach_sized(&store, id(20), 100, 30);
        assert_eq!(store.size_owner(id(20)), Some(token));
        assert_eq!(pty_size(&store, id(20)), (100, 30));
        store.kill_all();
    }

    /// A client with no size of its own cannot own one. A relay forked into a pipe rather than a
    /// terminal reports 0x0, and letting that own would resize everyone else's pty to nothing.
    #[test]
    fn a_client_without_a_size_cannot_own_it() {
        let store = SessionStore::new();
        sized_session(&store, id(21));
        let (_client, _) = attach_sized(&store, id(21), 0, 0);
        assert_eq!(store.size_owner(id(21)), None);
        assert_eq!(
            pty_size(&store, id(21)),
            (80, 24),
            "the pty keeps its own size"
        );
        store.kill_all();
    }

    /// The core of the policy: a second client's window does not move the pty.
    #[test]
    fn a_second_clients_resize_is_recorded_but_not_applied() {
        let store = SessionStore::new();
        sized_session(&store, id(22));
        let (_first, first) = attach_sized(&store, id(22), 100, 30);
        let (_second, second) = attach_sized(&store, id(22), 120, 40);

        assert_eq!(
            store.size_owner(id(22)),
            Some(first),
            "attaching does not take the size"
        );
        assert_eq!(pty_size(&store, id(22)), (100, 30));

        store.resize(id(22), second, 200, 50);
        assert_eq!(
            pty_size(&store, id(22)),
            (100, 30),
            "a non-owner's resize does not apply"
        );
        assert_eq!(store.size_owner(id(22)), Some(first));
        store.kill_all();
    }

    /// ...and typing is what takes it, applying the size recorded while it was not the owner.
    #[test]
    fn typing_claims_the_size_and_applies_what_was_recorded() {
        let store = SessionStore::new();
        sized_session(&store, id(23));
        let (_first, first) = attach_sized(&store, id(23), 100, 30);
        let (_second, second) = attach_sized(&store, id(23), 120, 40);
        store.resize(id(23), second, 200, 50);

        store.write_input(id(23), second, b"x");
        assert_eq!(store.size_owner(id(23)), Some(second));
        assert_eq!(
            pty_size(&store, id(23)),
            (200, 50),
            "the size recorded while it was not the owner takes effect at once"
        );
        assert_ne!(store.size_owner(id(23)), Some(first));
        store.kill_all();
    }

    /// The load-bearing exclusion. A terminal answering a query shares the input channel with the
    /// user, and a pane merely being focused must not steal the size.
    #[test]
    fn a_terminal_answering_a_query_does_not_claim_the_size() {
        let store = SessionStore::new();
        sized_session(&store, id(24));
        let (_first, first) = attach_sized(&store, id(24), 100, 30);
        let (_second, second) = attach_sized(&store, id(24), 120, 40);

        for answer in [
            &b"\x1b[I"[..],          // focus in
            &b"\x1b[24;80R"[..],     // cursor position report
            &b"\x1b[?62;1;4c"[..],   // device attributes
            &b"\x1b[<64;10;20M"[..], // wheel scroll
        ] {
            store.write_input(id(24), second, answer);
            assert_eq!(
                store.size_owner(id(24)),
                Some(first),
                "{answer:?} must not claim the session"
            );
        }

        // But a click does.
        store.write_input(id(24), second, b"\x1b[<0;10;20M");
        assert_eq!(
            store.size_owner(id(24)),
            Some(second),
            "a click is the user acting"
        );
        store.kill_all();
    }

    /// Closing one laptop must not strand the terminal at the geometry of the window that just
    /// went away — with one client left, it takes the size without having to ask.
    #[test]
    fn the_last_client_standing_takes_the_size_immediately() {
        let store = SessionStore::new();
        sized_session(&store, id(25));
        let (_first, first) = attach_sized(&store, id(25), 100, 30);
        let (_second, second) = attach_sized(&store, id(25), 120, 40);
        assert_eq!(store.size_owner(id(25)), Some(first));

        store.detach(id(25), first);
        assert_eq!(store.size_owner(id(25)), Some(second));
        assert_eq!(pty_size(&store, id(25)), (120, 40));
        store.kill_all();
    }

    /// With more than one client left, the owner leaving makes the size UNOWNED rather than
    /// handing it to an arbitrary survivor — the next one to act takes it.
    #[test]
    fn the_size_is_unowned_when_the_owner_leaves_a_crowd() {
        let store = SessionStore::new();
        sized_session(&store, id(26));
        let (_first, first) = attach_sized(&store, id(26), 100, 30);
        let (_second, second) = attach_sized(&store, id(26), 120, 40);
        let (_third, third) = attach_sized(&store, id(26), 140, 45);

        store.detach(id(26), first);
        assert_eq!(store.size_owner(id(26)), None);
        assert_eq!(
            pty_size(&store, id(26)),
            (100, 30),
            "and the pty holds its last size"
        );

        store.write_input(id(26), third, b"x");
        assert_eq!(store.size_owner(id(26)), Some(third));
        assert_eq!(pty_size(&store, id(26)), (140, 45));
        assert_ne!(store.size_owner(id(26)), Some(second));
        store.kill_all();
    }

    /// An unowned size is claimed by a resize too, not only by typing — otherwise a lone client
    /// that only ever drags its window would never move the pty.
    #[test]
    fn a_resize_claims_an_unowned_size() {
        let store = SessionStore::new();
        sized_session(&store, id(27));
        let (_first, first) = attach_sized(&store, id(27), 100, 30);
        let (_second, second) = attach_sized(&store, id(27), 0, 0);
        let (_third, _) = attach_sized(&store, id(27), 0, 0);
        store.detach(id(27), first);
        assert_eq!(store.size_owner(id(27)), None);

        store.resize(id(27), second, 90, 20);
        assert_eq!(store.size_owner(id(27)), Some(second));
        assert_eq!(pty_size(&store, id(27)), (90, 20));
        store.kill_all();
    }

    /// The owner's own resizes keep applying, which is the ordinary single-client case.
    #[test]
    fn the_owner_keeps_resizing_the_pty() {
        let store = SessionStore::new();
        sized_session(&store, id(28));
        let (_client, token) = attach_sized(&store, id(28), 100, 30);
        store.resize(id(28), token, 132, 43);
        assert_eq!(pty_size(&store, id(28)), (132, 43));
        store.kill_all();
    }

    /// Both windows on one session see the same output — otherwise they would each get half a
    /// terminal, which is the corruption multi-client attach used to cause.
    #[test]
    fn every_attached_client_sees_the_same_output() {
        let store = SessionStore::new();
        let args = [
            OsString::from("-c"),
            OsString::from("sleep 0.2; echo shared; sleep 5"),
        ];
        let e = env();
        store.create(spec(id(29), &args, &e)).expect("create");
        let (first, _) = attach_capture(&store, id(29));
        let (second, _) = attach_capture(&store, id(29));

        assert!(wait_for(&first, "shared", Duration::from_secs(5)).contains("shared"));
        assert!(wait_for(&second, "shared", Duration::from_secs(5)).contains("shared"));
        store.kill_all();
    }

    #[test]
    fn attaching_an_unknown_session_is_an_error() {
        let store = SessionStore::new();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(Capture::default())));
        assert!(matches!(
            store.attach(id(9), writer, 1, 80, 24),
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

    /// The reason `terminate` snapshots descendants. A child that calls `setsid()` leaves the
    /// pty's foreground process group and the shell's session both, so hanging up the pty reaches
    /// everything EXCEPT it — and the app quitting used to leave it running forever.
    ///
    /// Uses a real detached grandchild rather than a simulation, and observes its pid from outside
    /// the session, because the escape is a property of the OS and a stand-in would not have it.
    #[test]
    fn kill_reaches_a_setsid_grandchild() {
        let Some(perl) = which("perl") else {
            eprintln!("skipping: no perl to make a setsid'd grandchild with");
            return;
        };
        let pid_file = std::env::temp_dir().join(format!("wr-setsid-{}.pid", std::process::id()));
        let _ = std::fs::remove_file(&pid_file);

        let script = format!(
            "{perl} -MPOSIX=setsid -e 'setsid(); open(F, \">\", $ARGV[0]) or exit 1; \
             print F $$; close F; while (1) {{ sleep 1 }}' {} & exec cat",
            pid_file.display()
        );
        let args = [OsString::from("-c"), OsString::from(script)];
        let e = env();
        let store = SessionStore::new();
        store.create(spec(id(30), &args, &e)).expect("create");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut grandchild = 0;
        while Instant::now() < deadline {
            if let Some(pid) = std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|raw| raw.trim().parse::<i32>().ok())
            {
                grandchild = pid;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = std::fs::remove_file(&pid_file);
        assert!(grandchild > 0, "the setsid'd grandchild never started");
        assert!(alive(grandchild), "it should be running before the kill");

        assert!(store.kill(id(30)));

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && alive(grandchild) {
            std::thread::sleep(Duration::from_millis(20));
        }
        let survived = alive(grandchild);
        if survived {
            unsafe { libc::kill(grandchild, libc::SIGKILL) };
        }
        assert!(!survived, "a setsid'd grandchild must not survive the kill");
    }

    /// Whether a pid names a running process. Test-only: the kill path itself compares start
    /// times through `process::Descendant`, which this deliberately does not — a test that watched
    /// for pid reuse would be testing the OS, not the agent.
    fn alive(pid: i32) -> bool {
        pid > 0 && unsafe { libc::kill(pid, 0) } == 0
    }

    fn which(program: &str) -> Option<String> {
        std::env::var("PATH").ok().and_then(|path| {
            path.split(':')
                .map(|dir| std::path::Path::new(dir).join(program))
                .find(|candidate| candidate.is_file())
                .and_then(|candidate| candidate.to_str().map(str::to_string))
        })
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

    /// An oversized repaint must not take the session down.
    ///
    /// `replay()` has no size bound and `Frame::encode` PANICS above the 1 MiB cap. `attach`
    /// builds that frame while holding the attachment mutex, so before chunking, one big window
    /// showing a styled TUI poisoned the mutex on unwind — and `read_session`'s own `.expect` on
    /// the same lock then killed the reader thread, leaving the pty undrained and the shell
    /// blocked on write for EVERY client on that session, permanently.
    ///
    /// The shadow is painted directly rather than through the pty: the fixture has to reliably
    /// exceed a megabyte, and driving a real shell to emit that much styled output is slow and
    /// load-dependent. `terminal::tests::a_repaint_can_exceed_the_frame_cap` pins that this size
    /// is reachable from real output.
    ///
    /// Asserting the reader is still ALIVE afterwards is the point — a test that only checked
    /// `attach` returned `Ok` would pass against a version that poisoned the lock, because the
    /// poisoning kills the reader rather than the attacher.
    #[cfg(feature = "terminal-state")]
    #[test]
    fn an_oversized_repaint_does_not_wedge_the_session() {
        let store = SessionStore::new();
        let args = [
            OsString::from("-c"),
            OsString::from("sleep 0.3; echo still-draining; sleep 5"),
        ];
        let e = env();
        let mut spec = spec(id(71), &args, &e);
        spec.columns = 400;
        spec.rows = 200;
        store.create(spec).expect("create");

        // Paint the shadow past the frame cap: an SGR run per cell, so nothing coalesces.
        let (_, shadow, _) = store.parts(id(71)).expect("parts");
        {
            let mut shadow = shadow.lock().expect("shadow");
            let mut paint = Vec::new();
            for row in 0..200u32 {
                for column in 0..400u32 {
                    let colour = ((row * 400 + column) % 255) + 1;
                    paint.extend_from_slice(format!("\x1b[38;5;{colour}mX").as_bytes());
                }
                if row < 199 {
                    paint.extend_from_slice(b"\r\n");
                }
            }
            shadow.write(&paint);
            assert!(
                shadow.replay().len() > crate::protocol::frame::MAX_PAYLOAD_SIZE,
                "fixture no longer exceeds the cap, so this proves nothing"
            );
        }

        let replay_len = shadow.lock().expect("shadow").replay().len();
        let (capture, _) = attach_capture(&store, id(71));

        // The WHOLE repaint arrived, not just its first chunk. Liveness alone is not enough: a
        // `replay.chunks(..).take(1)` would leave every other assertion here green while sending
        // 8 KiB of a megabyte screen — and that truncation is exactly the regression this pair of
        // commits has already shipped once.
        assert!(
            capture.text().len() >= replay_len,
            "client got {} bytes of a {replay_len}-byte repaint",
            capture.text().len()
        );

        // The reader is still running: output produced AFTER the repaint still arrives. This is
        // what fails when the attachment mutex has been poisoned.
        assert!(
            wait_for(&capture, "still-draining", Duration::from_secs(5)).contains("still-draining"),
            "the pty stopped draining after the repaint — the session is wedged"
        );
        store.kill_all();
    }

    /// A client whose transport is already dead is NOT attached, rather than attached and later
    /// evicted.
    ///
    /// A partial repaint is worse than none: an 8 KiB chunk boundary can fall inside an escape
    /// sequence, so a client that got a prefix has its parser stranded mid-sequence and the next
    /// live output completes it as garbage. That is the same reason the repaint chunks instead of
    /// truncating, so stopping early has to fail the attach rather than register a half-painted
    /// pane.
    ///
    /// Needs a NON-EMPTY shadow, or there is no repaint to fail on and the attach legitimately
    /// succeeds — which is why the eviction test above had to stop using an already-broken writer.
    #[cfg(feature = "terminal-state")]
    #[test]
    fn an_unpaintable_client_is_not_attached() {
        struct Broken;
        impl Write for Broken {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
        }

        let store = SessionStore::new();
        let args = [OsString::from("-c"), OsString::from("sleep 5")];
        let e = env();
        store.create(spec(id(73), &args, &e)).expect("create");
        let (_, shadow, _) = store.parts(id(73)).expect("parts");
        shadow
            .lock()
            .expect("shadow")
            .write(b"something to repaint\r\n");

        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(Broken)));
        let result = store.attach(id(73), writer, 1, 80, 24);

        assert!(
            matches!(result, Err(SessionError::RepaintFailed(_))),
            "a client that cannot take its repaint must not be attached, got {result:?}"
        );
        assert!(
            !store.list()[0].attached,
            "nothing may be left registered for a client that was never painted"
        );
        assert!(store.contains(id(73)), "the session itself survives");
        store.kill_all();
    }

    /// The budget SCALES with the payload — the part that was wrong, and the cheap part to pin.
    ///
    /// A flat `WRITE_TIMEOUT` for the whole repaint is a throughput floor: a peer reading happily
    /// but slower than `replay.len()` per ten seconds failed every time, and every retry repeated
    /// it, so the session became permanently unattachable. These assertions fail against that.
    #[test]
    fn the_repaint_budget_scales_with_the_screen() {
        assert_eq!(
            repaint_budget(0),
            WRITE_TIMEOUT,
            "an empty repaint still gets the no-progress slack"
        );
        assert!(
            repaint_budget(4 * 1024 * 1024) > repaint_budget(64 * 1024),
            "a bigger screen must get longer, or the budget is a throughput floor"
        );
        // A megabyte — the size `a_repaint_can_exceed_the_frame_cap` proves is reachable — must get
        // meaningfully more than the flat slack, or a slow link cannot ever finish it.
        assert!(
            repaint_budget(1024 * 1024) >= WRITE_TIMEOUT + Duration::from_secs(16),
            "a 1 MiB screen got {:?}, which a modest link cannot meet",
            repaint_budget(1024 * 1024)
        );
    }
}
