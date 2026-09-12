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

use std::io::{Read, Write};
use std::os::unix::ffi::OsStringExt;
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
            let id = SessionId::from_slice(frame.payload.get(..16)?)?;
            // Create on first attach, reattach afterwards. One code path, so a client that
            // crashed and came back does not have to know which case it is in.
            let result = if sessions.contains(id) {
                sessions.attach(id).map(|_| ())
            } else {
                let shell = std::env::var_os("SHELL").unwrap_or_else(|| "/bin/sh".into());
                let env: Vec<_> = std::env::vars_os().collect();
                sessions
                    .create(SessionSpec {
                        id,
                        program: &shell,
                        args: &[],
                        env: &env,
                        cwd: None,
                        columns: 80,
                        rows: 24,
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
            }
            None
        }
        FrameKind::List => {
            // One line per session: id, attached flag, foreground command. Plain text because the
            // control plane is for humans and logs as much as for the app.
            let body = sessions
                .list()
                .into_iter()
                .map(|info| {
                    format!(
                        "{} {} {}",
                        info.id.to_hyphenated(),
                        if info.attached {
                            "attached"
                        } else {
                            "detached"
                        },
                        info.foreground.unwrap_or_else(|| "-".into())
                    )
                })
                .collect::<Vec<_>>()
                .join("\n");
            reply(Frame::new(FrameKind::Sessions, body.into_bytes()))
        }
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
        match read {
            None => break,
            Some(Ok(0)) => break,
            Some(Ok(n)) => {
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

/// Reads a session id from the environment the app sets, matching `PersistentSessionService`'s
/// `WORKROOM_SESSION_ID`.
pub fn session_id_from_env() -> Option<SessionId> {
    let raw = std::env::var_os("WORKROOM_SESSION_ID")?;
    let text = String::from_utf8(raw.into_vec()).ok()?;
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

    #[test]
    fn parses_a_session_id_from_the_environment() {
        // Safety: single-threaded within this test, and the variable is only read here.
        unsafe {
            std::env::set_var(
                "WORKROOM_SESSION_ID",
                "550E8400-E29B-41D4-A716-446655440000",
            );
        }
        let id = session_id_from_env().expect("parse");
        assert_eq!(id.to_hyphenated(), "550e8400-e29b-41d4-a716-446655440000");
        unsafe { std::env::remove_var("WORKROOM_SESSION_ID") };
        assert!(session_id_from_env().is_none());
    }

    #[test]
    fn rejects_a_malformed_session_id() {
        unsafe { std::env::set_var("WORKROOM_SESSION_ID", "not-a-uuid") };
        assert!(session_id_from_env().is_none());
        unsafe { std::env::remove_var("WORKROOM_SESSION_ID") };
    }
}
