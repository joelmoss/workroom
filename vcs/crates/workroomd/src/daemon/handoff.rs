//! Hand-off: replacing a running daemon's program with another binary, keeping every session
//! (#230; design doc, "Resume policy versus version lockstep").
//!
//! **The program is replaced in place, with `execve`, never by a second process.** A pty master is
//! only a descriptor, and passing it to a separate process would keep the shell alive and orphan
//! it: `waitpid` only works for a child's parent, so every session would lose its exit code. After
//! `execve` the pid is the same, so the new program is still every shell's parent.
//!
//! What crosses the exec:
//! - **Descriptors**, with close-on-exec cleared on duplicates made for the purpose: every pty
//!   master, the listening socket (so the socket is never unbound and a client that connects
//!   meanwhile waits in the backlog), and the single-instance lock file (a `flock` belongs to the
//!   open file description, so it is never released). Everything else closes, which is every
//!   client connection: a client reattaches to the new program.
//! - **A table** in a file beside the socket, named by `--handoff`: the descriptor numbers, and per
//!   session its id, pid, size, screen and metadata. A file, not a pipe: this process is the pipe's only
//!   reader, and a table bigger than the pipe's buffer (16 KiB on macOS; a few screens) would block
//!   the write forever.
//! - **The screen as VT bytes**, as an attaching client is shown it (`Shadow::replay_for`), never
//!   a snapshot. Two daemon revisions share no
//!   snapshot format; they do share VT. The new program feeds the bytes to a fresh terminal of the
//!   same size, so its fidelity is exactly a reattaching client's, including the one-row
//!   scrollback offset that re-synthesis costs (`vt.rs`). That row is lost at each hand-off.
//!
//! **It checks first and refuses rather than kills.** Before the exec, the new binary is run once
//! as `handoff-check <table>`, which reads the real table and paints every screen. That proves it
//! starts on this host and can restore these sessions. A binary that predates hand-off has no such
//! command, so a downgrade keeps the newer daemon running. Any failure before the exec, including
//! the exec itself, leaves this program running with nothing lost.
//!
//! **What cannot be recovered** is a binary that passes the check and then fails while it
//! restores. Its descriptors close when it dies: every shell is hung up and the socket stops
//! answering, so the next client starts a fresh daemon. `tests/hand_off.rs` does this on purpose and
//! records exactly that.

use std::ffi::{CString, OsString};
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::terminal::session::{FrozenSession, SessionId, SessionStore};

/// Why a hand-off did not happen, or why a table could not be read. The text is what the
/// requester is shown (a `Failure` frame, truncated to `MAX_REASON`) and what `handoff-check`
/// prints, so each message is part of what a user sees.
#[derive(Debug, thiserror::Error)]
pub enum HandOffError {
    #[error("not a hand-off table")]
    NotATable,
    #[error("hand-off table version {0} is not supported")]
    TableVersion(u16),
    #[error("hand-off table metadata is not UTF-8")]
    MetadataNotUtf8,
    #[error("hand-off table program status cannot be read")]
    ProgramStatus,
    #[error("hand-off table has trailing bytes")]
    TrailingBytes,
    #[error("hand-off table is truncated")]
    Truncated,
    #[error("this daemon serves one connection and has nothing to hand off")]
    NothingToHandOff,
    #[error("{} is not an absolute path", .0.display())]
    NotAbsolute(PathBuf),
    #[error("cannot read {}: not a regular file", .0.display())]
    NotAFile(PathBuf),
    #[error("cannot read {}: {source}", path.display())]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("another hand-off is in progress")]
    InProgress,
    #[error(
        "a repository command, or a send typing into a session, is still running; try again when \
         it finishes"
    )]
    RepositoryBusy,
    #[error("a filesystem operation is still stuck on a mount; try again when it returns")]
    FilesystemStuck,
    #[error("a session is being ended; try again when it finishes")]
    SessionEnding,
    #[error("a session is being ended or repainted; try again when it finishes")]
    SessionsBusy,
    #[error("could not duplicate descriptor {fd}: {source}")]
    Duplicate { fd: RawFd, source: std::io::Error },
    #[error("could not write {}: {source}", path.display())]
    WriteTable {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("{} could not start: {source}", binary.display())]
    Start {
        binary: PathBuf,
        source: std::io::Error,
    },
    #[error("{} did not say its build within {}s", .0.display(), CHECK_TIMEOUT.as_secs())]
    BuildLate(PathBuf),
    #[error("{} is build {theirs}, older than this daemon's build {ours}", binary.display())]
    Older {
        binary: PathBuf,
        theirs: u64,
        ours: u64,
    },
    #[error("{} did not check the sessions within {}s", .0.display(), CHECK_TIMEOUT.as_secs())]
    CheckLate(PathBuf),
    /// `stderr` is the check's own output, trimmed.
    #[error("{} cannot restore these sessions ({status}): {stderr}", binary.display())]
    CannotRestore {
        binary: PathBuf,
        status: ExitStatus,
        stderr: String,
    },
    #[error("the binary's path contains a NUL")]
    BinaryNul,
    #[error("an argument contains a NUL")]
    ArgumentNul,
    #[error("the table path has a NUL")]
    TablePathNul,
    #[error("the requester stopped waiting, so nothing was replaced")]
    RequesterGone,
    #[error("{} could not be executed: {source}", binary.display())]
    Exec {
        binary: PathBuf,
        source: std::io::Error,
    },
    #[error("this build cannot restore screens (built without terminal-state)")]
    NoTerminalState,
}

const MAGIC: [u8; 4] = *b"WRHO";
/// The table's format. The new program must read the old one's table, so a change here needs the
/// reader to keep accepting every version a shipped daemon writes: version 1 had no metadata, and its
/// sessions are adopted with none (#255); versions 1 and 2 had no program status, and theirs are
/// adopted with empty records under a new boot (#358). An older program refuses a newer table in
/// its check, so a hand-off never goes to a program that would drop what this one carries.
/// `a_version_3_table_from_the_shipped_daemon_is_adopted_with_its_program_status` holds the shipped
/// table: a field added to `program_status::Store` or `Record` needs a serde default, or a new
/// version here with 3 still accepted. Version 4 adds the terminal API's events (#687) after the
/// sessions; a table before it carries none, and the next program numbers its events under a boot
/// of its own, which is safe because no program that writes one has ever served the events, so
/// no client holds a place in them.
/// Version 5 adds each session's recipe (#693) after its program status, as length-prefixed JSON,
/// empty for none; a table before it carries none, and `session.new` from such a session builds
/// from the daemon's own environment.
/// Version 6 adds each session's resume state (ADR 0082) after its recipe, as length-prefixed
/// JSON, empty for none: its token, which its shell keeps, its records and its stream offset. A
/// table before it comes from a program that gave no session a token, so its sessions have none
/// and accept no reports. The table is written `0600`, and removed once read (`take_table`) or
/// once a hand-off fails (`replace`).
const TABLE_VERSION: u16 = 6;
/// The oldest table this program still reads.
const OLDEST_TABLE_VERSION: u16 = 1;
/// How long the new binary gets to check the table. Every session's output is stopped meanwhile
/// (a shell blocks once its pty buffer fills), so it is short; a healthy check takes milliseconds.
const CHECK_TIMEOUT: Duration = Duration::from_secs(3);
/// How long a program that has exited still gets for its `protocol` report to come through the
/// reader thread, past `CHECK_TIMEOUT` if need be. A check that used all its time otherwise left
/// a report the program had already given unread, and refused a build that did say it.
const REPORT_GRACE: Duration = Duration::from_millis(200);
/// How long a hand-off waits for running repository commands to finish before refusing. New ones
/// are refused meanwhile, so it is short too.
///
/// With the other waits below, inside the app's own wait (`DaemonHandOff.timeout`, 7 s): a
/// requester that gives up first calls the hand-off off, so a longer daemon-side wait would
/// only hold every repository request off for a hand-off that can no longer happen.
const QUIET_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a hand-off waits to stop every session (`SessionStore::frozen`) before refusing. Every
/// list and attach waits behind it meanwhile.
const FREEZE_TIMEOUT: Duration = Duration::from_millis(500);
/// How long a hand-off gives the programs whose paste a `terminal.send` left open (#689) to take
/// its end (`SessionStore::close_owed_pastes`). One that hasn't by then has read nothing for the
/// pty's write deadline and more, and its paste stays open in the next program, which owes it
/// nothing.
const PASTE_CLOSE_TIMEOUT: Duration = Duration::from_millis(100);
/// What encoding and writing the table may take (`replace`), before `CHECK_TIMEOUT` starts. The
/// table carries every session's screen, up to `HANDOFF_TOTAL_BYTES` (16 MiB) and more where a
/// screen alone is over its share.
const TABLE_WRITE_ALLOWANCE: Duration = Duration::from_millis(250);
/// `DaemonHandOff.timeout` in the app, which these waits must stay under. Checked at compile time,
/// so raising one past it fails the build rather than quietly defeating every busy hand-off.
///
/// The screens are captured within `HANDOFF_FORMAT_DEADLINE`, checked before each session and each
/// format, so one format can overrun it; what is left under this timeout covers that. The "handing
/// off" write after them is one small frame to a requester that is reading its answer, or has gone
/// and fails the write at once, so it is not counted.
const APP_TIMEOUT: Duration = Duration::from_secs(7);
const _: () = assert!(
    QUIET_TIMEOUT.as_millis()
        + PASTE_CLOSE_TIMEOUT.as_millis()
        + FREEZE_TIMEOUT.as_millis()
        + crate::terminal::session::HANDOFF_FORMAT_DEADLINE.as_millis()
        + crate::terminal::session::HANDOFF_IMAGE_DEADLINE.as_millis()
        + TABLE_WRITE_ALLOWANCE.as_millis()
        + CHECK_TIMEOUT.as_millis()
        + REPORT_GRACE.as_millis()
        < APP_TIMEOUT.as_millis()
);
/// How much of a refusal reaches the requester (`terminal::dispatch` truncates to it). The reason can quote
/// the requester's path and the check's stderr, and a frame over the protocol's cap is a panic in
/// `encode`, not a truncation.
pub(crate) const MAX_REASON: usize = 4096;
/// How much of the check's stderr a refusal repeats. The rest is drained and dropped.
const MAX_CHECK_STDERR: u64 = MAX_REASON as u64;

/// One hand-off at a time: a second would take the same slots and locks, and release them under
/// the first.
static IN_PROGRESS: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Set while a hand-off is under way, so `serve` stops accepting. A client that connects meanwhile
/// waits in the listener's backlog and is answered by whichever program comes out of it, where one
/// accepted now would be dropped at the exec.
static PAUSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether `serve` should accept connections now.
pub fn accepting() -> bool {
    !PAUSED.load(std::sync::atomic::Ordering::Acquire)
}

struct Paused;

impl Drop for Paused {
    fn drop(&mut self) {
        PAUSED.store(false, std::sync::atomic::Ordering::Release);
    }
}

/// What crosses the exec, apart from the descriptors themselves.
#[derive(Debug, PartialEq, Eq)]
pub struct Table {
    pub listener: RawFd,
    pub lock: RawFd,
    /// The session store's program status boot (#358); `None` from a table before version 3.
    pub boot: Option<SessionId>,
    pub sessions: Vec<FrozenSession>,
    /// The terminal API's events (`events::Hub::carry`), as JSON; `None` from a table before
    /// version 4.
    pub events: Option<Vec<u8>>,
}

impl Table {
    /// Big-endian, like the rest of the wire: magic, version, listener, lock, (from version 3) the
    /// boot, count, then per session id, pid, master, columns, rows, screen length and screen,
    /// (from version 2) its metadata as a count of length-prefixed key and value pairs, and (from
    /// version 3) its program status as length-prefixed JSON and (from version 5) its recipe as
    /// length-prefixed JSON, empty for none; then (from version 4) the events as length-prefixed
    /// JSON, empty for none.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = MAGIC.to_vec();
        out.extend_from_slice(&TABLE_VERSION.to_be_bytes());
        out.extend_from_slice(&self.listener.to_be_bytes());
        out.extend_from_slice(&self.lock.to_be_bytes());
        out.extend_from_slice(&self.boot.unwrap_or(SessionId([0; 16])).0);
        out.extend_from_slice(&(self.sessions.len() as u32).to_be_bytes());
        for session in &self.sessions {
            out.extend_from_slice(&session.id.0);
            out.extend_from_slice(&session.pid.to_be_bytes());
            out.extend_from_slice(&session.master.to_be_bytes());
            out.extend_from_slice(&session.columns.to_be_bytes());
            out.extend_from_slice(&session.rows.to_be_bytes());
            out.extend_from_slice(&(session.screen.len() as u32).to_be_bytes());
            out.extend_from_slice(&session.screen);
            out.extend_from_slice(&(session.metadata.len() as u32).to_be_bytes());
            for (key, value) in &session.metadata {
                for text in [key, value] {
                    out.extend_from_slice(&(text.len() as u32).to_be_bytes());
                    out.extend_from_slice(text.as_bytes());
                }
            }
            let status =
                serde_json::to_vec(&session.program_status).expect("program status serializes");
            out.extend_from_slice(&(status.len() as u32).to_be_bytes());
            out.extend_from_slice(&status);
            let recipe = session
                .recipe
                .as_ref()
                .map(|recipe| serde_json::to_vec(&recipe.to_json()).expect("a recipe serializes"))
                .unwrap_or_default();
            out.extend_from_slice(&(recipe.len() as u32).to_be_bytes());
            out.extend_from_slice(&recipe);
            let resume = session
                .resume
                .as_ref()
                .map(|resume| serde_json::to_vec(resume).expect("resume state serializes"))
                .unwrap_or_default();
            out.extend_from_slice(&(resume.len() as u32).to_be_bytes());
            out.extend_from_slice(&resume);
        }
        let events = self.events.as_deref().unwrap_or_default();
        out.extend_from_slice(&(events.len() as u32).to_be_bytes());
        out.extend_from_slice(events);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Table, HandOffError> {
        let mut reader = Reader(bytes);
        if reader.take(4)? != MAGIC {
            return Err(HandOffError::NotATable);
        }
        let version = u16::from_be_bytes(reader.array()?);
        if !(OLDEST_TABLE_VERSION..=TABLE_VERSION).contains(&version) {
            return Err(HandOffError::TableVersion(version));
        }
        let listener = i32::from_be_bytes(reader.array()?);
        let lock = i32::from_be_bytes(reader.array()?);
        let boot = if version >= 3 {
            Some(SessionId(reader.array()?))
        } else {
            None
        };
        let count = u32::from_be_bytes(reader.array()?);
        let mut sessions = Vec::new();
        for _ in 0..count {
            let id = SessionId(reader.array()?);
            let pid = i32::from_be_bytes(reader.array()?);
            let master = i32::from_be_bytes(reader.array()?);
            let columns = u16::from_be_bytes(reader.array()?);
            let rows = u16::from_be_bytes(reader.array()?);
            let length = u32::from_be_bytes(reader.array()?) as usize;
            let screen = reader.take(length)?.to_vec();
            let mut metadata = Vec::new();
            if version >= 2 {
                let entries = u32::from_be_bytes(reader.array()?);
                for _ in 0..entries {
                    let mut text = || -> Result<String, HandOffError> {
                        let length = u32::from_be_bytes(reader.array()?) as usize;
                        String::from_utf8(reader.take(length)?.to_vec())
                            .map_err(|_| HandOffError::MetadataNotUtf8)
                    };
                    let key = text()?;
                    let value = text()?;
                    metadata.push((key, value));
                }
            }
            let mut program_status = crate::terminal::program_status::Store::default();
            if version >= 3 {
                let length = u32::from_be_bytes(reader.array()?) as usize;
                program_status = serde_json::from_slice(reader.take(length)?)
                    .map_err(|_| HandOffError::ProgramStatus)?;
            }
            let mut recipe = None;
            if version >= 5 {
                let length = u32::from_be_bytes(reader.array()?) as usize;
                let bytes = reader.take(length)?;
                // A recipe that can't be read is none: the session is still adopted, and a `new`
                // from it builds from the daemon's own environment.
                recipe = (!bytes.is_empty())
                    .then(|| serde_json::from_slice::<serde_json::Value>(bytes).ok())
                    .flatten()
                    .and_then(|json| crate::terminal::session::Recipe::from_json(&json));
            }
            let mut resume = None;
            if version >= 6 {
                let length = u32::from_be_bytes(reader.array()?) as usize;
                let bytes = reader.take(length)?;
                // State that can't be read is none: the session is still adopted, and accepts no
                // reports.
                resume = (!bytes.is_empty())
                    .then(|| serde_json::from_slice(bytes).ok())
                    .flatten();
            }
            sessions.push(FrozenSession {
                recipe,
                resume,
                id,
                pid,
                master,
                columns,
                rows,
                screen,
                metadata,
                program_status,
            });
        }
        let mut events = None;
        if version >= 4 {
            let length = u32::from_be_bytes(reader.array()?) as usize;
            events = Some(reader.take(length)?.to_vec()).filter(|events| !events.is_empty());
        }
        if !reader.0.is_empty() {
            return Err(HandOffError::TrailingBytes);
        }
        Ok(Table {
            listener,
            lock,
            boot,
            sessions,
            events,
        })
    }
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], HandOffError> {
        if self.0.len() < count {
            return Err(HandOffError::Truncated);
        }
        let (head, tail) = self.0.split_at(count);
        self.0 = tail;
        Ok(head)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], HandOffError> {
        Ok(self.take(N)?.try_into().expect("exact length"))
    }
}

/// What this program needs in order to replace itself. Set once, by `serve`; `serve --stdio` never
/// sets it, since its one connection is its only route in and nothing would be handed to.
pub struct Context {
    pub socket: PathBuf,
    pub listener: RawFd,
    pub lock: RawFd,
    /// The arguments this program was started with, reused for the next one so it serves the
    /// same socket with the same settings.
    pub arguments: Vec<OsString>,
}

static CONTEXT: OnceLock<Context> = OnceLock::new();

pub fn install(context: Context) {
    let _ = CONTEXT.set(context);
}

/// This build's daemon build identity (`build.rs`, #680): a hash of every source but the CLI's
/// `commands` module, and of the compiler, so two builds that differ only in their CLI commands
/// are the same daemon.
/// `protocol` states it as `daemon-build`, and a hand-off to a binary with the same one is no
/// hand-off at all (`hand_off`).
///
/// Read out of `DAEMON_BUILD_MARKER` through `black_box`, as `build_number` is, so the marker
/// survives the linker; and split at its colon, so its prefix is in the binary once.
pub fn daemon_build() -> &'static str {
    marker_value(std::hint::black_box(DAEMON_BUILD_MARKER)).unwrap_or("")
}

/// The daemon build where a daemon finds it in a binary it is offered, without running it: a run
/// would come out of the requester's wait (`APP_TIMEOUT`), and a byte scan costs what the file
/// digest it replaced did. Its prefix must not contain `BUILD_MARKER`'s, which the app scans for.
#[used]
pub static DAEMON_BUILD_MARKER: &str = concat!(
    "WORKROOMD-DAEMON-BUILD:",
    env!("WORKROOMD_DAEMON_BUILD"),
    ";"
);

/// The value of a `<prefix>:<value>;` marker.
fn marker_value(marker: &str) -> Option<&str> {
    marker
        .split_once(':')
        .and_then(|(_, rest)| rest.strip_suffix(';'))
}

/// The longest daemon build a marker may carry (a SHA-256 is 64 hex digits); a longer run of
/// bytes after the prefix is not a marker.
const MAX_DAEMON_BUILD: usize = 128;

/// The daemon build marked in the file at `path`, or `None` when it has none: a binary from before
/// #680, or not a daemon at all, which is a different daemon from this one. The first complete
/// marker counts; a universal Mac binary carries one per architecture, all the same.
pub fn daemon_build_in(path: &Path) -> std::io::Result<Option<String>> {
    marker_in(path, std::hint::black_box(DAEMON_BUILD_MARKER))
}

/// The build number marked in the file at `path` (`BUILD_MARKER`), as the app reads it out of a
/// bundled daemon (`DaemonBootstrap.buildNumber(in:)`): `None` for a file with none.
pub fn build_number_marked_in(path: &Path) -> std::io::Result<Option<u64>> {
    Ok(marker_in(path, std::hint::black_box(BUILD_MARKER))?
        .filter(|value| value.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|value| value.parse().ok()))
}

/// The value of the first complete marker shaped like `marker` (its prefix up to the colon) in the
/// file at `path`.
fn marker_in(path: &Path, marker: &str) -> std::io::Result<Option<String>> {
    let prefix = &marker.as_bytes()[..=marker.find(':').unwrap_or(0)];
    // A marker split across two reads is found whole in the next: each read is searched after the
    // tail of the one before, as long as a marker can be.
    let overlap = prefix.len() + MAX_DAEMON_BUILD + 1;
    let chunk = 1 << 16;
    let mut file = std::fs::File::open(path)?;
    let mut buffer: Vec<u8> = Vec::with_capacity(chunk + overlap);
    loop {
        let kept = buffer.len();
        buffer.resize(kept + chunk, 0);
        let read = file.read(&mut buffer[kept..])?;
        buffer.truncate(kept + read);
        if let Some(found) = complete_marker(&buffer, prefix) {
            return Ok(Some(found));
        }
        if read == 0 {
            return Ok(None);
        }
        buffer.drain(..buffer.len().saturating_sub(overlap));
    }
}

/// The value of the first complete marker in `bytes`: `prefix`, then hex digits, then `;`.
fn complete_marker(bytes: &[u8], prefix: &[u8]) -> Option<String> {
    let mut from = 0;
    while let Some(at) = bytes[from..]
        .windows(prefix.len())
        .position(|window| window == prefix)
    {
        let value = &bytes[from + at + prefix.len()..];
        let end = value
            .iter()
            .take(MAX_DAEMON_BUILD + 1)
            .position(|&byte| byte == b';');
        if let Some(end) = end
            && end > 0
            && value[..end].iter().all(u8::is_ascii_hexdigit)
        {
            return Some(String::from_utf8_lossy(&value[..end]).into_owned());
        }
        from += at + 1;
    }
    None
}

/// This program's own binary. On Linux `/proc/self/exe` still reads the right bytes after the path
/// has been replaced; elsewhere this runs at startup, before an update can have replaced it.
pub fn own_binary() -> std::io::Result<PathBuf> {
    if cfg!(target_os = "linux") {
        Ok(PathBuf::from("/proc/self/exe"))
    } else {
        std::env::current_exe()
    }
}

/// The table's path, beside the socket in the daemon's own directory.
pub fn table_path(socket: &Path) -> PathBuf {
    socket.with_extension("handoff")
}

/// Replaces this program with `binary`, keeping every session. Returns only when it did not:
/// `Ok` when `binary` is this daemon build already (unless `force`), or `Err` with the reason it
/// refused or failed. Either way nothing has changed.
///
/// `before_exec` runs once everything has been checked, just before the exec: the requester is
/// told there, because after the exec its connection is gone. When it returns false the requester
/// could not be told, so it has stopped waiting, and the hand-off is called off: a requester that
/// gave up may already be attaching panes to this program, which the exec would drop.
pub fn hand_off(
    sessions: &SessionStore,
    binary: &Path,
    force: bool,
    before_exec: impl FnOnce() -> bool,
) -> Result<(), HandOffError> {
    let context = CONTEXT.get().ok_or(HandOffError::NothingToHandOff)?;
    if !binary.is_absolute() {
        return Err(HandOffError::NotAbsolute(binary.to_path_buf()));
    }
    // A regular file only: reading a FIFO or a device to its end could block this connection's
    // thread for good.
    if !std::fs::metadata(binary).is_ok_and(|meta| meta.is_file()) {
        return Err(HandOffError::NotAFile(binary.to_path_buf()));
    }
    // The same daemon, not the same file (#680): a binary whose CLI commands alone changed is
    // this daemon still, and a hand-off would only pause every session for nothing. One with no
    // marker predates the identity, so it is a different daemon.
    let offered = daemon_build_in(binary).map_err(|source| HandOffError::Read {
        path: binary.to_path_buf(),
        source,
    })?;
    // Never an older build, even one of this daemon build: `current` would have the bootstrap
    // install it over a newer file of the same daemon (#681), which the next start then runs. Read
    // out of its bytes, as the app reads a bundled daemon's; a file with no number goes on to the
    // checks below, which run it and ask.
    let ours = build_number();
    if ours > 0
        && let Some(theirs) =
            build_number_marked_in(binary).map_err(|source| HandOffError::Read {
                path: binary.to_path_buf(),
                source,
            })?
        && theirs < ours
    {
        return Err(HandOffError::Older {
            binary: binary.to_path_buf(),
            theirs,
            ours,
        });
    }
    if !force && offered.as_deref() == Some(daemon_build()) {
        return Ok(());
    }
    // A panic in an earlier hand-off poisons this and proves nothing about the next one, so a
    // poisoned lock is taken like a free one. Only a hand-off still running is a refusal.
    let Some(_only) = crate::util::try_recover(IN_PROGRESS.try_lock()) else {
        return Err(HandOffError::InProgress);
    };
    PAUSED.store(true, std::sync::atomic::Ordering::Release);
    let _paused = Paused;
    // A repository command cut off by the exec could leave a repository half-written, so none may
    // be running, and none may start: every slot is taken until the exec, or until this returns.
    let _quiet =
        crate::daemon::rpc::Quiet::acquire(QUIET_TIMEOUT).ok_or(HandOffError::RepositoryBusy)?;
    // A file lookup left behind at its deadline (#334) holds no permit, so `Quiet` doesn't wait for
    // it, but the exec would: `execve` waits for every other thread to die, and one stuck in a FUSE
    // request can't. The exec would then freeze every session on the host. Race-free: with `Quiet`
    // held no request starts, and a resolve or read still waiting holds a permit, so the count can
    // only fall from here. No timeout on this refusal: a timeout is what would let the exec
    // through.
    if crate::vcs::file::filesystem_operations_left_behind() > 0 {
        return Err(HandOffError::FilesystemStuck);
    }
    // A `terminal.send` holds a permit while it types (#689), so `Quiet` waited for every one, and
    // none starts now. What one left owed, the end of a paste its program stopped reading inside,
    // goes now if the program takes it: the next program knows nothing of it.
    if !sessions.close_owed_pastes(Instant::now() + PASTE_CLOSE_TIMEOUT) {
        crate::note!("hand-off: a paste a send left open could not be closed; it stays open");
    }
    // A kill on its own thread holds `TERMINATING` until its shell is gone, so `frozen` already
    // keeps the exec out of its SIGHUP grace. What is left is its acknowledgement, written after:
    // an exec there loses it, and the app reads a kill that worked as one that failed (#283). So
    // wait for it out of `FREEZE_TIMEOUT`, and give `frozen` what is left: the waits stay inside
    // `APP_TIMEOUT` (checked above) however the time is split.
    let deadline = Instant::now() + FREEZE_TIMEOUT;
    if !sessions.wait_for_kills(deadline) {
        return Err(HandOffError::SessionEnding);
    }
    sessions
        .frozen(
            deadline.saturating_duration_since(Instant::now()),
            |frozen| {
                // Again, under the freeze, which holds off any kill not yet past its session
                // lookup: one from another connection may have begun since the wait above. A kill
                // already past that lookup can still count itself after this; it then waits out
                // the exec, and its acknowledgement is lost, so the app reports it as not killed.
                if sessions.is_killing() {
                    return Err(HandOffError::SessionEnding);
                }
                // Sealed as it is carried: nothing numbered after it is sent from here, so no
                // client hears a revision the next program numbers again. Sent after all when the
                // hand-off doesn't happen, which is the only way `replace` returns.
                let events = sessions.hooks().events.carry();
                let replaced = replace(
                    context,
                    binary,
                    sessions.hooks().program_status.boot(),
                    frozen,
                    events,
                    before_exec,
                );
                sessions.hooks().events.unseal();
                replaced
            },
        )
        .unwrap_or(Err(HandOffError::SessionsBusy))
}

/// This build's number (`build.rs`): the commit time it was built from. Daemons are ordered by it, so
/// the app never replaces a newer daemon with an older one, and a daemon never hands off to an older
/// program (#255, D13). 0 for a build with no git and no `WORKROOMD_BUILD`.
///
/// Read out of `BUILD_MARKER`, through `black_box`, so the marker is reachable from code that runs:
/// `#[used]` keeps it in the object file, but only a reference keeps it past a linker that drops
/// unreferenced sections. Split at its colon rather than stripping the prefix, so the prefix is in
/// the binary once: a second copy ahead of the marker read as no build at all to the app's scan.
pub fn build_number() -> u64 {
    std::hint::black_box(BUILD_MARKER)
        .split_once(':')
        .and_then(|(_, rest)| rest.strip_suffix(';'))
        .and_then(|number| number.parse().ok())
        .unwrap_or(0)
}

/// The build number as the app finds it in a binary it has not run: the bundled Linux daemons are
/// never run on the Mac, so the app reads this marker out of their bytes instead
/// (`DaemonBootstrap.buildNumber(in:)`).
#[used]
pub static BUILD_MARKER: &str = concat!("WORKROOMD-BUILD:", env!("WORKROOMD_BUILD"), ";");

/// Duplicates made for the exec, closed again if it does not happen.
struct Carried(Vec<RawFd>);

impl Carried {
    fn dup(&mut self, fd: RawFd) -> Result<RawFd, HandOffError> {
        // Close-on-exec at first, so the check below does not inherit them; cleared just before
        // the exec.
        // At 3 or above: a copy on 0, 1 or 2 would be the new program's stdio, and its diagnostics
        // would be written into a pty or the listening socket.
        // SAFETY: F_DUPFD_CLOEXEC takes and returns plain integers; a stale `fd` fails with EBADF.
        let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
        if copy < 0 {
            return Err(HandOffError::Duplicate {
                fd,
                source: std::io::Error::last_os_error(),
            });
        }
        self.0.push(copy);
        Ok(copy)
    }
}

impl Drop for Carried {
    fn drop(&mut self) {
        for fd in &self.0 {
            // SAFETY: each one is a duplicate `dup` made and only this list holds. A successful
            // exec never gets here, so nothing else can be using it.
            unsafe { libc::close(*fd) };
        }
    }
}

fn replace(
    context: &Context,
    binary: &Path,
    boot: SessionId,
    frozen: &[FrozenSession],
    events: Vec<u8>,
    before_exec: impl FnOnce() -> bool,
) -> Result<(), HandOffError> {
    let mut carried = Carried(Vec::new());
    let mut sessions = Vec::with_capacity(frozen.len());
    for session in frozen {
        sessions.push(FrozenSession {
            master: carried.dup(session.master)?,
            ..session.clone()
        });
    }
    let table = Table {
        listener: carried.dup(context.listener)?,
        lock: carried.dup(context.lock)?,
        boot: Some(boot),
        sessions,
        events: Some(events),
    };
    let path = table_path(&context.socket);
    let _ = std::fs::remove_file(&path);
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .and_then(|mut file| std::io::Write::write_all(&mut file, &table.encode()))
        .map_err(|source| HandOffError::WriteTable {
            path: path.clone(),
            source,
        })?;
    // The build is asked for before the check and read after it: both within one `CHECK_TIMEOUT`,
    // since every session's output is stopped until they are done, and a program that cannot
    // restore these sessions still says so first.
    let deadline = Instant::now() + CHECK_TIMEOUT;
    let probe = BuildProbe::start(binary);
    let result = check(binary, &path, deadline)
        .and(probe)
        .and_then(|probe| probe.no_downgrade(binary, build_number(), deadline))
        .and_then(|()| {
            let ids: Vec<String> = frozen.iter().map(|s| s.id.to_hyphenated()).collect();
            crate::note!(
                "{} checked {} sessions; replacing this program with it, carrying {}",
                binary.display(),
                ids.len(),
                ids.join(", ")
            );
            exec(context, binary, &path, &carried, before_exec)
        });
    let _ = std::fs::remove_file(&path);
    result
}

/// A program's `protocol` report, asked for alongside its table check so that the two share one
/// `CHECK_TIMEOUT` (every session's output is stopped meanwhile) without a slow check using up the
/// report's time. Killed if dropped unread.
struct BuildProbe {
    child: std::process::Child,
    report: Option<std::sync::mpsc::Receiver<String>>,
}

impl BuildProbe {
    fn start(binary: &Path) -> Result<Self, HandOffError> {
        let mut child = Command::new(binary)
            .arg("protocol")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|source| HandOffError::Start {
                binary: binary.to_path_buf(),
                source,
            })?;
        // Read while it runs, so a report bigger than a pipe cannot block it into the deadline,
        // and handed over through a channel waited on until the deadline only: a process the
        // program left behind can hold the pipe open long after the program itself has exited.
        let report = child.stdout.take().map(|mut pipe| {
            let (sender, receiver) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let mut kept = Vec::new();
                let _ = (&mut pipe).take(MAX_CHECK_STDERR).read_to_end(&mut kept);
                let _ = sender.send(String::from_utf8_lossy(&kept).into_owned());
                let _ = std::io::copy(&mut pipe, &mut std::io::sink());
            });
            receiver
        });
        Ok(BuildProbe { child, report })
    }

    /// Refuses a program built before this one (#255, D13): two Macs on different builds would
    /// otherwise each hand the host's daemon to their own, older or newer, in turn. A program says
    /// its build in `protocol` (`build-number`); one that predates the line is older than any that
    /// has it. A build of this program with no number (0) refuses nothing, having nothing to
    /// compare. A program that has not exited by `deadline` is refused, and so is one whose report
    /// has not come through `REPORT_GRACE` after it exited: a process it left behind holds the pipe.
    fn no_downgrade(
        mut self,
        binary: &Path,
        ours: u64,
        deadline: Instant,
    ) -> Result<(), HandOffError> {
        if ours == 0 {
            return Ok(());
        }
        let late = || HandOffError::BuildLate(binary.to_path_buf());
        if wait_until(&mut self.child, deadline).is_none() {
            return Err(late());
        }
        let report = match self.report.take() {
            Some(report) => report
                .recv_timeout(
                    deadline
                        .saturating_duration_since(Instant::now())
                        .max(REPORT_GRACE),
                )
                .map_err(|_| late())?,
            None => String::new(),
        };
        let theirs = build_number_in(&report);
        if theirs < ours {
            return Err(HandOffError::Older {
                binary: binary.to_path_buf(),
                theirs,
                ours,
            });
        }
        Ok(())
    }
}

impl Drop for BuildProbe {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The `build-number` a `protocol` report states, or 0 if it states none.
fn build_number_in(report: &str) -> u64 {
    report
        .lines()
        .find_map(|line| line.strip_prefix("build-number "))
        .and_then(|number| number.trim().parse().ok())
        .unwrap_or(0)
}

/// Runs `binary handoff-check <table>`: the new program reads the real table and paints every
/// screen, without taking anything over.
fn check(binary: &Path, table: &Path, deadline: Instant) -> Result<(), HandOffError> {
    let mut child = Command::new(binary)
        .arg("handoff-check")
        .arg(table)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|source| HandOffError::Start {
            binary: binary.to_path_buf(),
            source,
        })?;
    // Drained while it runs: a check that wrote more than a pipe holds (a panic's backtrace) would
    // otherwise block on the write and read as a timeout, hiding what it said.
    let stderr = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut kept = Vec::new();
            let _ = (&mut pipe).take(MAX_CHECK_STDERR).read_to_end(&mut kept);
            let _ = std::io::copy(&mut pipe, &mut std::io::sink());
            String::from_utf8_lossy(&kept).into_owned()
        })
    });
    let Some(status) = wait_until(&mut child, deadline) else {
        return Err(HandOffError::CheckLate(binary.to_path_buf()));
    };
    if status.success() {
        return Ok(());
    }
    let stderr = stderr
        .and_then(|reader| reader.join().ok())
        .unwrap_or_default();
    Err(HandOffError::CannotRestore {
        binary: binary.to_path_buf(),
        status,
        stderr: stderr.trim().to_string(),
    })
}

/// `child`'s exit status, or None, with it killed, if it is still running at `deadline`.
fn wait_until(child: &mut std::process::Child, deadline: Instant) -> Option<ExitStatus> {
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

fn exec(
    context: &Context,
    binary: &Path,
    table: &Path,
    carried: &Carried,
    before_exec: impl FnOnce() -> bool,
) -> Result<(), HandOffError> {
    let program =
        CString::new(binary.as_os_str().as_bytes()).map_err(|_| HandOffError::BinaryNul)?;
    let mut arguments = vec![program.clone()];
    let mut previous = context.arguments.iter();
    while let Some(argument) = previous.next() {
        // A program that was itself handed to names its own (already consumed) table.
        if argument == "--handoff" {
            previous.next();
            continue;
        }
        arguments.push(CString::new(argument.as_bytes()).map_err(|_| HandOffError::ArgumentNul)?);
    }
    arguments.push(CString::new("--handoff").expect("no NUL"));
    arguments
        .push(CString::new(table.as_os_str().as_bytes()).map_err(|_| HandOffError::TablePathNul)?);
    let mut argv: Vec<*const libc::c_char> = arguments.iter().map(|a| a.as_ptr()).collect();
    argv.push(std::ptr::null());

    if !before_exec() {
        return Err(HandOffError::RequesterGone);
    }
    for fd in &carried.0 {
        wr_exec::set_cloexec(*fd, false);
    }
    // `execv`, not `Command::exec`: std's exec resets SIGPIPE to its default before the call, and
    // when the call fails that leaves this program to be killed by the next write to a closed
    // socket. `execv` keeps the environment, which carries the settings `serve` reads from it.
    // SAFETY: `program` and every pointer in `argv` point into CStrings that outlive the call, and
    // `argv` ends with the null pointer execv requires.
    unsafe { libc::execv(program.as_ptr(), argv.as_ptr()) };
    let error = std::io::Error::last_os_error();
    for fd in &carried.0 {
        wr_exec::set_cloexec(*fd, true);
    }
    Err(HandOffError::Exec {
        binary: binary.to_path_buf(),
        source: error,
    })
}

/// `handoff-check <table>`: whether this binary can restore the sessions in `table`. Reads it and
/// paints every screen into a terminal of its size, which is everything a restore does short of
/// taking the descriptors.
pub fn check_table(path: &Path) -> Result<usize, HandOffError> {
    let bytes = std::fs::read(path).map_err(|source| HandOffError::Read {
        path: path.to_path_buf(),
        source,
    })?;
    let table = Table::decode(&bytes)?;
    // A build without the shadow terminal would accept these screens and paint nothing, so every
    // pane would reattach blank. Refusing keeps the daemon that has them.
    if !cfg!(feature = "terminal-state") && table.sessions.iter().any(|s| !s.screen.is_empty()) {
        return Err(HandOffError::NoTerminalState);
    }
    for session in &table.sessions {
        let mut shadow = crate::terminal::shadow::Shadow::new(session.columns, session.rows);
        shadow.write(&session.screen);
    }
    Ok(table.sessions.len())
}

/// Reads and removes the table a hand-off left, for the program it was handed to.
pub fn take_table(path: &Path) -> Result<Table, HandOffError> {
    let bytes = std::fs::read(path).map_err(|source| HandOffError::Read {
        path: path.to_path_buf(),
        source,
    });
    let _ = std::fs::remove_file(path);
    Table::decode(&bytes?)
}

#[cfg(test)]
mod tests;
