//! Hand-off: replacing a running agent's program with another binary, keeping every session
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
//! - **The screen as VT bytes** (`Shadow::replay`), never a snapshot. Two agent revisions share no
//!   snapshot format; they do share VT. The new program feeds the bytes to a fresh terminal of the
//!   same size, so its fidelity is exactly a reattaching client's, including the one-row
//!   scrollback offset that re-synthesis costs (`terminal.rs`). That row is lost at each hand-off.
//!
//! **It checks first and refuses rather than kills.** Before the exec, the new binary is run once
//! as `handoff-check <table>`, which reads the real table and paints every screen. That proves it
//! starts on this host and can restore these sessions. A binary that predates hand-off has no such
//! command, so a downgrade keeps the newer agent running. Any failure before the exec, including
//! the exec itself, leaves this program running with nothing lost.
//!
//! **What cannot be recovered** is a binary that passes the check and then fails while it
//! restores. Its descriptors close when it dies: every shell is hung up and the socket stops
//! answering, so the next client starts a fresh agent. `tests/hand_off.rs` does this on purpose and
//! records exactly that.

use std::collections::hash_map::DefaultHasher;
use std::ffi::{CString, OsString};
use std::hash::Hasher;
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::session::{FrozenSession, SessionId, SessionStore};

const MAGIC: [u8; 4] = *b"WRHO";
/// The table's format. The new program must read the old one's table, so a change here needs the
/// reader to keep accepting every version a shipped agent writes: version 1 had no metadata, and its
/// sessions are adopted with none (#255). An older program refuses a newer table in its check, so a
/// hand-off never goes to a program that would drop what this one carries.
const TABLE_VERSION: u16 = 2;
/// The oldest table this program still reads.
const OLDEST_TABLE_VERSION: u16 = 1;
/// How long the new binary gets to check the table. Every session's output is stopped meanwhile
/// (a shell blocks once its pty buffer fills), so it is short; a healthy check takes milliseconds.
const CHECK_TIMEOUT: Duration = Duration::from_secs(3);
/// How long a hand-off waits for running repository commands to finish before refusing. New ones
/// are refused meanwhile, so it is short too.
///
/// With `FREEZE_TIMEOUT` and `CHECK_TIMEOUT`, inside the app's own wait (`AgentHandOff.timeout`,
/// 6 s): a requester that gives up first calls the hand-off off, so a longer agent-side wait would
/// only hold every repository request off for a hand-off that can no longer happen.
const QUIET_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a hand-off waits to stop every session (`SessionStore::frozen`) before refusing. Every
/// list and attach waits behind it meanwhile.
const FREEZE_TIMEOUT: Duration = Duration::from_millis(500);
/// `AgentHandOff.timeout` in the app, which these waits must stay under. Checked at compile time,
/// so raising one past it fails the build rather than quietly defeating every busy hand-off.
///
/// The "handing off" write after them is one small frame to a requester that is reading its
/// answer, or has gone and fails the write at once, so it is not counted.
const APP_TIMEOUT: Duration = Duration::from_secs(6);
const _: () = assert!(
    QUIET_TIMEOUT.as_millis() + FREEZE_TIMEOUT.as_millis() + CHECK_TIMEOUT.as_millis()
        < APP_TIMEOUT.as_millis()
);
/// How much of a refusal reaches the requester (`serve.rs` truncates to it). The reason can quote
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
    pub sessions: Vec<FrozenSession>,
}

impl Table {
    /// Big-endian, like the rest of the wire: magic, version, listener, lock, count, then per
    /// session id, pid, master, columns, rows, screen length and screen, and (from version 2) its
    /// metadata as a count of length-prefixed key and value pairs.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = MAGIC.to_vec();
        out.extend_from_slice(&TABLE_VERSION.to_be_bytes());
        out.extend_from_slice(&self.listener.to_be_bytes());
        out.extend_from_slice(&self.lock.to_be_bytes());
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
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Table, String> {
        let mut reader = Reader(bytes);
        if reader.take(4)? != MAGIC {
            return Err("not a hand-off table".into());
        }
        let version = u16::from_be_bytes(reader.array()?);
        if !(OLDEST_TABLE_VERSION..=TABLE_VERSION).contains(&version) {
            return Err(format!("hand-off table version {version} is not supported"));
        }
        let listener = i32::from_be_bytes(reader.array()?);
        let lock = i32::from_be_bytes(reader.array()?);
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
                    let mut text = || -> Result<String, String> {
                        let length = u32::from_be_bytes(reader.array()?) as usize;
                        String::from_utf8(reader.take(length)?.to_vec())
                            .map_err(|_| "hand-off table metadata is not UTF-8".to_string())
                    };
                    let key = text()?;
                    let value = text()?;
                    metadata.push((key, value));
                }
            }
            sessions.push(FrozenSession {
                id,
                pid,
                master,
                columns,
                rows,
                screen,
                metadata,
            });
        }
        if !reader.0.is_empty() {
            return Err("hand-off table has trailing bytes".into());
        }
        Ok(Table {
            listener,
            lock,
            sessions,
        })
    }
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], String> {
        if self.0.len() < count {
            return Err("hand-off table is truncated".into());
        }
        let (head, tail) = self.0.split_at(count);
        self.0 = tail;
        Ok(head)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], String> {
        Ok(self.take(N)?.try_into().expect("exact length"))
    }
}

/// What this program needs in order to replace itself. Set once, by `serve`; `serve --stdio` never
/// sets it, since its one connection is its only route in and nothing would be handed to.
pub struct Context {
    pub socket: PathBuf,
    pub listener: RawFd,
    pub lock: RawFd,
    /// This program's own bytes, hashed when it started. Read then because a later read may find
    /// another file: an app update replaces the binary at the same path.
    pub digest: Option<u64>,
    /// The arguments this program was started with, reused for the next one so it serves the
    /// same socket with the same settings.
    pub arguments: Vec<OsString>,
}

static CONTEXT: OnceLock<Context> = OnceLock::new();

pub fn install(context: Context) {
    let _ = CONTEXT.set(context);
}

/// Hashes a file's bytes. Only ever compared with another hash this same process made, so the
/// hasher's output needs to be stable within a process and nothing more.
pub fn digest(path: &Path) -> std::io::Result<u64> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = DefaultHasher::new();
    let mut buffer = vec![0u8; 1 << 16];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            return Ok(hasher.finish());
        }
        hasher.write(&buffer[..read]);
    }
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

/// The table's path, beside the socket in the agent's own directory.
pub fn table_path(socket: &Path) -> PathBuf {
    socket.with_extension("handoff")
}

/// Replaces this program with `binary`, keeping every session. Returns only when it did not:
/// `Ok` when `binary` is this program already (unless `force`), or `Err` with the reason it
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
) -> Result<(), String> {
    let context = CONTEXT
        .get()
        .ok_or("this agent serves one connection and has nothing to hand off")?;
    if !binary.is_absolute() {
        return Err(format!("{} is not an absolute path", binary.display()));
    }
    // A regular file only: reading a FIFO or a device to its end could block this connection's
    // thread for good.
    if !std::fs::metadata(binary).is_ok_and(|meta| meta.is_file()) {
        return Err(format!(
            "cannot read {}: not a regular file",
            binary.display()
        ));
    }
    let offered = digest(binary).map_err(|e| format!("cannot read {}: {e}", binary.display()))?;
    if !force && context.digest == Some(offered) {
        return Ok(());
    }
    // A panic in an earlier hand-off poisons this and proves nothing about the next one, so a
    // poisoned lock is taken like a free one. Only a hand-off still running is a refusal.
    let _only = match IN_PROGRESS.try_lock() {
        Ok(guard) => guard,
        Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
        Err(std::sync::TryLockError::WouldBlock) => {
            return Err("another hand-off is in progress".into())
        }
    };
    PAUSED.store(true, std::sync::atomic::Ordering::Release);
    let _paused = Paused;
    // A repository command cut off by the exec could leave a repository half-written, so none may
    // be running, and none may start: every slot is taken until the exec, or until this returns.
    let _quiet = crate::vcs::Quiet::acquire(QUIET_TIMEOUT)
        .ok_or("a repository command is still running; try again when it finishes")?;
    // A file lookup left behind at its deadline (#334) holds no permit, so `Quiet` doesn't wait for
    // it, but the exec would: `execve` waits for every other thread to die, and one stuck in a FUSE
    // request can't. The exec would then freeze every session on the host. Race-free: with `Quiet`
    // held no request starts, and a resolve or read still waiting holds a permit, so the count can
    // only fall from here. No timeout on this refusal: a timeout is what would let the exec
    // through.
    if crate::file::filesystem_operations_left_behind() > 0 {
        return Err(
            "a filesystem operation is still stuck on a mount; try again when it returns".into(),
        );
    }
    // A kill on its own thread holds `TERMINATING` until its shell is gone, so `frozen` already
    // keeps the exec out of its SIGHUP grace. What is left is its acknowledgement, written after:
    // an exec there loses it, and the app reads a kill that worked as one that failed (#283). So
    // wait for it out of `FREEZE_TIMEOUT`, and give `frozen` what is left: the waits stay inside
    // `APP_TIMEOUT` (checked above) however the time is split.
    let deadline = Instant::now() + FREEZE_TIMEOUT;
    if !sessions.wait_for_kills(deadline) {
        return Err("a session is being ended; try again when it finishes".into());
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
                    return Err("a session is being ended; try again when it finishes".into());
                }
                replace(context, binary, frozen, before_exec)
            },
        )
        .unwrap_or_else(|| {
            Err("a session is being ended or repainted; try again when it finishes".into())
        })
}

/// Duplicates made for the exec, closed again if it does not happen.
struct Carried(Vec<RawFd>);

impl Carried {
    fn dup(&mut self, fd: RawFd) -> Result<RawFd, String> {
        // Close-on-exec at first, so the check below does not inherit them; cleared just before
        // the exec.
        // At 3 or above: a copy on 0, 1 or 2 would be the new program's stdio, and its diagnostics
        // would be written into a pty or the listening socket.
        let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
        if copy < 0 {
            return Err(format!(
                "could not duplicate descriptor {fd}: {}",
                std::io::Error::last_os_error()
            ));
        }
        self.0.push(copy);
        Ok(copy)
    }
}

impl Drop for Carried {
    fn drop(&mut self) {
        for fd in &self.0 {
            unsafe { libc::close(*fd) };
        }
    }
}

fn replace(
    context: &Context,
    binary: &Path,
    frozen: &[FrozenSession],
    before_exec: impl FnOnce() -> bool,
) -> Result<(), String> {
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
        sessions,
    };
    let path = table_path(&context.socket);
    let _ = std::fs::remove_file(&path);
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .and_then(|mut file| std::io::Write::write_all(&mut file, &table.encode()))
        .map_err(|e| format!("could not write {}: {e}", path.display()))?;
    // The build is asked for before the check and read after it: both within one `CHECK_TIMEOUT`,
    // since every session's output is stopped until they are done, and a program that cannot
    // restore these sessions still says so first.
    let deadline = Instant::now() + CHECK_TIMEOUT;
    let probe = BuildProbe::start(binary);
    let result = check(binary, &path, deadline)
        .and(probe)
        .and_then(|probe| probe.no_downgrade(binary, crate::serve::build_number(), deadline))
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
    fn start(binary: &Path) -> Result<Self, String> {
        let mut child = Command::new(binary)
            .arg("protocol")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("{} could not start: {e}", binary.display()))?;
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
    /// otherwise each hand the host's agent to their own, older or newer, in turn. A program says
    /// its build in `protocol` (`build-number`); one that predates the line is older than any that
    /// has it. A build of this program with no number (0) refuses nothing, having nothing to
    /// compare. A program that has not said by `deadline` is refused.
    fn no_downgrade(mut self, binary: &Path, ours: u64, deadline: Instant) -> Result<(), String> {
        if ours == 0 {
            return Ok(());
        }
        let late = || {
            format!(
                "{} did not say its build within {}s",
                binary.display(),
                CHECK_TIMEOUT.as_secs()
            )
        };
        if wait_until(&mut self.child, deadline).is_none() {
            return Err(late());
        }
        let report = match self.report.take() {
            Some(report) => report
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .map_err(|_| late())?,
            None => String::new(),
        };
        let theirs = build_number_in(&report);
        if theirs < ours {
            return Err(format!(
                "{} is build {theirs}, older than this agent's build {ours}",
                binary.display()
            ));
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
fn check(binary: &Path, table: &Path, deadline: Instant) -> Result<(), String> {
    let mut child = Command::new(binary)
        .arg("handoff-check")
        .arg(table)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{} could not start: {e}", binary.display()))?;
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
        return Err(format!(
            "{} did not check the sessions within {}s",
            binary.display(),
            CHECK_TIMEOUT.as_secs()
        ));
    };
    if status.success() {
        return Ok(());
    }
    let stderr = stderr
        .and_then(|reader| reader.join().ok())
        .unwrap_or_default();
    Err(format!(
        "{} cannot restore these sessions ({status}): {}",
        binary.display(),
        stderr.trim()
    ))
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
) -> Result<(), String> {
    let program = CString::new(binary.as_os_str().as_bytes())
        .map_err(|_| "the binary's path contains a NUL".to_string())?;
    let mut arguments = vec![program.clone()];
    let mut previous = context.arguments.iter();
    while let Some(argument) = previous.next() {
        // A program that was itself handed to names its own (already consumed) table.
        if argument == "--handoff" {
            previous.next();
            continue;
        }
        arguments
            .push(CString::new(argument.as_bytes()).map_err(|_| "an argument contains a NUL")?);
    }
    arguments.push(CString::new("--handoff").expect("no NUL"));
    arguments
        .push(CString::new(table.as_os_str().as_bytes()).map_err(|_| "the table path has a NUL")?);
    let mut argv: Vec<*const libc::c_char> = arguments.iter().map(|a| a.as_ptr()).collect();
    argv.push(std::ptr::null());

    if !before_exec() {
        return Err("the requester stopped waiting, so nothing was replaced".into());
    }
    for fd in &carried.0 {
        set_cloexec(*fd, false);
    }
    // `execv`, not `Command::exec`: std's exec resets SIGPIPE to its default before the call, and
    // when the call fails that leaves this program to be killed by the next write to a closed
    // socket. `execv` keeps the environment, which carries the settings `serve` reads from it.
    unsafe { libc::execv(program.as_ptr(), argv.as_ptr()) };
    let error = std::io::Error::last_os_error();
    for fd in &carried.0 {
        set_cloexec(*fd, true);
    }
    Err(format!(
        "{} could not be executed: {error}",
        binary.display()
    ))
}

pub fn set_cloexec(fd: RawFd, on: bool) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            let flags = if on {
                flags | libc::FD_CLOEXEC
            } else {
                flags & !libc::FD_CLOEXEC
            };
            libc::fcntl(fd, libc::F_SETFD, flags);
        }
    }
}

/// `handoff-check <table>`: whether this binary can restore the sessions in `table`. Reads it and
/// paints every screen into a terminal of its size, which is everything a restore does short of
/// taking the descriptors.
pub fn check_table(path: &Path) -> Result<usize, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let table = Table::decode(&bytes)?;
    // A build without the shadow terminal would accept these screens and paint nothing, so every
    // pane would reattach blank. Refusing keeps the agent that has them.
    if !cfg!(feature = "terminal-state") && table.sessions.iter().any(|s| !s.screen.is_empty()) {
        return Err("this build cannot restore screens (built without terminal-state)".into());
    }
    for session in &table.sessions {
        let mut shadow = crate::shadow::Shadow::new(session.columns, session.rows);
        shadow.write(&session.screen);
    }
    Ok(table.sessions.len())
}

/// Reads and removes the table a hand-off left, for the program it was handed to.
pub fn take_table(path: &Path) -> Result<Table, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()));
    let _ = std::fs::remove_file(path);
    Table::decode(&bytes?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_table_survives_encoding() {
        let table = Table {
            listener: 3,
            lock: 4,
            sessions: vec![
                FrozenSession {
                    id: SessionId([7; 16]),
                    pid: 4242,
                    master: 9,
                    columns: 120,
                    rows: 40,
                    screen: b"\x1b[2Jhello".to_vec(),
                    metadata: vec![
                        ("workroom".into(), "wr|/p|cyan".into()),
                        ("created".into(), "1791130740000".into()),
                    ],
                },
                FrozenSession {
                    id: SessionId([8; 16]),
                    pid: 4343,
                    master: 10,
                    columns: 80,
                    rows: 24,
                    screen: Vec::new(),
                    metadata: Vec::new(),
                },
            ],
        };
        assert_eq!(Table::decode(&table.encode()), Ok(table));
    }

    /// A build without the shadow terminal refuses a table with screens, which it could only drop.
    #[test]
    fn screens_are_refused_by_a_build_that_cannot_paint_them() {
        let path = std::env::temp_dir().join(format!("wr-agent-table-{}", std::process::id()));
        let table = Table {
            listener: 3,
            lock: 4,
            sessions: vec![FrozenSession {
                id: SessionId([7; 16]),
                pid: 1,
                master: 5,
                columns: 80,
                rows: 24,
                screen: b"on screen".to_vec(),
                metadata: Vec::new(),
            }],
        };
        std::fs::write(&path, table.encode()).expect("table");
        let checked = check_table(&path);
        let _ = std::fs::remove_file(&path);
        assert_eq!(
            checked.is_ok(),
            cfg!(feature = "terminal-state"),
            "{checked:?}"
        );
    }

    #[test]
    fn a_protocol_report_states_its_build_number() {
        assert_eq!(
            build_number_in("protocol 7\nbuild wr-agent 0.1.0\nbuild-number 1791130740\n"),
            1791130740
        );
        // An agent from before #255 states none, and orders below every build that does.
        assert_eq!(build_number_in("protocol 6\nbuild wr-agent 0.1.0\n"), 0);
    }

    /// A program with a lower build number is refused, after the table check and before the exec;
    /// one at least as high, or any when this build has no number, is let through (D13). One that
    /// does not say in time is refused too: every session's output is stopped meanwhile.
    #[test]
    fn a_hand_off_to_an_older_build_is_refused() {
        let dir = std::env::temp_dir().join(format!("wr-agent-downgrade-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let program = |name: &str, number: Option<u64>| {
            let path = dir.join(name);
            let line = number.map_or(String::new(), |n| format!("echo build-number {n}; "));
            std::fs::write(&path, format!("#!/bin/sh\necho protocol 7; {line}exit 0\n")).unwrap();
            std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
                .unwrap();
            path
        };
        let older = program("older", Some(100));
        let same = program("same", Some(200));
        let newer = program("newer", Some(300));
        let unnumbered = program("unnumbered", None);
        let soon = || Instant::now() + CHECK_TIMEOUT;
        let no_downgrade = |binary: &Path, ours: u64, deadline: Instant| {
            BuildProbe::start(binary)?.no_downgrade(binary, ours, deadline)
        };
        assert!(no_downgrade(&older, 200, soon())
            .unwrap_err()
            .contains("older than this agent's build 200"));
        assert!(no_downgrade(&unnumbered, 200, soon()).is_err());
        assert_eq!(no_downgrade(&same, 200, soon()), Ok(()));
        assert_eq!(no_downgrade(&newer, 200, soon()), Ok(()));
        assert_eq!(no_downgrade(&older, 0, soon()), Ok(()));
        let slow = dir.join("slow");
        std::fs::write(&slow, "#!/bin/sh\nsleep 30\necho build-number 300\n").unwrap();
        std::fs::set_permissions(&slow, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let started = Instant::now();
        assert!(
            no_downgrade(&slow, 200, Instant::now() + Duration::from_millis(300))
                .unwrap_err()
                .contains("did not say its build")
        );
        assert!(started.elapsed() < Duration::from_secs(5));
        // One that exits but leaves a process holding its output open is refused at the deadline,
        // not waited on.
        let lingering = dir.join("lingering");
        std::fs::write(
            &lingering,
            "#!/bin/sh\n(sleep 30 &)\necho build-number 300\nexit 0\n",
        )
        .unwrap();
        std::fs::set_permissions(
            &lingering,
            std::os::unix::fs::PermissionsExt::from_mode(0o755),
        )
        .unwrap();
        let started = Instant::now();
        assert!(
            no_downgrade(&lingering, 200, Instant::now() + Duration::from_millis(300))
                .unwrap_err()
                .contains("did not say its build")
        );
        assert!(started.elapsed() < Duration::from_secs(5));
        // Asked for while the table is checked: a check that takes all the time leaves a report
        // already given to be read, not refused.
        let mut probe = BuildProbe::start(&newer).unwrap();
        while probe.child.try_wait().unwrap().is_none() {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(probe.no_downgrade(&newer, 200, Instant::now()), Ok(()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A table that is cut short or carries more than it declares is refused, not half-restored.
    #[test]
    fn a_damaged_table_is_refused() {
        let table = Table {
            listener: 3,
            lock: 4,
            sessions: vec![FrozenSession {
                id: SessionId([7; 16]),
                pid: 1,
                master: 5,
                columns: 80,
                rows: 24,
                screen: b"screen".to_vec(),
                metadata: Vec::new(),
            }],
        };
        let bytes = table.encode();
        assert!(Table::decode(&bytes[..bytes.len() - 1]).is_err());
        let mut longer = bytes.clone();
        longer.push(0);
        assert!(Table::decode(&longer).is_err());
        let mut newer = bytes;
        newer[5] = 3;
        assert!(Table::decode(&newer).is_err());
    }

    /// A table written by an agent from before #255 (version 1, no metadata) is still adopted, so
    /// upgrading a host keeps every shell; its sessions come over with no metadata (D6).
    ///
    /// The bytes are written out by hand, not by `encode`, which now writes version 2: a fixture an
    /// encoder produces would move with the encoder and stop proving anything about old tables.
    #[test]
    fn a_version_1_table_from_an_older_agent_is_adopted_without_metadata() {
        #[rustfmt::skip]
        let version_1: &[u8] = &[
            b'W', b'R', b'H', b'O', 0, 1,      // magic, version 1
            0, 0, 0, 3, 0, 0, 0, 4,            // listener 3, lock 4
            0, 0, 0, 1,                        // one session
            7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // id
            0, 0, 0x10, 0x92,                  // pid 4242
            0, 0, 0, 9,                        // master 9
            0, 120, 0, 40,                     // 120 x 40
            0, 0, 0, 5, b'h', b'e', b'l', b'l', b'o', // screen
        ];
        let table = Table::decode(version_1).expect("a version 1 table is read");
        assert_eq!(
            table,
            Table {
                listener: 3,
                lock: 4,
                sessions: vec![FrozenSession {
                    id: SessionId([7; 16]),
                    pid: 4242,
                    master: 9,
                    columns: 120,
                    rows: 40,
                    screen: b"hello".to_vec(),
                    metadata: Vec::new(),
                }],
            }
        );
    }
}
