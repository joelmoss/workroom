//! Sessions: a pty plus the identity a client reattaches by.
//!
//! **Identity is client-minted**, as it already is today — `TerminalSessions.swift` stores a
//! 16-byte UUID per pane and hands it over on attach. The daemon does not invent ids; it only
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
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::daemon::rpc::SharedWriter;
use crate::terminal::images::Transfer;
use crate::terminal::input::InputClassifier;
use crate::terminal::program_status::{Hub, Store};
use crate::terminal::pty::{Pty, PtyError, Size};
use crate::terminal::screens::Screens;
use crate::terminal::shadow::Shadow;
use crate::util::{lock_or_recover, recover};

mod attached;
mod freeze;
mod reader;
mod refusals;
mod store;
mod terminate;

pub(crate) use freeze::{HANDOFF_FORMAT_DEADLINE, HANDOFF_IMAGE_DEADLINE};
pub use reader::READ_CHUNK;
pub use refusals::refusals_path;
pub use terminate::KILL_EXIT_WAIT;

/// A `waitpid` status as the exit code a shell would report, which is what the `Exited` frame
/// carries.
///
/// The raw status is not that number: it packs the exit code into its high byte, so `exit 7`
/// arrives as 1792. Both ends of this wire already agree on the shell convention —
/// `SessionDaemon.exitCode` produces it and `SessionAttachClient` returns it as its own exit
/// status — so sending the raw value would make the same frame mean a different number depending
/// on which backend served the session, and a caller checking `$? == 7` would silently never
/// match.
pub fn exit_code(status: i32) -> i32 {
    // The low seven bits are the terminating signal, 0 when the process exited normally.
    let signal = status & 0o177;
    if signal == 0 {
        return (status >> 8) & 0xFF;
    }
    // 0o177 means stopped rather than terminated — not an exit at all, so report success rather
    // than inventing a failure for a process that is still there.
    if signal == 0o177 {
        return 0;
    }
    128 + signal
}

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
    /// The pixels of that size, zero if the client did not say.
    pixels: (u16, u16),
    /// Per-client, because it holds the tail of an unfinished escape sequence.
    classifier: InputClassifier,
    /// Its images on their way after a repaint, if it has any. Only the reader sends them.
    transfer: Option<Arc<Transfer>>,
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
/// or having a terminal answer a query. See `crate::terminal::input`.
#[derive(Default)]
struct Attached {
    clients: Vec<Client>,
    /// The token of the client whose size the pty follows, if any.
    owner: Option<u64>,
    /// Whether the screen changed since its record was last taken (`changed_screens`): set by the
    /// reader on output and by `apply_size` on a resize, so an idle session is not rewritten to
    /// disk every tick. Here, under the lock both of them already take.
    changed: bool,
}

impl Attached {
    /// A new session's: nobody attached yet, and a screen no record has been taken of.
    fn unrecorded() -> Attached {
        Attached {
            changed: true,
            ..Attached::default()
        }
    }

    fn client(&mut self, token: u64) -> Option<&mut Client> {
        self.clients.iter_mut().find(|client| client.token == token)
    }

    /// The size the pty should be at, or none if nobody owns it.
    fn owned_size(&self) -> Option<Size> {
        let owner = self.owner?;
        self.clients
            .iter()
            .find(|client| client.token == owner)
            .filter(|client| client.may_own())
            .map(|client| Size {
                columns: client.columns,
                rows: client.rows,
                x_pixels: client.pixels.0,
                y_pixels: client.pixels.1,
            })
    }

    /// Gives `token` the size, if it is allowed to have it. Returns the size to apply.
    fn claim(&mut self, token: u64) -> Option<Size> {
        let eligible = self.client(token).is_some_and(|client| client.may_own());
        if !eligible {
            return None;
        }
        self.owner = Some(token);
        self.owned_size()
    }
}

/// Where the reader is sending output, captured so the write can happen outside the lock.
struct Target {
    writer: SharedWriter,
    stream: u32,
    token: u64,
    /// Where this client's output takes an `images::ABORT`, when its transfer has just been
    /// stopped part way through a load.
    abort_at: Option<usize>,
}

/// Hands out attachment tokens. Process-wide and monotonic; the value means nothing but "later".
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

/// Numbers every session this process holds, so two sessions under one id are never mistaken for
/// each other (`SessionStore::still_holds`). A pointer would not do: the allocator reuses a freed
/// session's address for the next one.
static NEXT_SESSION: AtomicU64 = AtomicU64::new(1);

/// Held for reading while a session that has left the store is still being ended (`terminate`),
/// and for writing by a hand-off (`SessionStore::frozen`). A termination runs outside the store
/// lock, so without this an exec could land in its grace period: the SIGKILL sweep would never
/// run, and a descendant that ignores SIGHUP would outlive its session.
static TERMINATING: std::sync::RwLock<()> = std::sync::RwLock::new(());

/// The pty, the shadow and the attachments of one session — everything an operation needs, lifted
/// out of the store so no store lock is held while any of them is touched.
type SessionParts = (Arc<Pty>, Arc<Mutex<Shadow>>, Arc<Mutex<Attached>>);

/// What a client said about a session (`Session::metadata`), as key and value pairs.
type Metadata = Vec<(String, String)>;

/// The metadata key for when a session was created, in milliseconds since the epoch, which orders
/// sessions the app's layout does not name (#255). A hand-off carries it, so it never resets.
pub const CREATED_KEY: &str = "created";

/// The client-minted session id, as the wire carries it.
pub use wr_protocol::terminal::SessionId;

/// One session as a hand-off carries it to the next program: what that program needs to adopt it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrozenSession {
    pub id: SessionId,
    pub pid: i32,
    /// The pty master's descriptor number in this process.
    pub master: i32,
    pub columns: u16,
    pub rows: u16,
    /// The screen as VT bytes, as an attaching client is shown it (`Shadow::replay_for`), never a
    /// snapshot: two daemon revisions share no snapshot format, and they do share VT.
    pub screen: Vec<u8>,
    /// The session's metadata (`Session::metadata`), so its workroom survives the hand-off.
    pub metadata: Vec<(String, String)>,
    /// Its program status records (#358): the screen's VT carries none, and a record still
    /// waiting on the user must not vanish because the daemon was replaced.
    pub program_status: Store,
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
    /// process changes without the daemon being told, so a cached value is wrong more often than
    /// it is right.
    pub foreground: Option<String>,
    pub cwd: Option<String>,
    /// The foreground program's Claude profile (`CLAUDE_CONFIG_DIR`), read at the same time and
    /// for the same reason as `foreground`; the app uses it to tell which Claude account a pane
    /// runs (#480).
    pub claude_profile: Option<String>,
    /// What the client said about the session when it created it (`Session::metadata`).
    pub metadata: Vec<(String, String)>,
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
    /// This session's number, from `NEXT_SESSION`.
    number: u64,
    /// Which workroom the session belongs to, its first title, and when it was created, as the
    /// client that created it said (`dispatch::session_metadata`), plus `created` from here. Only
    /// the `workroom` key ever changes after creation, by a `Retag` frame
    /// (`SessionStore::set_workroom`): the app's own layout is what follows a renamed tab (#255).
    metadata: Vec<(String, String)>,
    /// `SessionSpec::interactive`.
    interactive: bool,
}

impl Session {
    pub fn info(&self) -> SessionInfo {
        let foreground = self.pty.foreground_pgid();
        let name = foreground.and_then(crate::terminal::process::executable_name);
        SessionInfo {
            id: self.id,
            pid: self.pty.child_pid(),
            attached: !lock_or_recover(&self.attached).clients.is_empty(),
            cwd: foreground.and_then(crate::terminal::process::working_directory),
            // Only `claude`'s environment is read: no other program's is anyone's business. Anything
            // not confirmed as `claude` reports no profile, so the app never guesses an account.
            claude_profile: foreground
                .filter(|_| name.as_deref() == Some("claude"))
                .map(|pid| crate::terminal::process::claude_profile(pid).unwrap_or_default()),
            foreground: name,
            metadata: self.metadata.clone(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("session {0} already exists")]
    AlreadyExists(String),
    #[error("no session {0}")]
    NotFound(String),
    /// A client asked for this id to be killed a moment ago, so it is not started again: see
    /// `SessionStore::refuse`.
    #[error("session {0} was ended and is not started again")]
    Ended(String),
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

/// Why `SessionStore::signal_run` sent nothing.
#[derive(Debug)]
pub enum RunSignalError {
    NotFound,
    NotARun,
    Failed(std::io::Error),
}

/// A session's screen as `SessionStore::changed_screens` takes it, for its record.
pub struct TakenScreen {
    pub id: SessionId,
    /// Which session under `id` this was, for `SessionStore::still_holds`.
    pub session: u64,
    pub columns: u16,
    pub rows: u16,
    pub record: Vec<u8>,
}

/// Owns every live session. Cheap to clone; all clones share one map.
///
/// # Lock order
///
/// Every lock the terminal code takes, and the one order they nest in: a lock is taken only while
/// holding locks above it on its own branch, never one below it or on another branch. Check an
/// edit that takes a lock against this before anything else.
///
/// ```text
/// Subscriber.queue          a program-status subscription being set up (`Connection::subscribe`)
/// ├─ Hub.subscribers        registering it
/// ├─ Hub.boot
/// └─ (the store map, then each shadow on its own: the snapshot, `program_status_events`)
///
/// TERMINATING               read: `kill`, `kill_all`, `end_if_absent` and a reader's end, through
/// │                         their SIGHUP grace; write: a hand-off's freeze (`frozen_formatting`)
/// ├─ ending                 a second kill waiting for the first, and `Ending` as it drops
/// ├─ runs_wake              a reader's end raising it
/// └─ sessions               the store map
///    ├─ refused             `create_then` checks it; `refuse` takes it alone
///    ├─ ending              `mark_ending` as sessions leave the map, `is_ending`
///    ├─ runs_wake           `signal_run`
///    └─ attached            per session: `list` (`Session::info`), the end of `attach`, the freeze
///       ├─ shadow           per session: `attach`'s repaint, `apply_size`, `send_images`, a read
///       │  ├─ Hub.boot      a status event built under it (a read, `change_program_status`)
///       │  └─ Transfer      a client's image queues: `send_images` taking the next chunk
///       ├─ Transfer         a read stopping a client's transfer
///       ├─ encoders         the image encoders' sender: `attach` starting a transfer
///       ├─ writer           a connection's writer: `attach`'s repaint
///       └─ screens_work     raised on output and on a resize
/// ```
///
/// Taken alone, under nothing and with nothing under them: `Hub.subscribers` and each
/// `Subscriber.queue` as a publish takes them (`Hub::publish` copies the list first, and publishes
/// only with every session lock released); a `Transfer` as an encoder looks at it and finishes; a shadow as an encoder copies its pixels, and as `compress_shadows` and
/// `promote_unprobed` visit each one after releasing the map. The store map is released before a
/// reader starts (`create_then`), and before `changed_screens` takes any session's attachment lock.
/// The forward, layout, watch and rpc locks never nest with these.
///
/// # Poisoned locks
///
/// Every one of these is recovered when a panic poisoned it, through `util::lock_or_recover` (owner
/// decision D5): nothing under them is left half-changed in a way a later holder could misread, and
/// a panic under one must not stop a session draining. None is an exception. The one exception in
/// the daemon is a connection's writer, which every service treats as a closed connection once
/// poisoned: a panic while it was held can leave part of an envelope on the stream, and a frame
/// written after it would be misread by the peer's decoder.
#[derive(Clone, Default)]
pub struct SessionStore {
    sessions: Arc<Mutex<HashMap<SessionId, Session>>>,
    /// Where each session's screen is kept for after a reboot, when the daemon was asked to keep
    /// them (`serve --screens`). See `crate::terminal::screens`.
    screens: Arc<OnceLock<Screens>>,
    /// Kills still running on threads of their own (`serve`'s Kill), whose sessions have already
    /// left the map. See `is_killing`.
    kills_in_flight: Arc<AtomicUsize>,
    /// Sessions out of the map whose shells `kill` or `kill_all` is still ending. A second kill of
    /// one waits on the first, so neither returns before the shell is gone. See `Ending`. Counted,
    /// so a session created again under an id still being ended, and killed, is not unmarked when
    /// the first kill finishes.
    ending: Arc<(Mutex<HashMap<SessionId, usize>>, Condvar)>,
    /// Ids a client asked to kill, and when each refusal ends, which `create_then` refuses until
    /// then (#297). Only ever locked alone or inside the session map's lock, never the other way
    /// round.
    refused: Arc<Mutex<HashMap<SessionId, Instant>>>,
    /// Where `refused` is kept for the next program to serve this socket, when this one serves
    /// one (`keep_refusals`).
    refusals: Arc<OnceLock<PathBuf>>,
    /// Publishes each session's program status to subscribed connections (#358).
    program_status: Arc<Hub>,
    /// Where run sessions keep their status files (`crate::terminal::run`), when this store serves
    /// a socket (`keep_runs`). A store without one refuses run sessions.
    runs: Arc<OnceLock<PathBuf>>,
    /// Raised when a run session is created or signalled: what the runs watcher
    /// (`crate::terminal::run`) sleeps on while no run session has a status left to publish.
    runs_wake: Arc<Wake>,
    /// Raised when a screen may have changed or a session has gone (output, a resize,
    /// `mark_changed`, the reader's end): what the screens thread (`crate::terminal::screens`)
    /// sleeps on instead of ticking every two seconds of an idle daemon.
    screens_work: Arc<Wake>,
}

/// A counted signal. `wait_past` a count read by `seen` returns once `raise` has moved it, so a
/// raise between the read and the wait is never missed.
#[derive(Default)]
struct Wake {
    count: Mutex<u64>,
    raised: Condvar,
}

impl Wake {
    fn seen(&self) -> u64 {
        *lock_or_recover(&self.count)
    }

    fn raise(&self) {
        *lock_or_recover(&self.count) += 1;
        self.raised.notify_all();
    }

    fn wait_past(&self, seen: u64) {
        let mut count = lock_or_recover(&self.count);
        while *count == seen {
            count = recover(self.raised.wait(count));
        }
    }
}

/// Sessions marked as being ended in `SessionStore::ending` until dropped, panics included.
struct Ending<'a> {
    store: &'a SessionStore,
    ids: Vec<SessionId>,
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
    /// The client's metadata for the session (`Session::metadata`); `created` is added here.
    pub metadata: &'a [(String, String)],
    /// The program is an interactive shell, not a run command: a report it sends itself is never
    /// a program waiting on the user (#481).
    pub interactive: bool,
}

/// Tries `attempt` until it gives a value or `deadline` passes.
fn until<T>(deadline: Instant, mut attempt: impl FnMut() -> Option<T>) -> Option<T> {
    loop {
        if let Some(value) = attempt() {
            return Some(value);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(test)]
mod tests;
