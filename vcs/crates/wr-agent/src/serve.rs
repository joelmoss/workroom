//! `wr-agent serve`: owns the ptys, speaks the envelope over a stream.
//!
//! The transport is a `UnixListener` locally and whatever bidirectional stream a driver opens
//! remotely, so the connection handler below takes `Read + Write` rather than a socket — that is
//! the whole reason the local path is also the remote path's test harness.
//!
//! **Single instance, by `flock`.** Two agents on one socket would each own half the sessions and
//! neither would find the other's, which presents as terminals vanishing. The lock is held for the
//! process's life and released by the kernel on exit, including a crash — no stale-lock cleanup to
//! get wrong.
//!
//! **Idle self-exit is kept exactly as the Swift daemon has it**, and the design doc says why the
//! earlier plan to remove it did not survive scrutiny: diffs, history and watches are things a
//! *connected client* asks for, so an agent with no connections and no ptys is holding nothing
//! anyone can lose. The one thing that must outlive the app is a live terminal, which is precisely
//! what the rule already protects.

use std::ffi::{OsStr, OsString};
use std::io::{Read, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::protocol::envelope::{
    negotiate, Envelope, EnvelopeDecoder, Hello, ProtocolError, Service,
};
use crate::protocol::frame::{Frame, FrameDecoder, FrameKind};
use crate::session::{SessionId, SessionSpec, SessionStore};

pub const BUILD: &str = concat!("wr-agent ", env!("CARGO_PKG_VERSION"));

/// How long an agent with no sessions and no clients waits before exiting.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    #[error("another agent already holds {0}")]
    AlreadyRunning(PathBuf),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Holds the single-instance lock for the process's lifetime.
pub struct InstanceLock {
    _file: std::fs::File,
}

/// `flock(LOCK_EX | LOCK_NB)` beside the socket. A lock *file* rather than the socket itself,
/// because binding a unix socket unlinks and recreates the path — two racing agents would each
/// successfully bind and the second would silently steal the first's address.
pub fn acquire_instance_lock(socket: &Path) -> Result<InstanceLock, ServeError> {
    let path = socket.with_extension("lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return Err(ServeError::AlreadyRunning(path));
    }
    Ok(InstanceLock { _file: file })
}

pub struct Agent {
    pub sessions: SessionStore,
    connections: Arc<AtomicUsize>,
}

impl Default for Agent {
    fn default() -> Self {
        Self::new()
    }
}

impl Agent {
    pub fn new() -> Self {
        Self {
            sessions: SessionStore::new(),
            connections: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Binds and serves until idle. Returns when no session and no client has existed for
    /// `idle_timeout`.
    pub fn serve(&self, socket: &Path, idle_timeout: Duration) -> Result<(), ServeError> {
        // A socket file left by a previous run would make bind fail with EADDRINUSE even though
        // nobody is listening. The flock above is what actually guarantees exclusivity, so
        // removing a stale path here is safe rather than a race.
        if socket.exists() {
            let _ = std::fs::remove_file(socket);
        }
        if let Some(parent) = socket.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let listener = UnixListener::bind(socket)?;
        listener.set_nonblocking(true)?;

        let mut idle_since = Some(Instant::now());
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    idle_since = None;
                    self.connections.fetch_add(1, Ordering::SeqCst);
                    let sessions = self.sessions.clone();
                    let connections = Arc::clone(&self.connections);
                    std::thread::spawn(move || {
                        let _ = stream.set_nonblocking(false);
                        let _ = handle_connection(stream, sessions);
                        connections.fetch_sub(1, Ordering::SeqCst);
                    });
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    let busy =
                        self.connections.load(Ordering::SeqCst) > 0 || !self.sessions.is_empty();
                    if busy {
                        idle_since = None;
                    } else {
                        let since = idle_since.get_or_insert_with(Instant::now);
                        if since.elapsed() >= idle_timeout {
                            break;
                        }
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
                Err(e) => return Err(e.into()),
            }
        }
        let _ = std::fs::remove_file(socket);
        Ok(())
    }
}

/// Greets, negotiates, then serves envelopes until the peer goes away.
///
/// Takes a `UnixStream` rather than a generic `Read + Write` for one reason: output needs its own
/// writer, so the pty pump can run while this loop blocks on read. `try_clone` gives that; a
/// generic stream cannot. The remote path will pass whatever its driver opens through the same
/// shape — the requirement is a clonable bidirectional stream, not a socket specifically.
pub fn handle_connection(
    mut stream: UnixStream,
    sessions: SessionStore,
) -> Result<(), ProtocolError> {
    let local = Hello::current(BUILD);
    stream
        .write_all(&local.encode())
        .map_err(|_| ProtocolError::NotAnAgent)?;
    let _ = stream.flush();

    // Read the peer's greeting first — everything after depends on the negotiated version, so
    // parsing an envelope before it would be parsing at an unknown version.
    let mut greeting = Vec::new();
    let mut byte = [0u8; 1];
    let remote = loop {
        if let Some((hello, _)) = Hello::decode(&greeting)? {
            break hello;
        }
        match stream.read(&mut byte) {
            Ok(0) => return Err(ProtocolError::NotAnAgent),
            Ok(_) => greeting.push(byte[0]),
            Err(_) => return Err(ProtocolError::NotAnAgent),
        }
    };
    negotiate(&local, &remote)?;

    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let mut attached: Option<SessionId> = None;
    let mut pump: Option<std::thread::JoinHandle<()>> = None;
    // The pump spends most of its life asleep waiting for an idle shell to say something, so it
    // cannot learn that the client has gone by failing a write — there is nothing to write. It
    // needs to be told.
    let stop = Arc::new(AtomicBool::new(false));

    loop {
        while let Some(envelope) = decoder.next_envelope()? {
            let was_attached = attached;
            if let Some(reply) = dispatch(&envelope, &sessions, &mut attached) {
                if stream.write_all(&reply.encode()).is_err() {
                    break;
                }
                let _ = stream.flush();
            }
            // Start the output pump exactly once, when an attach first succeeds. Starting it
            // before the reply would race the client's own read of `Attached`.
            if was_attached.is_none() {
                if let Some(id) = attached {
                    // Repaint before the pump starts, so the screen arrives ahead of any new
                    // output rather than being interleaved with it.
                    let replay = sessions.replay_bytes(id);
                    if !replay.is_empty() {
                        let frame = Frame::new(FrameKind::Output, replay);
                        let envelope =
                            Envelope::new(Service::Terminal, envelope.stream, frame.encode());
                        if stream.write_all(&envelope.encode()).is_err() {
                            break;
                        }
                        let _ = stream.flush();
                    }
                    if let Ok(writer) = stream.try_clone() {
                        let sessions = sessions.clone();
                        let stop = Arc::clone(&stop);
                        pump = Some(std::thread::spawn(move || {
                            let mut writer = writer;
                            pump_output(&sessions, id, &mut writer, envelope.stream, &stop);
                        }));
                    }
                }
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => decoder.push(&buffer[..n]),
            Err(_) => break,
        }
    }

    // Order matters here, and getting it wrong hangs the connection thread forever.
    //
    // Detach FIRST, so the session is correctly reported detached even if anything below stalls —
    // a session wrongly listed as attached is what a client sees when it tries to come back.
    // Then tell the pump to stop and close the socket, and only then join. Joining before setting
    // the flag deadlocks against an idle shell: the pump is asleep waiting for output that is not
    // coming, so it never attempts the write that would have discovered the closed socket.
    if let Some(id) = attached {
        sessions.detach(id);
    }
    stop.store(true, Ordering::SeqCst);
    let _ = stream.shutdown(std::net::Shutdown::Both);
    if let Some(pump) = pump {
        let _ = pump.join();
    }
    Ok(())
}

/// Handles one envelope. Returns a reply to send, if any.
fn dispatch(
    envelope: &Envelope,
    sessions: &SessionStore,
    attached: &mut Option<SessionId>,
) -> Option<Envelope> {
    if envelope.service != Service::Terminal && envelope.service != Service::Control {
        return None;
    }
    let mut frames = FrameDecoder::new();
    frames.push(&envelope.payload);
    let frame = frames.next_frame().ok().flatten()?;

    let reply = |frame: Frame| {
        Some(Envelope::new(
            envelope.service,
            envelope.stream,
            frame.encode(),
        ))
    };

    match frame.kind {
        FrameKind::Attach => {
            let request = AttachRequest::decode(&frame.payload)?;
            let id = request.id?;
            // Create on first attach, reattach afterwards. One code path, so a client that
            // crashed and came back does not have to know which case it is in.
            let result = if sessions.contains(id) {
                sessions.attach(id).map(|_| ())
            } else {
                let shell = request
                    .shell
                    .clone()
                    .unwrap_or_else(|| OsString::from("/bin/sh"));
                // A run command is `<shell> -c <command>`, so it inherits the login shell's
                // environment rather than being exec'd bare — the same shape the app uses today.
                let args: Vec<OsString> = match &request.command {
                    Some(command) if !command.is_empty() => {
                        vec![OsString::from("-c"), command.clone()]
                    }
                    _ => Vec::new(),
                };
                sessions
                    .create(SessionSpec {
                        id,
                        program: &shell,
                        args: &args,
                        env: &request.env,
                        cwd: request.cwd.as_deref(),
                        columns: request.columns,
                        rows: request.rows,
                    })
                    .map(|_| ())
            };
            match result {
                Ok(()) => {
                    *attached = Some(id);
                    reply(Frame::control(FrameKind::Attached))
                }
                Err(e) => reply(Frame::new(FrameKind::Failure, e.to_string().into_bytes())),
            }
        }
        FrameKind::Input => {
            let id = (*attached)?;
            sessions.with_pty(id, |pty| pty.write(&frame.payload));
            None
        }
        FrameKind::Resize => {
            let id = (*attached)?;
            if frame.payload.len() >= 4 {
                let columns = u16::from_be_bytes([frame.payload[0], frame.payload[1]]);
                let rows = u16::from_be_bytes([frame.payload[2], frame.payload[3]]);
                sessions.with_pty(id, |pty| pty.resize(columns, rows));
                // The shadow has to follow the pty, or a reattaching client is repainted at the
                // wrong geometry and every wrapped line is wrong.
                if let Some(shadow) = sessions.shadow(id) {
                    if let Ok(mut shadow) = shadow.lock() {
                        shadow.resize(columns, rows);
                    }
                }
            }
            None
        }
        FrameKind::List => reply(Frame::new(
            FrameKind::Sessions,
            encode_descriptor_list(&sessions.list()),
        )),
        FrameKind::Kill => {
            let id = SessionId::from_slice(frame.payload.get(..16)?)?;
            sessions.kill(id);
            reply(Frame::control(FrameKind::Acknowledged))
        }
        FrameKind::KillAll => {
            sessions.kill_all();
            reply(Frame::control(FrameKind::Acknowledged))
        }
        _ => None,
    }
}

/// The session list, in the wire format `SessionDescriptor.decodeList` already reads.
///
/// Matching the shipped Swift encoding rather than inventing a second one: the app's decoder,
/// its `SessionDescriptor` type and every caller of `liveSessions()` then work against either
/// backend with no branching. The format is
/// `count:u32`, then per session `id:[16]`, `pid:i32`, `tty:u64`, `cwd:string`,
/// `attached:u8`, `metadata:entries` — all big-endian, strings length-prefixed.
///
/// `tty` is zero: the Swift daemon reports the pty's device number, and nothing in the app reads
/// it (verified by grep). Reporting a fabricated value would be worse than reporting none.
pub fn encode_descriptor_list(sessions: &[crate::session::SessionInfo]) -> Vec<u8> {
    fn put_string(out: &mut Vec<u8>, value: &str) {
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value.as_bytes());
    }

    let mut out = Vec::new();
    out.extend_from_slice(&(sessions.len() as u32).to_be_bytes());
    for info in sessions {
        out.extend_from_slice(&info.id.0);
        out.extend_from_slice(&info.pid.to_be_bytes());
        out.extend_from_slice(&0u64.to_be_bytes());
        put_string(&mut out, info.cwd.as_deref().unwrap_or(""));
        out.push(u8::from(info.attached));
        // Metadata: the foreground command, under the key the app's own daemon uses for it, so a
        // pane title resolves identically on either backend.
        match &info.foreground {
            Some(command) => {
                out.extend_from_slice(&1u32.to_be_bytes());
                put_string(&mut out, "command");
                put_string(&mut out, command);
            }
            None => out.extend_from_slice(&0u32.to_be_bytes()),
        }
    }
    out
}

/// Decodes what `encode_descriptor_list` produced, for `wr-agent list`'s own output.
pub fn decode_descriptor_list(payload: &[u8]) -> Vec<(String, bool, String)> {
    let mut out = Vec::new();
    let mut at = 0usize;
    let take = |at: &mut usize, n: usize| -> Option<&[u8]> {
        let slice = payload.get(*at..*at + n)?;
        *at += n;
        Some(slice)
    };
    let Some(count) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap())) else {
        return out;
    };
    for _ in 0..count {
        let Some(id) = take(&mut at, 16).and_then(SessionId::from_slice) else {
            break;
        };
        if take(&mut at, 4).is_none() || take(&mut at, 8).is_none() {
            break;
        }
        let Some(cwd_len) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
        else {
            break;
        };
        if take(&mut at, cwd_len as usize).is_none() {
            break;
        }
        let Some(attached) = take(&mut at, 1).map(|b| b[0] == 1) else {
            break;
        };
        let Some(entries) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
        else {
            break;
        };
        let mut command = String::from("-");
        for _ in 0..entries {
            let Some(key_len) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
            else {
                break;
            };
            let key = take(&mut at, key_len as usize)
                .map(|b| String::from_utf8_lossy(b).into_owned())
                .unwrap_or_default();
            let Some(value_len) =
                take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
            else {
                break;
            };
            let value = take(&mut at, value_len as usize)
                .map(|b| String::from_utf8_lossy(b).into_owned())
                .unwrap_or_default();
            if key == "command" {
                command = value;
            }
        }
        out.push((id.to_hyphenated(), attached, command));
    }
    out
}

/// Pumps a session's pty to the client as `Output` frames. Runs for as long as the client is
/// attached; the pty keeps running after it stops.
pub fn pump_output<S: Write>(
    sessions: &SessionStore,
    id: SessionId,
    stream: &mut S,
    service_stream: u32,
    stop: &AtomicBool,
) {
    let mut buffer = [0u8; 8192];
    loop {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        let read = sessions.with_pty(id, |pty| pty.read(&mut buffer));

        // "The child is gone" looks different on each platform: reading a pty master whose child
        // has exited yields EOF on Darwin and **EIO** on Linux. Deciding it once, here, is what
        // stops the rest of this loop from having to know that — and matching only on EOF meant
        // the branch below never ran on Linux at all, while macOS exercised it and made the code
        // look correct. Found by running the suite in a Linux container.
        let ended = match &read {
            Some(Ok(0)) => true,
            Some(Err(e)) => e.raw_os_error() == Some(libc::EIO),
            _ => false,
        };

        if ended {
            // Read the pid under the lock, reap OUTSIDE it. `pty.wait()` is a blocking waitpid,
            // and holding the session store across it stalls every other session's operations —
            // including `list`, which made two unrelated tests fail by timing out rather than by
            // being wrong.
            let pid = sessions.with_pty(id, |pty| pty.child_pid()).unwrap_or(-1);
            let mut status = 0;
            if pid > 0 {
                // Non-blocking: the read can end a moment before the child's exit is reapable, and
                // telling the client promptly matters more than the exact status.
                unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
            }
            let frame = Frame::new(FrameKind::Exited, status.to_be_bytes().to_vec());
            let envelope = Envelope::new(Service::Terminal, service_stream, frame.encode());
            let _ = stream.write_all(&envelope.encode());
            let _ = stream.flush();
            // The shell IS the session; with it gone there is nothing left to reattach to.
            sessions.kill(id);
            break;
        }

        match read {
            // The session was removed from the store, i.e. killed through the control plane.
            None => break,
            Some(Ok(n)) => {
                // The shadow sees exactly what the client sees, before the client sees it — so a
                // client that attaches a moment later is shown a screen that includes this.
                if let Some(shadow) = sessions.shadow(id) {
                    if let Ok(mut shadow) = shadow.lock() {
                        shadow.write(&buffer[..n]);
                    }
                }
                let frame = Frame::new(FrameKind::Output, buffer[..n].to_vec());
                let envelope = Envelope::new(Service::Terminal, service_stream, frame.encode());
                if stream.write_all(&envelope.encode()).is_err() {
                    break;
                }
                let _ = stream.flush();
            }
            Some(Err(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Some(Err(_)) => break,
        }
    }
}

/// Connects to a running agent, or returns None if there is nothing listening.
pub fn connect(socket: &Path) -> Option<UnixStream> {
    UnixStream::connect(socket).ok()
}

/// Spawns `wr-agent serve` detached, the way the Swift attach client spawns the daemon today:
/// `posix_spawn` with a new session, stdio to /dev/null, so it outlives whoever started it.
pub fn spawn_agent(binary: &Path, socket: &Path) -> std::io::Result<()> {
    use std::process::{Command, Stdio};
    let mut command = Command::new(binary);
    command
        .arg("serve")
        .arg("--socket")
        .arg(socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        use std::os::unix::process::CommandExt;
        command.pre_exec(|| {
            // Detach from the caller's session so the agent is not killed with it, which is the
            // whole point of a session that outlives the app.
            libc::setsid();
            Ok(())
        });
    }
    command.spawn().map(|_| ())
}

/// How a client asks for a session to exist: the id, plus what to run if it does not yet.
///
/// These travel in the Attach frame rather than being read from the agent's own environment,
/// because the agent is long-lived and shared — its environment is whatever it happened to be
/// spawned with, which may be minutes or days older than the client's, and belongs to a different
/// workroom. The client knows the shell, the directory and the metadata; the agent must be told.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AttachRequest {
    pub id: Option<SessionId>,
    pub shell: Option<OsString>,
    pub command: Option<OsString>,
    pub cwd: Option<OsString>,
    pub columns: u16,
    pub rows: u16,
    /// Passed to the child verbatim. The client's environment, not the agent's.
    pub env: Vec<(OsString, OsString)>,
}

impl AttachRequest {
    /// 16-byte id, then NUL-terminated `KEY=VALUE` entries. Deliberately not a serialisation
    /// format: the envelope already carries the version, the fields are all strings, and a
    /// dependency-free encoding keeps the agent linkable into anything.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.id.map(|i| i.0).unwrap_or([0u8; 16]));
        let mut put = |key: &str, value: &[u8]| {
            out.extend_from_slice(key.as_bytes());
            out.push(b'=');
            out.extend_from_slice(value);
            out.push(0);
        };
        if let Some(shell) = &self.shell {
            put("SHELL", shell.as_bytes());
        }
        if let Some(command) = &self.command {
            put("COMMAND", command.as_bytes());
        }
        if let Some(cwd) = &self.cwd {
            put("CWD", cwd.as_bytes());
        }
        put("COLS", self.columns.to_string().as_bytes());
        put("ROWS", self.rows.to_string().as_bytes());
        for (key, value) in &self.env {
            let mut entry = b"ENV:".to_vec();
            entry.extend_from_slice(key.as_bytes());
            out.extend_from_slice(&entry);
            out.push(b'=');
            out.extend_from_slice(value.as_bytes());
            out.push(0);
        }
        out
    }

    pub fn decode(payload: &[u8]) -> Option<AttachRequest> {
        let id = SessionId::from_slice(payload.get(..16)?)?;
        let mut request = AttachRequest {
            id: Some(id),
            ..Default::default()
        };
        for entry in payload[16..].split(|b| *b == 0) {
            if entry.is_empty() {
                continue;
            }
            let Some(split) = entry.iter().position(|b| *b == b'=') else {
                continue;
            };
            let (key, value) = (&entry[..split], &entry[split + 1..]);
            let value = OsString::from_vec(value.to_vec());
            match key {
                b"SHELL" => request.shell = Some(value),
                b"COMMAND" => request.command = Some(value),
                b"CWD" => request.cwd = Some(value),
                b"COLS" => {
                    request.columns = value.to_string_lossy().parse().unwrap_or(0);
                }
                b"ROWS" => {
                    request.rows = value.to_string_lossy().parse().unwrap_or(0);
                }
                _ => {
                    if let Some(name) = key.strip_prefix(b"ENV:") {
                        request.env.push((OsString::from_vec(name.to_vec()), value));
                    }
                }
            }
        }
        Some(request)
    }

    /// Built from the environment `PersistentSessionService.launchEnvironment` sets, so the app
    /// needs no new contract: it already exports every one of these.
    pub fn from_env() -> AttachRequest {
        Self::from_vars(|name| std::env::var_os(name), std::env::vars_os().collect())
    }

    /// The parsing, with the environment passed in.
    ///
    /// Separated from `from_env` so tests never touch the process environment. Setting variables
    /// in a test is a shared-mutable-state bug waiting to happen: these tests passed serially and
    /// raced each other under cargo's default parallelism, each clobbering the ids the others had
    /// just set.
    pub fn from_vars(
        get: impl Fn(&str) -> Option<OsString>,
        env: Vec<(OsString, OsString)>,
    ) -> AttachRequest {
        let var = |name: &str| get(name).filter(|v| !v.is_empty());
        AttachRequest {
            // An empty COMMAND is the app's "ordinary shell", not a command to run: `sh -c ""`
            // exits instantly and reads as a session that died on creation.
            id: var("WORKROOM_SESSION_ID").and_then(|v| parse_session_id(&v)),
            shell: var("WORKROOM_SESSION_SHELL").or_else(|| var("SHELL")),
            command: var("WORKROOM_SESSION_COMMAND"),
            cwd: var("WORKROOM_SESSION_CWD"),
            columns: 0,
            rows: 0,
            env,
        }
    }
}

/// The socket the app told us to use, matching `PersistentSessionService`'s
/// `WORKROOM_SESSION_SOCKET`. `attachCommand()` passes no flags, so the environment is the whole
/// contract on the app's side.
pub fn socket_from_env() -> Option<PathBuf> {
    std::env::var_os("WORKROOM_SESSION_SOCKET")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// Parses the app's `uuidString` form — uppercase and hyphenated — tolerantly: hex digits only,
/// exactly 32 of them. Tolerant because the id is a stored-data contract with Swift's `UUID`
/// description, and a formatting difference should not silently orphan a live session.
pub fn parse_session_id(value: &OsStr) -> Option<SessionId> {
    let text = String::from_utf8(value.as_bytes().to_vec()).ok()?;
    let hex: String = text.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if hex.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    for (i, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(SessionId(bytes))
}

/// Reads a session id from the environment the app sets, matching `PersistentSessionService`'s
/// `WORKROOM_SESSION_ID`.
pub fn session_id_from_env() -> Option<SessionId> {
    parse_session_id(&std::env::var_os("WORKROOM_SESSION_ID")?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instance_lock_is_exclusive() {
        let dir = std::env::temp_dir().join(format!("wr-agent-lock-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("agent.sock");

        let first = acquire_instance_lock(&socket).expect("first lock");
        assert!(
            matches!(
                acquire_instance_lock(&socket),
                Err(ServeError::AlreadyRunning(_))
            ),
            "a second agent must not be able to take the lock"
        );
        drop(first);
        // Released on drop, so a restart after a clean exit works.
        acquire_instance_lock(&socket).expect("lock after release");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The descriptor list must match what `SessionDescriptor.decodeList` expects, byte for byte,
    /// or the app silently sees no sessions on the Rust backend.
    #[test]
    fn descriptor_list_round_trips_through_our_own_decoder() {
        use crate::session::SessionInfo;
        let sessions = vec![
            SessionInfo {
                id: SessionId([3u8; 16]),
                pid: 4242,
                attached: true,
                foreground: Some("nvim".into()),
                cwd: Some("/work/room".into()),
            },
            SessionInfo {
                id: SessionId([9u8; 16]),
                pid: 77,
                attached: false,
                foreground: None,
                cwd: None,
            },
        ];
        let decoded = decode_descriptor_list(&encode_descriptor_list(&sessions));
        assert_eq!(decoded.len(), 2);
        assert_eq!(decoded[0].0, SessionId([3u8; 16]).to_hyphenated());
        assert!(decoded[0].1);
        assert_eq!(decoded[0].2, "nvim");
        assert!(!decoded[1].1);
        assert_eq!(decoded[1].2, "-");
    }

    /// The header the Swift decoder reads first, pinned explicitly: a count, then a 16-byte id.
    /// `SessionDescriptor.minimumEncodedSize` is 37, and `decodeList` rejects a count larger than
    /// `payload.count / 37` — so an encoder that disagreed here would be rejected wholesale rather
    /// than producing a visible error.
    #[test]
    fn descriptor_list_layout_matches_the_swift_decoder() {
        use crate::session::SessionInfo;
        let bytes = encode_descriptor_list(&[SessionInfo {
            id: SessionId([1u8; 16]),
            pid: 1,
            attached: true,
            foreground: None,
            cwd: None,
        }]);
        assert_eq!(&bytes[..4], &[0, 0, 0, 1], "count is a big-endian u32");
        assert_eq!(&bytes[4..20], &[1u8; 16], "then the 16-byte identifier");
        // 4 (count) + 16 + 4 (pid) + 8 (tty) + 4 (empty cwd) + 1 (attached) + 4 (no metadata)
        assert_eq!(bytes.len(), 41);
        assert!(
            1 <= bytes.len() / 37,
            "a single descriptor must satisfy Swift's minimumEncodedSize guard"
        );
    }

    #[test]
    fn an_empty_descriptor_list_is_just_a_zero_count() {
        assert_eq!(encode_descriptor_list(&[]), vec![0, 0, 0, 0]);
        assert!(decode_descriptor_list(&[0, 0, 0, 0]).is_empty());
    }

    #[test]
    fn a_truncated_descriptor_list_decodes_to_what_survived() {
        use crate::session::SessionInfo;
        let full = encode_descriptor_list(&[SessionInfo {
            id: SessionId([5u8; 16]),
            pid: 1,
            attached: true,
            foreground: None,
            cwd: None,
        }]);
        // Cut mid-descriptor: no panic, no phantom entry.
        assert!(decode_descriptor_list(&full[..20]).is_empty());
    }

    #[test]
    fn attach_request_round_trips() {
        let request = AttachRequest {
            id: Some(SessionId([7u8; 16])),
            shell: Some(OsString::from("/bin/zsh")),
            command: Some(OsString::from("npm run dev")),
            cwd: Some(OsString::from("/Users/x/dev/workroom")),
            columns: 120,
            rows: 40,
            env: vec![
                (OsString::from("TERM"), OsString::from("xterm-ghostty")),
                (OsString::from("PATH"), OsString::from("/usr/bin:/bin")),
            ],
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded, request);
    }

    /// A value containing `=` must survive: PATH-like variables and commands are full of them, and
    /// splitting on the LAST rather than the FIRST separator would quietly corrupt them.
    #[test]
    fn attach_request_keeps_equals_signs_in_values() {
        let request = AttachRequest {
            id: Some(SessionId([1u8; 16])),
            command: Some(OsString::from("FOO=bar make test ARGS=-v")),
            env: vec![(OsString::from("K"), OsString::from("a=b=c"))],
            ..Default::default()
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded.command, request.command);
        assert_eq!(decoded.env, request.env);
    }

    #[test]
    fn attach_request_survives_empty_optional_fields() {
        let request = AttachRequest {
            id: Some(SessionId([2u8; 16])),
            ..Default::default()
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded, request);
    }

    #[test]
    fn attach_request_rejects_a_short_payload() {
        assert!(AttachRequest::decode(&[0u8; 8]).is_none());
    }

    /// The app sets these and passes NO flags, so the environment alone has to be sufficient.
    /// The app sets these and passes NO flags, so the environment alone has to be sufficient.
    #[test]
    fn attach_request_reads_the_app_environment_contract() {
        let vars = [
            (
                "WORKROOM_SESSION_ID",
                "550e8400-e29b-41d4-a716-446655440000",
            ),
            ("WORKROOM_SESSION_SHELL", "/bin/fish"),
            ("WORKROOM_SESSION_CWD", "/work/room"),
            ("WORKROOM_SESSION_COMMAND", ""),
        ];
        let request = AttachRequest::from_vars(
            |name| {
                vars.iter()
                    .find(|(k, _)| *k == name)
                    .map(|(_, v)| OsString::from(*v))
            },
            vec![(OsString::from("TERM"), OsString::from("xterm-ghostty"))],
        );
        assert_eq!(
            request.id.map(|i| i.to_hyphenated()).as_deref(),
            Some("550e8400-e29b-41d4-a716-446655440000")
        );
        assert_eq!(request.shell.as_deref(), Some(OsStr::new("/bin/fish")));
        assert_eq!(request.cwd.as_deref(), Some(OsStr::new("/work/room")));
        // An empty COMMAND is "ordinary shell", not a command — `sh -c ""` exits instantly and
        // reads as a session that died on creation.
        assert_eq!(request.command, None);
        assert_eq!(request.env.len(), 1);
    }

    /// Falls back to the plain SHELL when the app did not name one.
    #[test]
    fn attach_request_falls_back_to_the_plain_shell_variable() {
        let request = AttachRequest::from_vars(
            |name| (name == "SHELL").then(|| OsString::from("/bin/zsh")),
            Vec::new(),
        );
        assert_eq!(request.shell.as_deref(), Some(OsStr::new("/bin/zsh")));
    }

    #[test]
    fn parses_the_apps_uuid_format() {
        let id = parse_session_id(OsStr::new("550E8400-E29B-41D4-A716-446655440000")).expect("id");
        assert_eq!(id.to_hyphenated(), "550e8400-e29b-41d4-a716-446655440000");
        // Unhyphenated is the same id: the separators carry no information.
        assert_eq!(
            parse_session_id(OsStr::new("550e8400e29b41d4a716446655440000")),
            Some(id)
        );
    }

    #[test]
    fn rejects_a_malformed_session_id() {
        assert!(parse_session_id(OsStr::new("not-a-uuid")).is_none());
        assert!(parse_session_id(OsStr::new("")).is_none());
        // 31 and 33 hex digits are both wrong, and neither may be silently padded or truncated.
        assert!(parse_session_id(OsStr::new(&"a".repeat(31))).is_none());
        assert!(parse_session_id(OsStr::new(&"a".repeat(33))).is_none());
    }
}
