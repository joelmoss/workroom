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
//!   session its id, pid, size and screen. A file, not a pipe: this process is the pipe's only
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
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::session::{FrozenSession, SessionId, SessionStore};

const MAGIC: [u8; 4] = *b"WRHO";
/// The table's format. The new program must read the old one's table, so a change here needs the
/// reader to keep accepting every version a shipped agent writes.
const TABLE_VERSION: u16 = 1;
/// How long the new binary gets to check the table. Every session's output is stopped meanwhile
/// (a shell blocks once its pty buffer fills), so it is short; a healthy check takes milliseconds.
const CHECK_TIMEOUT: Duration = Duration::from_secs(3);
/// How long a hand-off waits for running repository commands to finish before refusing. New ones
/// are refused meanwhile, so it is short too.
///
/// Together with `CHECK_TIMEOUT`, inside the app's own wait (`AgentHandOff.timeout`, 6 s): a
/// requester that gives up first calls the hand-off off, so a longer agent-side wait would only
/// hold every repository request off for a hand-off that can no longer happen.
const QUIET_TIMEOUT: Duration = Duration::from_secs(2);

/// One hand-off at a time: a second would take the same slots and locks, and release them under
/// the first.
static IN_PROGRESS: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// What crosses the exec, apart from the descriptors themselves.
#[derive(Debug, PartialEq, Eq)]
pub struct Table {
    pub listener: RawFd,
    pub lock: RawFd,
    pub sessions: Vec<FrozenSession>,
}

impl Table {
    /// Big-endian, like the rest of the wire: magic, version, listener, lock, count, then per
    /// session id, pid, master, columns, rows, screen length and screen.
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
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Table, String> {
        let mut reader = Reader(bytes);
        if reader.take(4)? != MAGIC {
            return Err("not a hand-off table".into());
        }
        let version = u16::from_be_bytes(reader.array()?);
        if version != TABLE_VERSION {
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
            sessions.push(FrozenSession {
                id,
                pid,
                master,
                columns,
                rows,
                screen,
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
    // A repository command cut off by the exec could leave a repository half-written, so none may
    // be running, and none may start: every slot is taken until the exec, or until this returns.
    let _quiet = crate::vcs::Quiet::acquire(QUIET_TIMEOUT)
        .ok_or("a repository command is still running; try again when it finishes")?;
    sessions.frozen(|frozen| replace(context, binary, frozen, before_exec))
}

/// Duplicates made for the exec, closed again if it does not happen.
struct Carried(Vec<RawFd>);

impl Carried {
    fn dup(&mut self, fd: RawFd) -> Result<RawFd, String> {
        // Close-on-exec at first, so the check below does not inherit them; cleared just before
        // the exec.
        let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
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
    let result =
        check(binary, &path).and_then(|()| exec(context, binary, &path, &carried, before_exec));
    let _ = std::fs::remove_file(&path);
    result
}

/// Runs `binary handoff-check <table>`: the new program reads the real table and paints every
/// screen, without taking anything over.
fn check(binary: &Path, table: &Path) -> Result<(), String> {
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
            let mut text = String::new();
            let _ = pipe.read_to_string(&mut text);
            text
        })
    });
    let deadline = Instant::now() + CHECK_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "{} did not check the sessions within {}s",
                    binary.display(),
                    CHECK_TIMEOUT.as_secs()
                ));
            }
        }
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
                },
                FrozenSession {
                    id: SessionId([8; 16]),
                    pid: 4343,
                    master: 10,
                    columns: 80,
                    rows: 24,
                    screen: Vec::new(),
                },
            ],
        };
        assert_eq!(Table::decode(&table.encode()), Ok(table));
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
            }],
        };
        let bytes = table.encode();
        assert!(Table::decode(&bytes[..bytes.len() - 1]).is_err());
        let mut longer = bytes.clone();
        longer.push(0);
        assert!(Table::decode(&longer).is_err());
        let mut newer = bytes;
        newer[5] = 2;
        assert!(Table::decode(&newer).is_err());
    }
}
