//! The harness the daemon's process-level tests share: a real daemon and real clients over a real
//! socket, each killed when its test ends.

use std::io::{BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use workroomd::testing::{SessionStore, handle_connection};
use wr_protocol::envelope::Hello;

pub fn daemon_binary() -> PathBuf {
    // `CARGO_BIN_EXE_workroomd` is resolved at COMPILE time and bakes in an absolute path from the
    // build host. That is right for `cargo test`, and wrong the moment the cross-compiled test
    // binary is carried to the machine it targets — which is exactly how the Linux side of this
    // crate is verified. `WORKROOMD_BIN` lets the runner say where the binary actually is.
    match std::env::var_os("WORKROOMD_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_workroomd")),
    }
}

/// A spawned daemon or attach client that is killed when the test ends, panic or not.
///
/// Every test here already finishes with `let _ = daemon.kill()`, and that line does not run when an
/// assertion fails — an unwind skips straight past it. The daemon does not clean itself up either:
/// it exits when idle, but a leaked one still holds the session's shell, so it is never idle. A
/// week of failing runs during development left 88 daemons and their shells alive on the developer's
/// machine. `Drop` runs during unwinding; an explicit kill at the end of the body does not.
pub struct Spawned(pub Child);

impl Drop for Spawned {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl std::ops::Deref for Spawned {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}

impl std::ops::DerefMut for Spawned {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}

pub struct Workspace {
    pub dir: PathBuf,
}

impl Workspace {
    pub fn new(name: &str) -> Workspace {
        let dir =
            std::env::temp_dir().join(format!("workroomd-it-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        Workspace { dir }
    }

    pub fn socket(&self) -> PathBuf {
        self.dir.join("workroomd.sock")
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

pub fn start_daemon(socket: &Path) -> Spawned {
    start_daemon_with(socket, &[])
}

/// `start_daemon` with more `serve` flags.
pub fn start_daemon_with(socket: &Path, flags: &[&std::ffi::OsStr]) -> Spawned {
    let child = Command::new(daemon_binary())
        .args(["serve", "--socket"])
        .arg(socket)
        .args(["--idle-timeout", "60"])
        .args(flags)
        // The daemon spawns $SHELL, so without this these tests run the DEVELOPER's shell — an
        // interactive zsh with a git-aware prompt and a line editor that redraws pending typeahead
        // on reattach. That redraw looks exactly like a repaint and made an earlier version of the
        // repaint test below pass with the feature switched off.
        .env("SHELL", "/bin/sh")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn daemon");
    let child = Spawned(child);
    wait_for(Duration::from_secs(5), || socket.exists());
    assert!(socket.exists(), "daemon never bound its socket");
    child
}

pub fn wait_for(timeout: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}

pub fn attach(socket: &Path, session: &str) -> Spawned {
    attach_with(socket, session, &[])
}

/// `attach` with more flags, such as `--no-create` for a restored pane.
pub fn attach_with(socket: &Path, session: &str, flags: &[&str]) -> Spawned {
    attach_with_env(socket, session, flags, &[])
}

/// `attach_with` and more of the session variables the app exports, such as a run command's.
pub fn attach_with_env(
    socket: &Path,
    session: &str,
    flags: &[&str],
    env: &[(&str, &str)],
) -> Spawned {
    let child = Command::new(daemon_binary())
        .args(["attach", "--socket"])
        .arg(socket)
        .args(["--session", session])
        .args(flags)
        // The shell now comes from the CLIENT's environment, which is the point — the daemon is
        // long-lived and shared, so its own environment is the wrong source. That makes this pin
        // load-bearing rather than tidy: without it these tests run the developer's interactive
        // shell, which exits immediately on a piped stdin and takes the session with it.
        .env("SHELL", "/bin/sh")
        .envs(env.iter().copied())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn attach");
    Spawned(child)
}

/// A client's stdout, readable more than once.
///
/// It owns the reader thread, because taking `child.stdout` is a one-shot: an earlier version
/// called a `read_until` helper twice on the same client and panicked on the second take.
pub struct ClientReader {
    rx: std::sync::mpsc::Receiver<String>,
    seen: String,
}

impl ClientReader {
    pub fn new(child: &mut Child) -> ClientReader {
        let stdout = child.stdout.take().expect("stdout");
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut byte = [0u8; 1];
            while reader.read(&mut byte).unwrap_or(0) > 0 {
                if tx
                    .send(String::from_utf8_lossy(&byte).into_owned())
                    .is_err()
                {
                    return;
                }
            }
        });
        ClientReader {
            rx,
            seen: String::new(),
        }
    }

    /// Accumulates until `needle` appears or the deadline passes. Everything read so far is kept,
    /// so a later call continues rather than starting over.
    pub fn read_until(&mut self, needle: &str, timeout: Duration) -> &str {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if self.seen.contains(needle) {
                break;
            }
            match self.rx.recv_timeout(Duration::from_millis(100)) {
                Ok(chunk) => self.seen.push_str(&chunk),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => break,
            }
        }
        &self.seen
    }

    /// Reads whatever is still arriving, for `quiet`, then stops. Used to be sure the shell has
    /// finished echoing before the client is killed — leftover output would otherwise reach the
    /// NEXT client as ordinary buffered bytes and make a repaint assertion prove nothing.
    pub fn drain(&mut self, quiet: Duration) {
        while let Ok(chunk) = self.rx.recv_timeout(quiet) {
            self.seen.push_str(&chunk);
        }
    }
}

/// Sends one Control frame to the daemon at `socket` and returns its first reply frame, as the
/// app's control client does.
pub fn control(socket: &Path, frame: wr_protocol::frame::Frame) -> wr_protocol::frame::Frame {
    use wr_protocol::envelope::{Envelope, EnvelopeDecoder, Service};
    use wr_protocol::frame::FrameDecoder;

    let mut stream = UnixStream::connect(socket).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .expect("timeout");
    stream
        .write_all(&Hello::current("test").encode())
        .expect("greet");
    let mut greeting = Vec::new();
    let mut byte = [0u8; 1];
    while Hello::decode(&greeting)
        .expect("a daemon greeting")
        .is_none()
    {
        stream.read_exact(&mut byte).expect("greeting byte");
        greeting.push(byte[0]);
    }
    stream
        .write_all(&Envelope::new(Service::Control, 1, frame.encode()).encode())
        .expect("send");
    let mut envelopes = EnvelopeDecoder::new();
    let mut buffer = [0u8; 4096];
    loop {
        let n = stream
            .read(&mut buffer)
            .unwrap_or_else(|e| panic!("no reply to {frame:?}: {e}"));
        assert_ne!(n, 0, "the daemon hung up without answering");
        envelopes.push(&buffer[..n]);
        while let Ok(Some(envelope)) = envelopes.next_envelope() {
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            if let Ok(Some(frame)) = frames.next_frame() {
                return frame;
            }
        }
    }
}

pub fn list_sessions(socket: &Path) -> String {
    let output = Command::new(daemon_binary())
        .args(["list", "--socket"])
        .arg(socket)
        .output()
        .expect("list");
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// Whether the daemon under test was built with the shadow terminal.
///
/// Empty counts as absent. `var_os` returns `Some("")` for a variable that is set but empty, which
/// is exactly what a container runner passing `--env NAME=` produces — and an `is_none()` check
/// then runs assertions against a build that cannot satisfy them.
pub fn has_terminal_state() -> bool {
    std::env::var_os("WORKROOMD_HAS_TERMINAL_STATE")
        .map(|value| !value.is_empty())
        .unwrap_or(false)
}

/// A client of a daemon's envelope protocol over any byte stream, shared by the service tests:
/// the request/reply services' JSON requests and their chunked replies, the envelopes in between,
/// and a Terminal stream's output. Each test file wraps one with what is particular to its service.
///
/// Envelopes are sorted as they arrive: Terminal output into `seen`, every other envelope into
/// `other` until something asks for it, so output that keeps flowing while a request is in flight
/// and the request's reply never eat each other's bytes.
pub struct RpcClient<R: Read = UnixStream, W: Write = UnixStream> {
    pub reader: R,
    pub writer: W,
    decoder: wr_protocol::envelope::EnvelopeDecoder,
    /// Terminal output so far.
    pub seen: Vec<u8>,
    /// Envelopes for every service but Terminal, in arrival order, kept until asked for.
    pub other: Vec<wr_protocol::envelope::Envelope>,
    /// The stream the next `request` takes. Stream 0 is the daemon's events, never a request's.
    pub next_stream: u32,
    /// The stream ended. `read_until` and `pump` stop on it; `next` and `next_on` panic on it, so a
    /// check that nothing arrives cannot pass on a daemon that hung up.
    pub closed: bool,
}

impl RpcClient {
    /// Connects to a daemon served in this process with a session store of its own
    /// (`connect_in_process`). Reads wait at most `read_timeout` each, from after the greeting:
    /// the greeting can be slow on a loaded machine, and a timeout during it would panic the test
    /// for a scheduling reason.
    pub fn connect(name: &str, read_timeout: Duration) -> (RpcClient, std::thread::JoinHandle<()>) {
        Self::connect_to(name, SessionStore::new(), read_timeout)
    }

    /// `connect` to a session store the test holds too.
    pub fn connect_to(
        name: &str,
        sessions: SessionStore,
        read_timeout: Duration,
    ) -> (RpcClient, std::thread::JoinHandle<()>) {
        let (stream, server) = connect_in_process_to(name, sessions);
        stream.set_read_timeout(Some(read_timeout)).unwrap();
        let reader = stream.try_clone().unwrap();
        (RpcClient::over(reader, stream), server)
    }
}

impl<R: Read, W: Write> RpcClient<R, W> {
    /// A client over a stream that has not been greeted yet (`handshake`), or already has.
    pub fn over(reader: R, writer: W) -> RpcClient<R, W> {
        RpcClient {
            reader,
            writer,
            decoder: wr_protocol::envelope::EnvelopeDecoder::new(),
            seen: Vec::new(),
            other: Vec::new(),
            next_stream: 1,
            closed: false,
        }
    }

    /// One read that honours a deadline. `WouldBlock` (a non-blocking reader, or a read timeout)
    /// means "not yet" rather than an error — treating it as one is what made every read site
    /// here either hang or spuriously fail. None when the stream ended (`closed`) or the deadline
    /// passed.
    pub fn read_some(&mut self, buffer: &mut [u8], deadline: Instant) -> Option<usize> {
        while Instant::now() < deadline {
            match self.reader.read(buffer) {
                Ok(0) => {
                    self.closed = true;
                    return None;
                }
                Ok(n) => return Some(n),
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(_) => {
                    self.closed = true;
                    return None;
                }
            }
        }
        None
    }

    /// Greets the daemon and reads its greeting, within five seconds.
    pub fn handshake(&mut self) {
        self.writer
            .write_all(&Hello::current("test-client").encode())
            .expect("send hello");
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut greeting = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            if let Ok(Some(_)) = Hello::decode(&greeting) {
                break;
            }
            let n = self
                .read_some(&mut byte, deadline)
                .expect("the daemon closed the stream or never greeted");
            greeting.push(byte[..n][0]);
        }
    }

    /// Sends one envelope.
    pub fn send_payload(
        &mut self,
        service: wr_protocol::envelope::Service,
        stream: u32,
        payload: Vec<u8>,
    ) {
        self.writer
            .write_all(&wr_protocol::envelope::Envelope::new(service, stream, payload).encode())
            .expect("send");
    }

    /// Sends one frame.
    pub fn send(
        &mut self,
        service: wr_protocol::envelope::Service,
        stream: u32,
        frame: wr_protocol::frame::Frame,
    ) {
        self.send_payload(service, stream, frame.encode());
    }

    /// Sends a frame one byte at a time. A remote stream can split anywhere, and the daemon must
    /// not care — a decoder that assumed whole frames would pass every other test here.
    pub fn send_bytewise(
        &mut self,
        service: wr_protocol::envelope::Service,
        stream: u32,
        frame: wr_protocol::frame::Frame,
    ) {
        let bytes = wr_protocol::envelope::Envelope::new(service, stream, frame.encode()).encode();
        for byte in bytes {
            self.writer.write_all(&[byte]).expect("send byte");
        }
    }

    /// Reads once and sorts what arrived: terminal output into `seen`, the rest into `other`.
    /// False when the stream ended or the deadline passed.
    pub fn pump(&mut self, deadline: Instant) -> bool {
        use wr_protocol::envelope::Service;
        use wr_protocol::frame::{FrameDecoder, FrameKind};
        let mut buffer = [0u8; 65536];
        let Some(n) = self.read_some(&mut buffer, deadline) else {
            return false;
        };
        self.decoder.push(&buffer[..n]);
        // A decode error panics here, naming itself, rather than surfacing later as a timeout.
        while let Some(envelope) = self.decoder.next_envelope().expect("a malformed envelope") {
            if envelope.service != Service::Terminal {
                self.other.push(envelope);
                continue;
            }
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            while let Some(frame) = frames.next_frame().expect("a malformed frame") {
                if frame.kind == FrameKind::Output {
                    self.seen.extend_from_slice(&frame.payload);
                }
            }
        }
        true
    }

    /// The next envelope that is not Terminal output, on any service and stream, in arrival
    /// order; None when nothing comes within `timeout`. Panics when the daemon hung up: silence
    /// and a closed connection are not the same answer.
    pub fn next(&mut self, timeout: Duration) -> Option<wr_protocol::envelope::Envelope> {
        let deadline = Instant::now() + timeout;
        loop {
            if !self.other.is_empty() {
                return Some(self.other.remove(0));
            }
            if !self.pump(deadline) {
                assert!(!self.closed, "the daemon closed the connection");
                return None;
            }
        }
    }

    /// The next envelope on `service`/`stream`, setting aside the rest; None when nothing comes
    /// within `timeout`. Panics when the daemon hung up, as `next` does.
    pub fn next_on(
        &mut self,
        service: wr_protocol::envelope::Service,
        stream: u32,
        timeout: Duration,
    ) -> Option<wr_protocol::envelope::Envelope> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(index) = self
                .other
                .iter()
                .position(|e| e.service == service && e.stream == stream)
            {
                return Some(self.other.remove(index));
            }
            if !self.pump(deadline) {
                assert!(!self.closed, "the daemon closed the connection");
                return None;
            }
        }
    }

    /// The next envelope on `service`/`stream`, or a panic naming what never came.
    pub fn envelope(
        &mut self,
        service: wr_protocol::envelope::Service,
        stream: u32,
        timeout: Duration,
    ) -> wr_protocol::envelope::Envelope {
        self.next_on(service, stream, timeout)
            .unwrap_or_else(|| panic!("nothing arrived on {service:?} stream {stream}"))
    }

    /// The stream the next request takes.
    pub fn take_stream(&mut self) -> u32 {
        let stream = self.next_stream;
        self.next_stream += 1;
        stream
    }

    /// One request to a JSON service (VCS, File, Status, Layout, ProgramStatus): the request goes
    /// out as one envelope, and the reply comes back as chunks whose first byte says whether more
    /// follow.
    pub fn request(
        &mut self,
        service: wr_protocol::envelope::Service,
        stream: u32,
        request: &serde_json::Value,
    ) -> serde_json::Value {
        self.send_payload(service, stream, serde_json::to_vec(request).unwrap());
        let mut assembled = Vec::new();
        loop {
            let envelope = self.envelope(service, stream, Duration::from_secs(20));
            let (last, body) = envelope.payload.split_first().expect("empty reply chunk");
            assembled.extend_from_slice(body);
            if *last == 1 {
                return serde_json::from_slice(&assembled).expect("a JSON reply");
            }
        }
    }

    /// Accumulates Terminal output until `needle` appears, or the deadline passes.
    pub fn read_until(&mut self, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if String::from_utf8_lossy(&self.seen).contains(needle) {
                break;
            }
            if !self.pump(deadline) {
                break;
            }
        }
        String::from_utf8_lossy(&self.seen).into_owned()
    }
}

/// A connection to a daemon served in this process, greeted as `name`: the daemon's side runs
/// `handle_connection` on a thread of its own, with a session store of its own. The stream has no
/// read timeout yet; each caller picks its own once the greeting is done.
pub fn connect_in_process(name: &str) -> (UnixStream, std::thread::JoinHandle<()>) {
    connect_in_process_to(name, SessionStore::new())
}

/// `connect_in_process` to a session store the test holds too, so it can make sessions directly.
pub fn connect_in_process_to(
    name: &str,
    sessions: SessionStore,
) -> (UnixStream, std::thread::JoinHandle<()>) {
    let (mut stream, server) = UnixStream::pair().unwrap();
    let server = std::thread::spawn(move || {
        let _ = handle_connection(server, sessions);
    });
    stream.write_all(&Hello::current(name).encode()).unwrap();
    let mut greeting = Vec::new();
    while Hello::decode(&greeting).unwrap().is_none() {
        let mut byte = [0u8];
        stream.read_exact(&mut byte).unwrap();
        greeting.push(byte[0]);
    }
    (stream, server)
}
