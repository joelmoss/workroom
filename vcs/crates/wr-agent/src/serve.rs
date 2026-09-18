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
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::protocol::envelope::{
    negotiate, Envelope, EnvelopeDecoder, Hello, ProtocolError, Service,
};
use crate::protocol::frame::{Frame, FrameDecoder, FrameKind, MAX_PAYLOAD_SIZE};
use crate::session::{SessionId, SessionSpec, SessionStore, SharedWriter};
use crate::shell;
use crate::transport::Transport;

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
                    // `connections` drops as soon as `handle_connection` returns, but `vcs::dispatch`
                    // answers on a DETACHED thread that outlives it — a client that disconnects (or
                    // whose request already tripped the app-side timeout) while its VCS request is
                    // still running, e.g. a JJ snapshot mid in-process working-copy rewrite, would
                    // otherwise let `connections` and `sessions` both read empty while that thread is
                    // still mutating the repository. `crate::vcs::is_busy()` is the only thing that
                    // actually knows.
                    let busy = self.connections.load(Ordering::SeqCst) > 0
                        || !self.sessions.is_empty()
                        || crate::vcs::is_busy();
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
/// Generic over the transport, which is the whole point: the driver contract is a bidirectional
/// byte stream, so `ssh host wr-agent serve --stdio`, a provider's exec channel and a local unix
/// socket are all the same code path here. It also means the remote protocol can be tested over a
/// pair of pipes with no container, no ssh and no provider — see `transport::PipeTransport`.
pub fn handle_connection<T: Transport>(
    transport: T,
    sessions: SessionStore,
) -> Result<(), ProtocolError> {
    let (mut reader, writer) = transport.split().map_err(|_| ProtocolError::NotAnAgent)?;
    // One writer, shared, and type-erased. A socket could be cloned instead, but a pipe or an exec
    // channel cannot, and the agent must not require a transport that can. Boxed because the
    // SESSION holds it now — its reader outlives this connection, and the next client may arrive
    // over a different kind of stream. Contention is negligible: the command loop writes only
    // replies, and the reader holds the lock for one write at a time.
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(writer)));

    let send = |bytes: &[u8]| -> bool {
        match writer.lock() {
            Ok(mut writer) => writer
                .write_all(bytes)
                .and_then(|()| writer.flush())
                .is_ok(),
            Err(_) => false,
        }
    };

    let local = Hello::current(BUILD);
    if !send(&local.encode()) {
        return Err(ProtocolError::NotAnAgent);
    }

    // Read the peer's greeting first — everything after depends on the negotiated version, so
    // parsing an envelope before it would be parsing at an unknown version.
    let mut greeting = Vec::new();
    let mut byte = [0u8; 1];
    let remote = loop {
        if let Some((hello, _)) = Hello::decode(&greeting)? {
            break hello;
        }
        match reader.read(&mut byte) {
            Ok(0) => return Err(ProtocolError::NotAnAgent),
            Ok(_) => greeting.push(byte[0]),
            Err(_) => return Err(ProtocolError::NotAnAgent),
        }
    };
    negotiate(&local, &remote)?;

    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let mut attached: Option<SessionId> = None;
    // Identifies THIS attachment, so ending this connection cannot detach a client that has since
    // taken the session over.
    let mut token = 0u64;

    // The decoder's failure is carried out rather than returned with `?`, so that EVERY exit runs
    // the detach below. It used to propagate straight out of the function: an unknown service byte
    // or an oversized declared length left the client registered on the session, holding this
    // connection's write half — so the fd stayed open, the session reported `attached: true`
    // forever, and if that client was the size owner nobody else could claim the geometry. A quiet
    // session never notices, because the eviction that would clean it up only happens on a failed
    // delivery.
    let mut failure = None;
    'outer: loop {
        loop {
            match decoder.next_envelope() {
                Ok(Some(envelope)) => {
                    if let Some(reply) = dispatch(
                        &envelope,
                        &sessions,
                        &mut attached,
                        &mut token,
                        &writer,
                        &send,
                    ) {
                        if !send(&reply.encode()) {
                            break 'outer;
                        }
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    failure = Some(e);
                    break 'outer;
                }
            }
        }
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => decoder.push(&buffer[..n]),
            Err(_) => break,
        }
    }

    // The session keeps its reader; only the client goes. There is nothing to stop and nothing to
    // join — which is also why a detached session keeps draining its pty instead of wedging the
    // shell behind a full output queue.
    if let Some(id) = attached {
        sessions.detach(id, token);
    }
    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Handles one envelope. Returns a reply to send, if any.
///
/// `send` is passed in as well as a reply being returned, because the Attach arm must emit
/// `Attached` BEFORE the session paints the screen behind it — and the painting happens inside
/// `SessionStore::attach`, under the lock that keeps it from being interleaved with live output.
fn dispatch(
    envelope: &Envelope,
    sessions: &SessionStore,
    attached: &mut Option<SessionId>,
    token: &mut u64,
    writer: &SharedWriter,
    send: &dyn Fn(&[u8]) -> bool,
) -> Option<Envelope> {
    if envelope.service == Service::Vcs {
        crate::vcs::dispatch(envelope, writer);
        return None;
    }
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
            // A new session must register its first client before its reader starts: a command
            // such as `echo` can exit before attach, taking its output and exit status with it.
            let attach = || {
                send(
                    &Envelope::new(
                        Service::Control,
                        envelope.stream,
                        Frame::control(FrameKind::Attached).encode(),
                    )
                    .encode(),
                )
                .then_some(())
                .ok_or(crate::session::SessionError::NotFound(id.to_hyphenated()))?;
                sessions.attach(
                    id,
                    Arc::clone(writer),
                    envelope.stream,
                    request.columns,
                    request.rows,
                )
            };
            // Create on first attach, reattach afterwards. One code path, so a client that
            // crashed and came back does not have to know which case it is in.
            let result = if sessions.contains(id) {
                attach()
            } else {
                // Not `<shell>` with no arguments: see `shell::invocation`. Spawning the shell
                // bare cost the login profile and ghostty's shell integration, which showed up in
                // the app as panes stuck on the title the user's own prompt sets.
                // **The session's own variables do not reach the session's shell**, matching what
                // the Swift attach client has always done (`SessionAttachClient.makeRequest`
                // filters the same prefix before sending). Leaking them had two consequences, both
                // real: `wr-agent attach` typed inside a pane picked up THAT pane's id and socket
                // from its own environment and attached a second relay to the session it was
                // running in, with the pty fanning output to both; and `run_attach`'s "was I
                // invoked by the app" test — which reads exactly these variables — was true for
                // anything the user typed in a pane, so the usage-instead-of-nested-shell guard
                // could never fire there.
                let child_environment: Vec<(OsString, OsString)> = request
                    .env
                    .iter()
                    .filter(|(key, _)| !key.to_string_lossy().starts_with("WORKROOM_SESSION_"))
                    .cloned()
                    .collect();
                let invocation = shell::invocation(
                    &request
                        .command
                        .clone()
                        .unwrap_or_default()
                        .to_string_lossy(),
                    &request.shell.clone().unwrap_or_default().to_string_lossy(),
                    &request
                        .resources
                        .clone()
                        .unwrap_or_default()
                        .to_string_lossy(),
                    &child_environment,
                );
                sessions.create_then(
                    SessionSpec {
                        id,
                        program: &invocation.program,
                        argv0: invocation.arguments.first().map(|a| a.as_os_str()),
                        args: &invocation.arguments[1..],
                        env: &invocation.environment,
                        cwd: request.cwd.as_deref(),
                        columns: request.columns,
                        rows: request.rows,
                    },
                    |_| attach(),
                )
            };
            match result {
                Ok((_, granted)) => {
                    *attached = Some(id);
                    *token = granted;
                    None
                }
                Err(e) => reply(Frame::new(FrameKind::Failure, e.to_string().into_bytes())),
            }
        }
        FrameKind::Input => {
            let id = (*attached)?;
            // Through the session, not straight at the pty, for two reasons: it writes with
            // `write_all` (the master is non-blocking, so a paste bigger than the pty's input queue
            // short-writes and the tail would be dropped in silence), and typing is also how a
            // client CLAIMS the session's size, which only the session can arbitrate.
            sessions.write_input(id, *token, &frame.payload);
            None
        }
        FrameKind::Resize => {
            let id = (*attached)?;
            if frame.payload.len() >= 4 {
                let columns = u16::from_be_bytes([frame.payload[0], frame.payload[1]]);
                let rows = u16::from_be_bytes([frame.payload[2], frame.payload[3]]);
                // Recorded always, applied only if this client owns the size or nobody does — a
                // background window resizing must not move the pty out from under whoever is
                // typing in another one.
                sessions.resize(id, *token, columns, rows);
            }
            None
        }
        FrameKind::List => reply(list_reply(encode_descriptor_list(&sessions.list()))),
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
/// Wraps an encoded session list in the frame to send, refusing one that is too big.
///
/// A `Sessions` reply grows with the session count and each session's cwd, and unlike output it
/// goes out as ONE frame. `Frame::encode` panics past the cap rather than truncating — and even if
/// it did not, a client that sees a declared length over the cap fails its decoder permanently, so
/// an over-long list would not merely fail, it would poison every later frame on that connection.
/// Answer with the failure the app already knows how to show instead.
fn list_reply(payload: Vec<u8>) -> Frame {
    if payload.len() > MAX_PAYLOAD_SIZE {
        return Frame::new(
            FrameKind::Failure,
            format!(
                "session list of {} bytes exceeds the {MAX_PAYLOAD_SIZE}-byte frame cap",
                payload.len()
            )
            .into_bytes(),
        );
    }
    Frame::new(FrameKind::Sessions, payload)
}

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
    /// Ghostty's bundled resources, whose `shell-integration` subtree the shell is pointed at.
    /// Without it the shell loads the user's own config directly and the app loses OSC 2/7 —
    /// which is what a pane's title and working directory are read from.
    pub resources: Option<OsString>,
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
        if let Some(resources) = &self.resources {
            put("RESOURCES", resources.as_bytes());
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
                b"RESOURCES" => request.resources = Some(value),
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
            resources: var("WORKROOM_SESSION_RESOURCES"),
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

    /// The number in an `Exited` frame is the one a shell would report, not the raw `waitpid`
    /// status — the two differ by a byte shift, and `SessionAttachClient` hands whatever arrives
    /// straight back as its own exit status.
    #[test]
    fn an_exit_status_becomes_the_code_a_shell_would_report() {
        assert_eq!(exit_code(7 << 8), 7, "exit 7, not the raw 1792");
        assert_eq!(exit_code(0), 0);
        assert_eq!(exit_code(255 << 8), 255, "the widest normal exit");
        assert_eq!(
            exit_code(libc::SIGKILL),
            128 + 9,
            "killed, by shell convention"
        );
        assert_eq!(exit_code(libc::SIGHUP), 128 + 1);
        assert_eq!(exit_code(0o177), 0, "stopped is not an exit");
    }

    /// A `Sessions` reply is one frame, and `Frame::encode` panics rather than truncating past the
    /// cap. Reply with a failure instead — which the app already renders — rather than killing the
    /// connection thread and leaving the client waiting for a frame that will never come.
    #[test]
    fn an_oversized_session_list_is_refused_rather_than_panicking() {
        let ordinary = list_reply(encode_descriptor_list(&[]));
        assert_eq!(ordinary.kind, FrameKind::Sessions);

        let over = list_reply(vec![0u8; MAX_PAYLOAD_SIZE + 1]);
        assert_eq!(over.kind, FrameKind::Failure);
        // And the refusal must itself be sendable, which is the whole point.
        let _ = over.encode();
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
            resources: Some(OsString::from(
                "/Applications/Workroom.app/Contents/Resources/ghostty",
            )),
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
