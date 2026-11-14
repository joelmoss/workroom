//! `workroomd serve`: owns the ptys, speaks the envelope over a stream.
//!
//! The transport is a `UnixListener` locally and whatever bidirectional stream a driver opens
//! remotely, so the connection handler below takes `Read + Write` rather than a socket — that is
//! the whole reason the local path is also the remote path's test harness.
//!
//! **Single instance, by `flock`.** Two daemons on one socket would each own half the sessions and
//! neither would find the other's, which presents as terminals vanishing. The lock is held for the
//! process's life and released by the kernel on exit, including a crash — no stale-lock cleanup to
//! get wrong.
//!
//! **Idle self-exit is kept exactly as the Swift helper has it**, and the design doc says why the
//! earlier plan to remove it did not survive scrutiny: diffs, history and watches are things a
//! *connected client* asks for, so a daemon with no connections and no ptys is holding nothing
//! anyone can lose. The one thing that must outlive the app is a live terminal, which is precisely
//! what the rule already protects.

use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::daemon::rpc::{self, SharedWriter};
use crate::daemon::transport::Transport;
use crate::terminal::session::SessionStore;
use wr_protocol::envelope::{Envelope, EnvelopeDecoder, Hello, ProtocolError, Service, negotiate};
use wr_protocol::frame::{Frame, FrameDecoder, FrameKind};
use wr_protocol::reply::Reply;

pub const BUILD: &str = concat!("workroomd ", env!("CARGO_PKG_VERSION"));

/// How long a daemon with no sessions and no clients waits before exiting.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a connection that said it pings (`FrameKind::Pings`) may go with nothing received
/// before it is closed (ADR 0075): four of the app's 15 s pings. A Mac that slept or dropped off
/// the network leaves its service stream's `relay` running, and on Railway nothing else ends it.
pub const SERVICE_DEADLINE: Duration = Duration::from_secs(60);

#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    #[error("another daemon already holds {0}")]
    AlreadyRunning(PathBuf),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Holds the single-instance lock for the process's lifetime.
pub struct InstanceLock {
    file: std::fs::File,
}

impl InstanceLock {
    pub fn fd(&self) -> std::os::unix::io::RawFd {
        self.file.as_raw_fd()
    }

    /// The lock an earlier program in this process held, handed over across `execve`
    /// (`crate::daemon::handoff`). A `flock` belongs to the open file description, not the program,
    /// so it was never released. Close-on-exec goes back on, as on everything a hand-off carries.
    ///
    /// # Safety
    /// `fd` must be the open lock file the hand-off table names, owned by nothing else.
    pub unsafe fn adopt(fd: std::os::unix::io::RawFd) -> InstanceLock {
        use std::os::unix::io::FromRawFd;
        wr_exec::set_cloexec(fd, true);
        InstanceLock {
            // SAFETY: the caller guarantees `fd` is the open lock file and owned by nothing else,
            // so the `File` can take ownership of it.
            file: unsafe { std::fs::File::from_raw_fd(fd) },
        }
    }
}

/// `flock(LOCK_EX | LOCK_NB)` beside the socket. A lock *file* rather than the socket itself,
/// because binding a unix socket unlinks and recreates the path — two racing daemons would each
/// successfully bind and the second would silently steal the first's address.
pub fn acquire_instance_lock(socket: &Path) -> Result<InstanceLock, ServeError> {
    make_socket_folder(socket)?;
    let path = socket.with_extension("lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)?;
    // SAFETY: the descriptor belongs to `file`, which is open for the call; flock takes integers.
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return Err(ServeError::AlreadyRunning(path));
    }
    Ok(InstanceLock { file })
}

/// How often `serve` touches its lock and log (`Daemon::keep_fresh`): far inside the three days
/// macOS's `tmp_cleaner` gives a /tmp file nobody touches (#528).
pub const FRESHEN_EVERY: Duration = Duration::from_secs(3600);

/// The files a serving daemon keeps fresh, by descriptor, and how often.
struct Freshen {
    lock: std::os::unix::io::RawFd,
    log: std::os::unix::io::RawFd,
    every: Duration,
}

/// Sets each regular file's access and modification times to now, through its descriptor: by
/// descriptor, it is the file this process holds even when a hand-off handed it over, and a
/// terminal or pipe in place of a log is left alone.
fn touch(files: &[std::os::unix::io::RawFd]) {
    for &fd in files {
        // SAFETY: fstat writes only into `stat`, and both calls take a descriptor by number, which
        // fails cleanly if it is not open.
        unsafe {
            let mut stat: libc::stat = std::mem::zeroed();
            if libc::fstat(fd, &mut stat) == 0 && (stat.st_mode & libc::S_IFMT) == libc::S_IFREG {
                libc::futimens(fd, std::ptr::null());
            }
        }
    }
}

/// A pipe `Daemon::run` sleeps on beside its listener, so that whatever ends a client, a session,
/// a kill or a request (`wake_idle`) has it look again at whether the daemon is idle, instead of
/// waking once a second to look (the whole of an otherwise idle daemon's wakeups, 2026-10-23).
/// Process-wide, as `TERMINATING` is; close-on-exec, so the program a hand-off runs makes its own.
struct IdleWake {
    read: libc::c_int,
    write: libc::c_int,
}

static IDLE_WAKE: OnceLock<IdleWake> = OnceLock::new();

fn idle_wake() -> &'static IdleWake {
    IDLE_WAKE.get_or_init(|| {
        let mut fds = [-1 as libc::c_int; 2];
        // SAFETY: `pipe` writes two descriptors into the array.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return IdleWake {
                read: -1,
                write: -1,
            };
        }
        for fd in fds {
            let _ = wr_exec::set_nonblocking(fd);
            wr_exec::set_cloexec(fd, true);
        }
        IdleWake {
            read: fds[0],
            write: fds[1],
        }
    })
}

/// Has `Daemon::run` look again at whether the daemon is idle. A full pipe already holds a wake,
/// and without a pipe the loop falls back to looking every second.
pub(crate) fn wake_idle() {
    let wake = idle_wake();
    // SAFETY: one byte from a live buffer, to a descriptor this process opened or -1.
    unsafe { libc::write(wake.write, [0u8].as_ptr().cast(), 1) };
}

/// Empties the wake pipe, so the next `poll` sleeps until the next wake.
fn drain(fd: libc::c_int) {
    let mut taken = [0u8; 64];
    // SAFETY: reads into a live buffer of the stated length, from a non-blocking descriptor.
    while unsafe { libc::read(fd, taken.as_mut_ptr().cast(), taken.len()) } > 0 {}
}

pub struct Daemon {
    pub sessions: SessionStore,
    connections: Arc<AtomicUsize>,
    freshen: Option<Freshen>,
    /// `SERVICE_DEADLINE`, or a test's shorter one.
    service_deadline: Duration,
}

impl Default for Daemon {
    fn default() -> Self {
        Self::new()
    }
}

impl Daemon {
    pub fn new() -> Self {
        Self {
            sessions: SessionStore::new(),
            connections: Arc::new(AtomicUsize::new(0)),
            freshen: None,
            service_deadline: SERVICE_DEADLINE,
        }
    }

    /// A daemon whose pinging connections are closed after `deadline` of silence instead of
    /// `SERVICE_DEADLINE`, so a test sees one closed in a fraction of a second.
    #[cfg(any(test, feature = "test-support"))]
    pub fn with_service_deadline(mut self, deadline: Duration) -> Daemon {
        self.service_deadline = deadline;
        self
    }

    /// While `run` serves, touches `lock` and `log` every `every`, so a cleaner that deletes files
    /// nobody has touched for days never takes them (#528): macOS's `tmp_cleaner`, for a daemon in
    /// the /tmp socket fallback, where the lock is opened once and never written, and a quiet
    /// daemon's log can sit for days.
    pub fn keep_fresh(
        &mut self,
        lock: std::os::unix::io::RawFd,
        log: std::os::unix::io::RawFd,
        every: Duration,
    ) {
        self.freshen = Some(Freshen { lock, log, every });
    }

    /// Serves on a bound listener until idle. Returns when no session and no client has existed
    /// for `idle_timeout`. The listener is the one `bind` returns, or the one a hand-off carried
    /// across `execve` (`crate::daemon::handoff`), which must never be unbound and bound again.
    pub fn run(
        &self,
        listener: UnixListener,
        socket: &Path,
        idle_timeout: Duration,
    ) -> Result<(), ServeError> {
        listener.set_nonblocking(true)?;
        let mut idle_since = Some(Instant::now());
        let mut result = Ok(());
        // First at once: a lock taken over by hand-off, or one left by a daemon that idled out, can
        // already be days old. Then by the wall clock, not `Instant`: on macOS that stops while the
        // Mac sleeps, and launchd runs a missed `tmp_cleaner` the moment it wakes. A clock set back
        // reads as due.
        let mut freshened: Option<std::time::SystemTime> = None;
        let wake = idle_wake();
        // Only a /tmp daemon has files a cleaner takes, and only it must look at the wall clock
        // soon after a wake (`poll_timeout`).
        let in_tmp = self.freshen.is_some()
            && (socket.starts_with("/tmp") || socket.starts_with("/private/tmp"));
        loop {
            if let Some(freshen) = &self.freshen
                && freshened.is_none_or(|at| at.elapsed().map_or(true, |e| e >= freshen.every))
            {
                touch(&[freshen.lock, freshen.log]);
                freshened = Some(std::time::SystemTime::now());
            }
            // During a hand-off a new client waits in the backlog for the next program
            // (`crate::daemon::handoff::accepting`), rather than being accepted and dropped at the
            // exec.
            if !crate::daemon::handoff::accepting() {
                idle_since = None;
                std::thread::sleep(Duration::from_millis(25));
                continue;
            }
            match listener.accept() {
                Ok((stream, _)) => {
                    idle_since = None;
                    self.connections.fetch_add(1, Ordering::SeqCst);
                    let sessions = self.sessions.clone();
                    let connections = Arc::clone(&self.connections);
                    let deadline = self.service_deadline;
                    // `std::thread::spawn` panics when the OS cannot create a thread. That would
                    // unwind THIS accept loop — the fetch_add above already ran, so `connections`
                    // would be stuck one high forever with nothing left to correct it (worse, an
                    // uncaught panic here takes the whole daemon down with it, over one transient
                    // thread-exhaustion failure). `Builder::spawn` turns it into an `Err`; the
                    // closure is dropped without running, so undo the count ourselves and drop this
                    // one connection rather than the daemon.
                    if std::thread::Builder::new()
                        .spawn(move || {
                            let _ = stream.set_nonblocking(false);
                            let _ = handle_connection_with(stream, sessions, deadline);
                            connections.fetch_sub(1, Ordering::SeqCst);
                            wake_idle();
                        })
                        .is_err()
                    {
                        self.connections.fetch_sub(1, Ordering::SeqCst);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // `connections` drops as soon as `handle_connection` returns, but `vcs::dispatch`
                    // answers on a DETACHED thread that outlives it — a client that disconnects (or
                    // whose request already tripped the app-side timeout) while its VCS request is
                    // still running, e.g. a git commit mid-way through updating the index, would
                    // otherwise let `connections` and `sessions` both read empty while that thread is
                    // still mutating the repository. `crate::daemon::rpc::is_busy()` is the only
                    // thing that actually knows.
                    // A kill on its own thread is the same shape: see `SessionStore::is_killing`.
                    let busy = self.connections.load(Ordering::SeqCst) > 0
                        || !self.sessions.is_empty()
                        || crate::daemon::rpc::is_busy()
                        || self.sessions.is_killing();
                    // How long to sleep: until the idle deadline when idle, the next freshen when
                    // one is kept, and otherwise until something happens.
                    let mut until: Option<Duration> = None;
                    if busy {
                        idle_since = None;
                    } else {
                        let since = idle_since.get_or_insert_with(Instant::now);
                        let waited = since.elapsed();
                        if waited >= idle_timeout {
                            break;
                        }
                        until = Some(idle_timeout - waited);
                    }
                    if let Some(freshen) = &self.freshen {
                        let next = freshened.map_or(Duration::ZERO, |at| {
                            at.elapsed()
                                .map_or(Duration::ZERO, |e| freshen.every.saturating_sub(e))
                        });
                        until = Some(until.map_or(next, |u| u.min(next)));
                    }
                    let timeout = poll_timeout(until, wake.read >= 0, in_tmp);
                    // Sleep until a client connects or something ends (`wake_idle`): polling the
                    // listener every 25 ms cost 40 wakeups a second for nothing, and looking once
                    // a second was every wakeup an idle daemon had left.
                    let mut descriptors = [
                        libc::pollfd {
                            fd: listener.as_raw_fd(),
                            events: libc::POLLIN,
                            revents: 0,
                        },
                        libc::pollfd {
                            fd: wake.read,
                            events: libc::POLLIN,
                            revents: 0,
                        },
                    ];
                    // SAFETY: two live pollfds, for the listener this loop owns and the wake pipe
                    // (or -1, which `poll` skips).
                    unsafe { libc::poll(descriptors.as_mut_ptr(), 2, timeout) };
                    drain(wake.read);
                }
                // An accept failure (descriptor exhaustion, say) ends the daemon.
                Err(e) => {
                    result = Err(e.into());
                    break;
                }
            }
        }
        let _ = std::fs::remove_file(socket);
        result
    }
}

/// The accept loop's `poll` timeout in milliseconds, -1 for none: until the next deadline, or
/// until something happens. A second at most without a wake pipe, as the loop looked before it
/// had one; and a second at most for a daemon in /tmp, because `poll` does not count the time a
/// Mac sleeps. Its freshen deadline is on the wall clock, and launchd runs a missed `tmp_cleaner`
/// the moment the Mac wakes: after days asleep, an hour-long timeout would leave the lock and log
/// for the cleaner to delete, and another daemon could then take the socket (#528).
fn poll_timeout(until: Option<Duration>, pipe: bool, in_tmp: bool) -> i32 {
    let timeout = until.map_or(-1, |u| i32::try_from(u.as_millis()).unwrap_or(i32::MAX));
    if (!pipe || in_tmp) && !(0..=1000).contains(&timeout) {
        1000
    } else {
        timeout
    }
}

/// Binds the daemon's socket.
///
/// A socket file left by a previous run would make bind fail with EADDRINUSE even though nobody is
/// listening. The flock (`acquire_instance_lock`) is what actually guarantees exclusivity, so
/// removing a stale path here is safe rather than a race.
pub fn bind(socket: &Path) -> std::io::Result<UnixListener> {
    if socket.exists() {
        let _ = std::fs::remove_file(socket);
    }
    make_socket_folder(socket)?;
    UnixListener::bind(socket)
}

/// Makes the socket's folder, and any missing above it, private to this user (ADR 0043: a client
/// of the socket can type into every session). Nothing else makes it when the daemon is a
/// container's entrypoint (#308). A folder that exists keeps the mode it has.
pub fn make_socket_folder(socket: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    match socket.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent),
        _ => Ok(()),
    }
}

/// The state the request/reply services keep for ONE connection, dropped with it.
///
/// Per connection, never process-wide: stream ids restart at 1 on every connect and this daemon
/// outlives the app, so a shared map would let one launch's abandoned chunks corrupt the next
/// launch's identically-numbered request (see `PartialRequests`). And for `subscriptions` the
/// teardown matters more than the isolation: dropping it on ANY exit from `handle_connection` stops
/// every filesystem watcher the client started, so an OS watcher never outlives the peer it reports to.
/// `forwards` is there for the same reason, and it is what makes the design's "a forwarded port only
/// carries while a client is attached" true rather than aspirational.
struct ConnectionServices {
    /// `Transport::peer`, for the log lines a kill or a hand-off writes.
    peer: String,
    partial: crate::daemon::rpc::PartialRequests,
    /// The Layout service's own, so its chunked requests never share a buffer with the VCS one's.
    layout_partial: crate::daemon::rpc::PartialRequests,
    subscriptions: crate::vcs::watch::Subscriptions,
    forwards: crate::host::forward::Forwards,
    /// Its program status subscription, ended with it like `subscriptions`.
    program_status: crate::terminal::program_status::Connection,
    /// The service-stream deadline, once the client says it pings.
    deadline: Deadline,
}

/// Closes a connection whose client said it pings (`FrameKind::Pings`) and then sent nothing for
/// `after` (ADR 0075). Only such a client gets it: an older app, and every local connection, never
/// says so, and a quiet one of those is just quiet.
///
/// A watchdog thread waits on a channel the read loop ticks on every read, and ends the connection
/// through its `Closer` when no tick comes in time. What is received counts, and so does a large
/// write the client is taking: a reply bigger than one `WRITE_CHUNK` ticks after each chunk the
/// link accepts (`ProgressWriter`), since over a slow link it can hold the writer, and the read
/// loop's next reply behind it, for longer than the deadline. A small write says nothing (it lands
/// in the socket's buffer whether or not anyone is there), and a write to a client that is gone
/// stops making progress once the buffers fill, so it is still closed. The thread ends with the
/// connection, when the `Deadline` is dropped and takes the sender with it.
struct Deadline {
    after: Duration,
    closer: crate::daemon::transport::Closer,
    peer: String,
    heard: Heard,
}

/// The watchdog's channel, once it runs: shared by the read loop and the connection's writer.
type Heard = Arc<Mutex<Option<std::sync::mpsc::Sender<()>>>>;

/// Ticks `heard`, if the watchdog runs.
fn tick(heard: &Heard) {
    if let Some(sender) = crate::util::lock_or_recover(heard).as_ref() {
        let _ = sender.send(());
    }
}

/// How much of a write goes to the link at a time, so a large one's progress is seen as it goes.
const WRITE_CHUNK: usize = 16 * 1024;

/// The connection's writer: a write larger than `WRITE_CHUNK` goes out a chunk at a time, ticking
/// the deadline after each the link accepts (`Deadline`).
struct ProgressWriter {
    inner: Box<dyn std::io::Write + Send>,
    heard: Heard,
}

impl std::io::Write for ProgressWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.write(&buf[..buf.len().min(WRITE_CHUNK)])
    }

    fn write_all(&mut self, mut buf: &[u8]) -> std::io::Result<()> {
        let large = buf.len() > WRITE_CHUNK;
        while !buf.is_empty() {
            match self.inner.write(&buf[..buf.len().min(WRITE_CHUNK)]) {
                Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    buf = &buf[n..];
                    if large {
                        tick(&self.heard);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

impl Drop for Deadline {
    /// Ends the watchdog with the connection: the writer outlives it (a session holds it), so the
    /// sender can't go with the writer.
    fn drop(&mut self) {
        crate::util::lock_or_recover(&self.heard).take();
    }
}

impl Deadline {
    /// Starts the watchdog, once. A thread the OS will not give leaves the connection with no
    /// deadline, as it was before this existed.
    fn start(&mut self) {
        if crate::util::lock_or_recover(&self.heard).is_some() {
            return;
        }
        let (heard, ticks) = std::sync::mpsc::channel::<()>();
        let after = self.after;
        let closer = Arc::clone(&self.closer);
        let peer = self.peer.clone();
        let started = std::thread::Builder::new()
            .name("service-deadline".into())
            .spawn(move || {
                loop {
                    match ticks.recv_timeout(after) {
                        Ok(()) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            crate::daemon::log::note(format_args!(
                                "closing {peer}'s connection: nothing from it for {after:?}"
                            ));
                            closer();
                            return;
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
                    }
                }
            });
        if started.is_ok() {
            *crate::util::lock_or_recover(&self.heard) = Some(heard);
        }
    }

    /// Something arrived from the client.
    fn heard(&self) {
        tick(&self.heard);
    }
}

/// Greets, negotiates, then serves envelopes until the peer goes away.
///
/// Generic over the transport, which is the whole point: the driver contract is a bidirectional
/// byte stream, so `ssh host workroomd serve --stdio`, a provider's exec channel and a local unix
/// socket are all the same code path here. It also means the remote protocol can be tested over a
/// pair of pipes with no container, no ssh and no provider — see `transport::PipeTransport`.
pub fn handle_connection<T: Transport>(
    transport: T,
    sessions: SessionStore,
) -> Result<(), ProtocolError> {
    handle_connection_with(transport, sessions, SERVICE_DEADLINE)
}

/// `handle_connection`, closing a connection that said it pings after `deadline` of silence
/// rather than `SERVICE_DEADLINE`.
pub fn handle_connection_with<T: Transport>(
    transport: T,
    sessions: SessionStore,
    deadline: Duration,
) -> Result<(), ProtocolError> {
    // Before `split`, which consumes the transport: the watch service needs a way to end THIS
    // connection from a thread that only writes.
    let closer = transport.closer();
    let peer = transport.peer();
    let (mut reader, writer) = transport.split().map_err(|_| ProtocolError::NotADaemon)?;
    // One writer, shared, and type-erased. A socket could be cloned instead, but a pipe or an exec
    // channel cannot, and the daemon must not require a transport that can. Boxed because the
    // SESSION holds it now — its reader outlives this connection, and the next client may arrive
    // over a different kind of stream. Contention is negligible: the command loop writes only
    // replies, and the reader holds the lock for one write at a time.
    let heard: Heard = Arc::new(Mutex::new(None));
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(ProgressWriter {
        inner: Box::new(writer),
        heard: Arc::clone(&heard),
    })));

    let send = |bytes: &[u8]| rpc::write(&writer, bytes);

    let local = Hello::current(BUILD);
    if !send(&local.encode()) {
        return Err(ProtocolError::NotADaemon);
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
            Ok(0) => return Err(ProtocolError::NotADaemon),
            Ok(_) => greeting.push(byte[0]),
            Err(_) => return Err(ProtocolError::NotADaemon),
        }
    };
    negotiate(&local, &remote)?;

    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let mut attachment = crate::terminal::dispatch::Attachment::new(Arc::clone(&closer));
    let mut services = ConnectionServices {
        deadline: Deadline {
            after: deadline,
            closer: Arc::clone(&closer),
            peer: peer.clone(),
            heard,
        },
        peer,
        partial: crate::daemon::rpc::PartialRequests::default(),
        layout_partial: crate::daemon::rpc::PartialRequests::default(),
        subscriptions: crate::vcs::watch::Subscriptions::new(
            Arc::clone(&writer),
            Arc::clone(&closer),
        ),
        forwards: crate::host::forward::Forwards::new(),
        program_status: crate::terminal::program_status::Connection::new(
            Arc::clone(&sessions.hooks().program_status),
            Arc::clone(&writer),
            closer,
        ),
    };

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
                        &mut attachment,
                        &mut services,
                        &writer,
                        &send,
                    ) && !send(&reply.encode())
                    {
                        break 'outer;
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
            Ok(n) => {
                services.deadline.heard();
                decoder.push(&buffer[..n]);
            }
            Err(_) => break,
        }
    }

    attachment.end(&sessions);
    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Hands one envelope to its service. Returns a reply to send, if any: only the Terminal and
/// Control frames (`crate::terminal::dispatch`) are answered this way; every other service writes
/// its own replies.
fn dispatch(
    envelope: &Envelope,
    sessions: &SessionStore,
    attachment: &mut crate::terminal::dispatch::Attachment,
    services: &mut ConnectionServices,
    writer: &SharedWriter,
    send: &dyn Fn(&[u8]) -> bool,
) -> Option<Envelope> {
    if envelope.service == Service::Vcs {
        crate::vcs::service::dispatch(&mut services.partial, envelope, writer);
        return None;
    }
    if envelope.service == Service::File {
        crate::vcs::file::dispatch(envelope, writer, &services.subscriptions);
        return None;
    }
    if envelope.service == Service::Layout {
        crate::host::layout::dispatch(&mut services.layout_partial, envelope, writer);
        return None;
    }
    if envelope.service == Service::Status {
        retired_status(envelope, writer);
        return None;
    }
    if envelope.service == Service::Forward {
        crate::host::forward::dispatch(envelope, writer, &services.forwards);
        return None;
    }
    if envelope.service == Service::ProgramStatus {
        crate::terminal::program_status::dispatch(envelope, sessions, &mut services.program_status);
        return None;
    }
    if envelope.service == Service::Control && is_pings(&envelope.payload) {
        services.deadline.start();
        return Some(Envelope::new(
            envelope.service,
            envelope.stream,
            Frame::control(FrameKind::Acknowledged).encode(),
        ));
    }
    if envelope.service == Service::Terminal || envelope.service == Service::Control {
        return crate::terminal::dispatch::dispatch(
            envelope,
            sessions,
            attachment,
            &services.peer,
            writer,
            send,
        );
    }
    None
}

/// Whether a Control envelope is the client saying it pings.
fn is_pings(payload: &[u8]) -> bool {
    let mut frames = FrameDecoder::new();
    frames.push(payload);
    matches!(frames.next_frame(), Ok(Some(frame)) if frame.kind == FrameKind::Pings)
}

/// The Status service is retired (#382): the daemon no longer decides whether its box is busy. An app
/// from before then still asks for `status`, so every request gets the one failure that app already
/// handles, `unsupported` at the last version it reads. Dropping it instead would leave that app
/// waiting out its own timeout. Stream 0 was where verdicts were pushed, never where a request
/// arrives.
fn retired_status(envelope: &Envelope, writer: &SharedWriter) {
    if envelope.stream == 0 {
        return;
    }
    crate::daemon::rpc::send(
        writer,
        Service::Status,
        envelope.stream,
        serde_json::json!(Reply::error(
            2,
            serde_json::json!({"unsupported": "this daemon has no status service"})
        )),
    );
}

/// Connects to a running daemon, or returns None if there is nothing listening.
pub fn connect(socket: &Path) -> Option<UnixStream> {
    UnixStream::connect(socket).ok()
}

/// Spawns `workroomd serve` detached, the way the Swift attach client spawns the daemon today:
/// `posix_spawn` with a new session, stdio to /dev/null, so it outlives whoever started it.
pub fn spawn_daemon(binary: &Path, socket: &Path) -> std::io::Result<()> {
    use std::process::{Command, Stdio};
    let mut command = Command::new(binary);
    command
        .arg("serve")
        .arg("--socket")
        .arg(socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: the closure runs in the forked child before exec, where only async-signal-safe calls
    // are allowed. It makes one, `setsid`, and allocates nothing.
    unsafe {
        use std::os::unix::process::CommandExt;
        command.pre_exec(|| {
            // Detach from the caller's session so the daemon is not killed with it, which is the
            // whole point of a session that outlives the app.
            libc::setsid();
            Ok(())
        });
    }
    // `pre_exec` makes std fork rather than `posix_spawn`.
    crate::util::ready_to_fork();
    command.spawn().map(|_| ())
}

/// The socket the app told us to use, matching `PersistentSessionService`'s
/// `WORKROOM_SESSION_SOCKET`. `attachCommand()` passes no flags, so the environment is the whole
/// contract on the app's side.
pub fn socket_from_env() -> Option<PathBuf> {
    std::env::var_os("WORKROOM_SESSION_SOCKET")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests;
