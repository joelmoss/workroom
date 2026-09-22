//! `Service::Forward`: one loopback TCP connection on the agent's box per multiplex stream.
//!
//! A forwarded port becomes another service on the multiplex, so no provider public hostname is
//! required and it works identically on a local container. **Caveat, by construction:** it only
//! carries while a client is attached — every forwarded socket is owned by the connection that
//! opened it and is closed with it.
//!
//! # Wire contract
//!
//! Unlike the request/reply services, a Forward stream is a *byte pipe* after its first exchange,
//! so its payloads cannot all be JSON. Every Forward envelope payload is therefore
//! **one opcode byte, then a body** — the same shape as the `0 = continuation, 1 = final` marker
//! byte the VCS, File and Status services put in front of their JSON:
//!
//! ```text
//! 0x01 OPEN   client → agent   body: the JSON request (below). One envelope, exactly once.
//! 0x02 REPLY  agent → client   body: JSON {"version":1,"result":…} or {"version":1,"error":…}.
//! 0x03 DATA   both directions  body: raw connection bytes, 0..=1 MiB - 1. May be empty.
//! 0x04 EOF    both directions  body: empty. The sender will send no more DATA.
//! 0x05 CLOSE  both directions  body: empty. The stream is finished; the socket is gone.
//! ```
//!
//! **Stream 0 carries nothing on this service.** There is no agent-initiated stream here (unlike
//! File's watch events), so an envelope on stream 0 is dropped.
//!
//! **EOF and CLOSE are both needed, and mean different things.** EOF is a half-close: the sender is
//! done writing but still reading, which is how `curl --data-binary @-` style traffic and any
//! shutdown-then-read-the-response protocol works. CLOSE is the whole connection ending, which EOF
//! cannot express — a client that aborted mid-transfer would otherwise leave the agent holding a
//! socket waiting for a peer that will never be read again.
//!
//! ## Opening
//!
//! The client picks an unused stream id and sends OPEN with a single JSON object, shaped like the
//! Status and File services' requests:
//!
//! ```json
//! {"method": "open", "host": "127.0.0.1", "port": 5173}
//! ```
//!
//! Unknown fields are refused, so the object is exactly those three. The agent answers on the same
//! stream with REPLY, once:
//!
//! - `{"version":1,"result":{"opened":true}}` — connected. Every later payload on this stream is
//!   the connection's bytes.
//! - `{"version":1,"error":{"<kind>":"<detail>"}}` — not connected, followed by CLOSE.
//!
//! **The agent's CLOSE is always its last word on a stream, and a stream id is free again only
//! once the client has seen it.** That is the one rule a client has to keep rather than infer, and
//! it holds on every path: an error reply is followed by CLOSE; a forward that ends because the
//! peer went away, because the client sent CLOSE, because the client fell too far behind, or
//! because the client's CLOSE arrived while the connect was still in flight, ends with exactly one
//! CLOSE after whatever DATA and EOF preceded it, and nothing is written on the stream after it.
//! So a client that waits for CLOSE can re-use the id with no risk of the old forward's bytes
//! landing on the new one. A client that gives up on a slow `open` (the connect is bounded at
//! 3 s, which is longer than a client's own timeout is likely to be) sends CLOSE and waits for the
//! agent's, like any other close — or simply never re-uses ids, which is what a monotonic stream
//! counter gets for free.
//!
//! The error kinds, exhaustively, with the exact detail strings where they are fixed:
//!
//! | kind | when |
//! |---|---|
//! | `unsupported` | `"forward requests are a single JSON object"` — the OPEN body does not start with `{` |
//! | `unsupported` | a serde message — malformed JSON, an unknown field, a missing or out-of-range `host`/`port` |
//! | `unsupported` | `"forward requests are {\"method\": \"open\", \"host\": …, \"port\": …}"` — a method other than `open` |
//! | `refused` | `"<host> is not a loopback address"` — the host is not one of the three literals below (a long host is abbreviated) |
//! | `refused` | `"stream <n> is already forwarding"` — OPEN for a stream id that already has a connection, whatever the body; NOT followed by CLOSE, the stream is the running forward's |
//! | `refused` | `"too many forwarded connections"` — this multiplex connection already holds 64 |
//! | `connect` | the OS error text — connection refused, timed out (3s), unreachable |
//! | `connect` | `"could not duplicate the socket"` — out of descriptors |
//!
//! ## Target
//!
//! **Loopback only, by literal**: `127.0.0.1`, `::1`, and `localhost` (case-insensitive), which the
//! agent maps to those two addresses itself. Nothing is resolved: a DNS lookup on the dispatch path
//! is an unbounded blocking call, and `localhost` resolving through a hosts file is the classic way
//! an allowlist checked before resolution gets bypassed. So `127.0.0.2` is refused too, along with
//! every other address. Reverse (remote → Mac) forwarding is not part of this service.
//!
//! ## Closing
//!
//! - The TCP peer closes its write half → the agent sends EOF. The client may still send.
//! - Both halves are done → the agent sends CLOSE and forgets the stream.
//! - The TCP connection fails mid-stream (a reset) → the agent shuts the socket and sends CLOSE.
//! - The client sends EOF → the agent shuts down the socket's write half, so the peer sees EOF.
//!   DATA after the client's own EOF is dropped.
//! - The client sends CLOSE → the agent shuts the socket down entirely and answers CLOSE, after
//!   any DATA or EOF the socket's reader was still delivering.
//! - The multiplex connection drops (or the client detaches) → every socket it opened is shut down.
//!
//! A client that violates the contract is ignored rather than answered: DATA/EOF/CLOSE for a stream
//! that is not forwarding is dropped, as is an unknown opcode, exactly as `serve.rs` drops an
//! envelope for a service byte it does not handle.
//!
//! # Threading and backpressure
//!
//! Two threads per forwarded connection, in the pty and file services' shape — no async runtime, no
//! new dependency. One reads the socket and writes DATA envelopes; one takes client bytes off a
//! channel and writes them to the socket. **The connection's reader thread never blocks on a
//! forwarded socket**: the channel is unbounded and the OPEN's `connect` happens on the spawned
//! thread, so a forwarded socket that stalls cannot stop a terminal on the same connection from
//! being read. (It does contend for the shared writer when it refuses an OPEN, exactly as every
//! other service's error reply does.)
//!
//! What bounds the unbounded channel is a byte budget: a forward holding more than
//! [`MAX_QUEUED_BYTES`] of undelivered client bytes — counting a fixed overhead per message, so a
//! flood of empty ones is not free — is killed with CLOSE rather than allowed to grow. The
//! multiplex has no per-stream flow control, so the choice is between buffering without limit,
//! blocking the reader thread, and dropping one stalled connection; only the third keeps the other
//! streams honest.
//!
//! **Every terminal emission comes from the forward's own threads.** A kill — the client's CLOSE,
//! the budget, a reset — marks the forward and wakes its threads; the last thread out forgets the
//! stream and sends the one CLOSE. Nothing else writes CLOSE, which is what makes "CLOSE is last"
//! true rather than aspirational: a `token` alone guarded the map, and every path that wrote to the
//! wire without going through the threads was a way for a stale envelope to land on a re-used
//! stream id — which the app's connection reader answers by failing the whole connection.
//!
//! The *writer* is the process-wide [`SharedWriter`], held for one envelope at a time — the same
//! discipline `vcs::send` and every session's output already use. A forward is not faster or slower
//! to starve than pty output is.
//!
//! A forward takes no request [`Permit`](crate::vcs::Permit): like a `watch` subscription it is a
//! resource that lives across many requests, not a request in flight, so it is capped separately
//! ([`MAX_FORWARDS`] per connection). The cap counts threads alive, not map entries: a forward
//! whose connect is failing holds its slot until its thread has said so and gone.

use crate::protocol::envelope::{Envelope, Service, MAX_ENVELOPE_PAYLOAD};
use crate::session::SharedWriter;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The wire version of this service, reported in every reply. Separate from `PROTOCOL_VERSION`,
/// which says whether the service exists at all.
pub const FORWARD_SERVICE_VERSION: u32 = 1;

/// Opcodes. See the module doc for what each one carries.
const OPEN: u8 = 0x01;
const REPLY: u8 = 0x02;
const DATA: u8 = 0x03;
const EOF: u8 = 0x04;
const CLOSE: u8 = 0x05;

/// Bounded so a refused or blackholed port answers rather than holding the stream open forever. A
/// loopback connect either completes in microseconds or is never going to. One budget for the whole
/// OPEN, however many addresses the host names.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// What one queued message costs on top of its bytes: the channel node and the `Vec` header. Exact
/// to the byte does not matter; what matters is that an empty message is not free.
const MESSAGE_OVERHEAD: usize = 64;

/// How much of a refused host is echoed back. The rest of the reply is fixed text, so this is what
/// keeps a maximum-sized OPEN from producing a reply larger than an envelope may be.
const ECHOED_HOST: usize = 64;

/// Forwarded connections one multiplex connection may hold at once, matching the spirit of the file
/// service's subscription cap: a resource the client holds, bounded so it cannot be held without
/// limit.
pub const MAX_FORWARDS: usize = 64;

/// Client bytes that may sit undelivered for ONE forward before it is killed. Two envelopes'
/// worth, so a maximum-sized envelope always fits even behind another.
///
/// ponytail: a fixed per-stream budget, 64 × 2 MiB per connection worst case. Per-stream flow
/// control on the multiplex — a window the peer credits — is the upgrade path if that ever matters.
const MAX_QUEUED_BYTES: usize = 2 * crate::protocol::envelope::MAX_ENVELOPE_PAYLOAD;

/// How much of the socket is read at once. Well under the envelope cap, so a DATA envelope is
/// always sendable.
const READ_BUFFER: usize = 64 * 1024;

#[derive(Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Request {
    method: String,
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    port: Option<u16>,
}

/// A refusal, as `{"<kind>": "<detail>"}`. One shape for the Swift decoder, like `FileError`'s.
struct Refusal(&'static str, String);

impl Refusal {
    fn unsupported(detail: impl Into<String>) -> Self {
        Refusal("unsupported", detail.into())
    }

    fn refused(detail: impl Into<String>) -> Self {
        Refusal("refused", detail.into())
    }

    fn value(&self) -> Value {
        json!({"version": FORWARD_SERVICE_VERSION, "error": {self.0: self.1}})
    }
}

/// The addresses a target host names, or `None` if it is not loopback.
///
/// Matched as TEXT and never resolved — see the module doc. `localhost` yields both loopback
/// addresses because a server may be bound to only one of them.
fn loopback_addresses(host: &str) -> Option<Vec<IpAddr>> {
    Some(match host {
        "127.0.0.1" => vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        "::1" => vec![IpAddr::V6(Ipv6Addr::LOCALHOST)],
        _ if host.eq_ignore_ascii_case("localhost") => {
            vec![
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                IpAddr::V6(Ipv6Addr::LOCALHOST),
            ]
        }
        _ => return None,
    })
}

/// Parse an OPEN body into the addresses to try and the port.
fn target(body: &[u8]) -> Result<(Vec<IpAddr>, u16), Refusal> {
    // A request is always one JSON object. Answering here beats parsing a stray DATA payload that
    // arrived before its OPEN as JSON and reporting a serde error for it.
    if body.first() != Some(&b'{') {
        return Err(Refusal::unsupported(
            "forward requests are a single JSON object",
        ));
    }
    let request: Request =
        serde_json::from_slice(body).map_err(|error| Refusal::unsupported(error.to_string()))?;
    if request.method != "open" {
        return Err(Refusal::unsupported(
            r#"forward requests are {"method": "open", "host": …, "port": …}"#,
        ));
    }
    let host = request
        .host
        .ok_or_else(|| Refusal::unsupported("missing host"))?;
    let port = request
        .port
        .ok_or_else(|| Refusal::unsupported("missing port"))?;
    let addresses = loopback_addresses(&host).ok_or_else(|| {
        Refusal::refused(format!("{} is not a loopback address", abbreviated(&host)))
    })?;
    Ok((addresses, port))
}

/// The host as a refusal echoes it: whole if short, abbreviated if not. A host can be as long as an
/// envelope allows, and reflecting all of it would make the reply longer than one.
fn abbreviated(host: &str) -> String {
    if host.chars().count() <= ECHOED_HOST {
        return host.to_string();
    }
    let mut short: String = host.chars().take(ECHOED_HOST).collect();
    short.push('…');
    short
}

/// One Forward envelope, written under the shared writer lock — one envelope at a time, exactly as
/// `vcs::send` writes one chunk at a time. `false` means the client is gone — or the body could
/// not be an envelope at all. It never is (DATA is read in `READ_BUFFER` pieces, replies are
/// small), but `Envelope::encode` asserts rather than errs, and an assertion under the writer lock
/// would poison it for every service on the connection.
fn send(writer: &SharedWriter, stream: u32, opcode: u8, body: &[u8]) -> bool {
    if body.len() + 1 > MAX_ENVELOPE_PAYLOAD {
        return false;
    }
    let mut payload = Vec::with_capacity(1 + body.len());
    payload.push(opcode);
    payload.extend_from_slice(body);
    let Ok(mut writer) = writer.lock() else {
        return false;
    };
    writer
        .write_all(&Envelope::new(Service::Forward, stream, payload).encode())
        .and_then(|()| writer.flush())
        .is_ok()
}

fn send_reply(writer: &SharedWriter, stream: u32, value: &Value) -> bool {
    send(
        writer,
        stream,
        REPLY,
        &serde_json::to_vec(value).expect("JSON value serializes"),
    )
}

/// What the dispatching thread hands a forward's socket writer.
enum Msg {
    Data(Vec<u8>),
    /// The client's EOF: shut the socket's write half.
    Eof,
    /// The forward is over (the client's CLOSE, the budget, a reset): shut the socket and finish.
    Kill,
}

/// One forwarded connection, as the dispatching thread sees it.
struct Conn {
    tx: Sender<Msg>,
    /// Undelivered client bytes plus a per-message overhead. Unbounded channel, bounded by this.
    queued: Arc<AtomicUsize>,
    /// A clone of the socket, kept only so another thread can `shutdown` it. `None` until the
    /// connect completes.
    socket: Arc<Mutex<Option<TcpStream>>>,
    /// Distinguishes THIS forward from a later one on the same stream id, so a finishing pair of
    /// threads cannot remove the entry a re-opened stream has since installed.
    token: u64,
    /// Set by `kill`. The socket reader reads it before every emission, so a killed forward sends
    /// no EOF for the shutdown it was killed with; the connect thread reads it at registration, so a
    /// kill that landed during the connect is answered with CLOSE alone.
    killed: Arc<AtomicBool>,
    /// The client sent EOF. Later DATA is dropped, not charged: the writer that would have taken it
    /// has gone.
    half_closed: AtomicBool,
}

impl Conn {
    /// Ends the connection now, from any thread: the shutdown unblocks the socket reader and any
    /// write in flight, and the message unblocks a writer parked on the channel. The threads say
    /// CLOSE when they are both done — see `finish`; nothing here writes to the client.
    fn kill(&self) {
        self.killed.store(true, Ordering::Release);
        let _ = self.tx.send(Msg::Kill);
        self.shutdown();
    }

    fn shutdown(&self) {
        let socket = self.socket.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(socket) = socket.as_ref() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
}

/// One of the `MAX_FORWARDS` slots, held from before a forward's thread is spawned until that
/// thread returns — through a failing connect, a refused reply, everything. The map cannot count
/// for this: an entry is forgotten a moment before its thread is done, and a connect that is still
/// failing has no entry to count at all once the client gave up on it.
struct Slot(Arc<AtomicUsize>);

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Every forwarded connection ONE multiplex connection owns.
///
/// Per connection, never process-wide, and that is the whole "only carries while a client is
/// attached" caveat: `ConnectionServices` drops this when `handle_connection` returns by any path,
/// and the drop closes every socket. The map is behind an `Arc` because the per-connection threads
/// outlive this value by a moment and have to be able to forget themselves.
pub struct Forwards {
    open: Arc<Mutex<HashMap<u32, Conn>>>,
    next_token: AtomicUsize,
    /// Forward threads alive on this connection: what `MAX_FORWARDS` bounds.
    live: Arc<AtomicUsize>,
}

impl Default for Forwards {
    fn default() -> Self {
        Self::new()
    }
}

impl Forwards {
    pub fn new() -> Self {
        Self {
            open: Arc::new(Mutex::new(HashMap::new())),
            next_token: AtomicUsize::new(0),
            live: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn open(&self, stream: u32, body: &[u8], writer: &SharedWriter) {
        // Ownership before content: an OPEN on a stream that is already forwarding is refused
        // whatever its body says, and NOT closed — the stream belongs to the forward that is
        // already running there, and a CLOSE for a malformed duplicate would tell the client the
        // stream is free while the agent kept pumping the old socket's bytes onto it.
        let taken = |open: &HashMap<u32, Conn>| {
            if !open.contains_key(&stream) {
                return false;
            }
            send_reply(
                writer,
                stream,
                &Refusal::refused(format!("stream {stream} is already forwarding")).value(),
            );
            true
        };
        if taken(&self.open.lock().unwrap_or_else(|e| e.into_inner())) {
            return;
        }
        let (addresses, port) = match target(body) {
            Ok(target) => target,
            Err(refusal) => {
                send_reply(writer, stream, &refusal.value());
                send(writer, stream, CLOSE, &[]);
                return;
            }
        };

        let (tx, rx) = channel();
        let queued = Arc::new(AtomicUsize::new(0));
        let socket = Arc::new(Mutex::new(None));
        let killed = Arc::new(AtomicBool::new(false));
        let token = self.next_token.fetch_add(1, Ordering::Relaxed) as u64;
        let slot = {
            let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
            // Parsed with the lock released, so checked again.
            if taken(&open) {
                return;
            }
            if self.live.load(Ordering::Acquire) >= MAX_FORWARDS {
                drop(open);
                send_reply(
                    writer,
                    stream,
                    &Refusal::refused("too many forwarded connections").value(),
                );
                send(writer, stream, CLOSE, &[]);
                return;
            }
            // Taken under the lock, so two OPENs cannot both pass the check above.
            self.live.fetch_add(1, Ordering::AcqRel);
            open.insert(
                stream,
                Conn {
                    tx,
                    queued: Arc::clone(&queued),
                    socket: Arc::clone(&socket),
                    token,
                    killed: Arc::clone(&killed),
                    half_closed: AtomicBool::new(false),
                },
            );
            Slot(Arc::clone(&self.live))
        };

        // The connect runs HERE, not on the caller: `connect_timeout` blocks for up to three
        // seconds, and the caller is the connection's envelope reader.
        let open_map = Arc::clone(&self.open);
        let writer = Arc::clone(writer);
        std::thread::spawn(move || {
            let _slot = slot;
            connect_and_run(ForwardTask {
                stream,
                token,
                addresses,
                port,
                rx,
                queued,
                socket,
                killed,
                open: open_map,
                writer,
            });
        });
    }

    /// Client bytes for a forwarded socket. Dropped if the stream is not forwarding (or the client
    /// already said EOF on it), and the whole forward is killed if it has fallen too far behind.
    fn deliver(&self, stream: u32, bytes: &[u8]) {
        let open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let Some(conn) = open.get(&stream) else {
            return;
        };
        if conn.half_closed.load(Ordering::Acquire) || conn.killed.load(Ordering::Acquire) {
            return;
        }
        if bytes.is_empty() {
            // Nothing to write, and nothing to queue: an empty DATA must not cost a channel node.
            return;
        }
        let cost = bytes.len() + MESSAGE_OVERHEAD;
        if conn.queued.fetch_add(cost, Ordering::AcqRel) + cost > MAX_QUEUED_BYTES {
            // One stalled forward dies rather than the agent buffering without limit. The kill
            // reaches a writer parked on `recv` (the message) and one parked on the socket (the
            // shutdown); the threads send the CLOSE once they are both out.
            conn.kill();
            return;
        }
        let _ = conn.tx.send(Msg::Data(bytes.to_vec()));
    }

    /// The client will send no more: the socket's write half goes down so the peer sees EOF. Once.
    fn half_close(&self, stream: u32) {
        let open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(conn) = open.get(&stream) {
            if !conn.half_closed.swap(true, Ordering::AcqRel) {
                let _ = conn.tx.send(Msg::Eof);
            }
        }
    }

    /// The client is done with the stream: the socket goes, and the threads answer with the CLOSE
    /// that frees the id. The entry stays until they have, so nothing can re-open the id first.
    fn close(&self, stream: u32) {
        let open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(conn) = open.get(&stream) {
            conn.kill();
        }
    }
}

impl Drop for Forwards {
    fn drop(&mut self) {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        for (_, conn) in open.drain() {
            conn.shutdown();
        }
    }
}

/// Everything one forwarded connection's threads need. A struct because it is eight values that
/// travel together into a thread, not because anything else builds one.
struct ForwardTask {
    stream: u32,
    token: u64,
    addresses: Vec<IpAddr>,
    port: u16,
    rx: Receiver<Msg>,
    queued: Arc<AtomicUsize>,
    socket: Arc<Mutex<Option<TcpStream>>>,
    killed: Arc<AtomicBool>,
    open: Arc<Mutex<HashMap<u32, Conn>>>,
    writer: SharedWriter,
}

/// Forget this forward, if it is still the one registered: the entry, if it was ours. `None` means
/// the connection is gone (`Forwards::drop` took it) and nobody is listening for a CLOSE.
fn forget(open: &Mutex<HashMap<u32, Conn>>, stream: u32, token: u64) -> Option<Conn> {
    let mut open = open.lock().unwrap_or_else(|e| e.into_inner());
    match open.get(&stream) {
        Some(conn) if conn.token == token => open.remove(&stream),
        _ => None,
    }
}

/// Kill this forward from one of its own threads (a reset seen by the reader), if it is still
/// registered: the same kill a client CLOSE performs, so the other thread wakes and the pair
/// finishes with the one CLOSE.
fn kill_own(open: &Mutex<HashMap<u32, Conn>>, stream: u32, token: u64) {
    let open = open.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(conn) = open.get(&stream) {
        if conn.token == token {
            conn.kill();
        }
    }
}

/// The forward ended before it had threads to end it: still ours, an error reply (unless it was
/// killed meanwhile — a killed forward gets no reply) and the CLOSE; no longer ours, nothing, the
/// connection is gone.
fn retire(task: &ForwardTask, refusal: Option<Refusal>) {
    let Some(conn) = forget(&task.open, task.stream, task.token) else {
        return;
    };
    if let (Some(refusal), false) = (refusal, conn.killed.load(Ordering::Acquire)) {
        send_reply(&task.writer, task.stream, &refusal.value());
    }
    send(&task.writer, task.stream, CLOSE, &[]);
}

/// Connect, answer, then pump client bytes into the socket until either side is done.
///
/// This thread is the socket's WRITER; it spawns the reader. A connect failure is an error reply
/// and a CLOSE, never a dropped stream.
fn connect_and_run(task: ForwardTask) {
    let mut last = None;
    let mut connected = None;
    // One deadline across every address the host names: `localhost` is two, and "bounded at 3 s"
    // is the promise the client's own timeout is budgeted against.
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    for address in &task.addresses {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            last.get_or_insert_with(|| std::io::ErrorKind::TimedOut.into());
            break;
        }
        match TcpStream::connect_timeout(&SocketAddr::new(*address, task.port), remaining) {
            Ok(socket) => {
                connected = Some(socket);
                break;
            }
            Err(error) => last = Some(error),
        }
    }
    let Some(mut socket) = connected else {
        let detail = last.map_or_else(|| "no address to connect to".into(), |e| e.to_string());
        retire(&task, Some(Refusal("connect", detail)));
        return;
    };

    // The clones are how the reader thread reads, and how `Forwards::drop`, a client CLOSE and the
    // overflow kill reach this socket. Both or neither: a forward whose shutdown handle failed to
    // clone would be one nothing could ever end.
    let duplicated = socket
        .try_clone()
        .and_then(|reader| socket.try_clone().map(|held| (reader, held)));
    let Ok((reader_socket, held)) = duplicated else {
        let _ = socket.shutdown(Shutdown::Both);
        retire(
            &task,
            Some(Refusal("connect", "could not duplicate the socket".into())),
        );
        return;
    };
    // Registered under the map lock, so nothing that landed DURING the connect is missed. The
    // connection's departure took the entry: the socket goes silently, whoever was listening is
    // gone. A client CLOSE (or the budget) killed it: the socket goes, and the client gets the
    // CLOSE it is waiting for and no reply. Without the check, the socket would be registered
    // nowhere, the reader would pump DATA onto a stream id the client has since freed, and no
    // shutdown could ever reach it.
    {
        let open = task.open.lock().unwrap_or_else(|e| e.into_inner());
        match open.get(&task.stream) {
            Some(conn) if conn.token == task.token => {
                if conn.killed.load(Ordering::Acquire) {
                    drop(open);
                    let _ = socket.shutdown(Shutdown::Both);
                    retire(&task, None);
                    return;
                }
                *task.socket.lock().unwrap_or_else(|e| e.into_inner()) = Some(held);
            }
            _ => {
                drop(open);
                let _ = socket.shutdown(Shutdown::Both);
                return;
            }
        }
    }

    // Answered BEFORE the reader starts, so the client can never see DATA ahead of the reply. A
    // kill that lands between the registration above and this reply is handled like any other:
    // the message is in the channel, the loop below reads it first, and the pair ends with CLOSE.
    if !send_reply(
        &task.writer,
        task.stream,
        &json!({"version": FORWARD_SERVICE_VERSION, "result": {"opened": true}}),
    ) {
        forget(&task.open, task.stream, task.token);
        let _ = socket.shutdown(Shutdown::Both);
        return;
    }

    // Both halves have to finish before the stream is forgotten: the client may still be sending
    // after the peer stopped, and the peer may still be sending after the client stopped.
    let halves = Arc::new(AtomicUsize::new(2));
    let reader = {
        let halves = Arc::clone(&halves);
        let writer = Arc::clone(&task.writer);
        let open = Arc::clone(&task.open);
        let killed = Arc::clone(&task.killed);
        let (stream, token) = (task.stream, task.token);
        std::thread::spawn(move || {
            pump_to_client(reader_socket, stream, &writer, &killed, &open, token);
            finish(&halves, &open, stream, token, &writer);
        })
    };

    while let Ok(message) = task.rx.recv() {
        match message {
            Msg::Data(bytes) => {
                let wrote = socket.write_all(&bytes).and_then(|()| socket.flush());
                task.queued
                    .fetch_sub(bytes.len() + MESSAGE_OVERHEAD, Ordering::AcqRel);
                if wrote.is_err() {
                    // The peer is gone. The reader will see the same and kill the forward, or
                    // has already; either way the pair finishes.
                    let _ = socket.shutdown(Shutdown::Both);
                    break;
                }
            }
            Msg::Eof => {
                // The client half-closed: the peer sees EOF, and this direction is done.
                let _ = socket.shutdown(Shutdown::Write);
                break;
            }
            Msg::Kill => {
                let _ = socket.shutdown(Shutdown::Both);
                break;
            }
        }
    }
    finish(&halves, &task.open, task.stream, task.token, &task.writer);
    // Deliberately not joined: the reader is still legitimately blocked on a peer that has not
    // finished sending, and joining would park this thread for exactly as long for nothing.
    drop(reader);
}

/// Socket → client, until the peer closes, the connection fails, or the forward is killed.
///
/// Nothing is emitted for a killed forward: a shutdown performed by a kill makes `read` return
/// `Ok(0)` exactly as a peer's half-close does, and the EOF that would say so belongs to a
/// stream the client is waiting to see CLOSE on.
fn pump_to_client(
    mut socket: TcpStream,
    stream: u32,
    writer: &SharedWriter,
    killed: &AtomicBool,
    open: &Mutex<HashMap<u32, Conn>>,
    token: u64,
) {
    let mut buffer = vec![0u8; READ_BUFFER];
    loop {
        match socket.read(&mut buffer) {
            Ok(count) if killed.load(Ordering::Acquire) => {
                if count == 0 {
                    return;
                }
            }
            // The peer closed its write half. EOF rather than CLOSE: it may still be reading.
            Ok(0) => {
                send(writer, stream, EOF, &[]);
                return;
            }
            Ok(count) => {
                if !send(writer, stream, DATA, &buffer[..count]) {
                    return;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            // A reset. The stream is over for both halves: the writer may be parked on the channel
            // where no socket error reaches it, so it is told.
            Err(_) => {
                kill_own(open, stream, token);
                return;
            }
        }
    }
}

/// One half of a forward is done. The last one out forgets the stream and sends the one CLOSE —
/// the agent's last word on the stream, after every DATA and EOF, on every path: a peer that
/// finished, a client that sent CLOSE, a budget that ran out, a reset. Unless the connection is
/// already gone, in which case there is nobody to say it to.
fn finish(
    halves: &AtomicUsize,
    open: &Mutex<HashMap<u32, Conn>>,
    stream: u32,
    token: u64,
    writer: &SharedWriter,
) {
    if halves.fetch_sub(1, Ordering::AcqRel) != 1 {
        return;
    }
    if forget(open, stream, token).is_some() {
        send(writer, stream, CLOSE, &[]);
    }
}

/// Handle one Forward envelope. Shaped like `file::dispatch`, but the payload is an opcode and a
/// body rather than a chunk flag and JSON.
pub fn dispatch(envelope: &Envelope, writer: &SharedWriter, forwards: &Forwards) {
    // No agent-initiated stream on this service, so stream 0 carries nothing.
    if envelope.stream == 0 {
        return;
    }
    let Some((&opcode, body)) = envelope.payload.split_first() else {
        return;
    };
    match opcode {
        OPEN => forwards.open(envelope.stream, body, writer),
        // Borrowed: the copy is made after the stream is found to be forwarding, so a DATA storm
        // on unknown ids costs the connection's reader a map lookup each, not a 1 MiB allocation.
        DATA => forwards.deliver(envelope.stream, body),
        EOF => forwards.half_close(envelope.stream),
        CLOSE => forwards.close(envelope.stream),
        // A REPLY from a client, or anything else: dropped, as `serve.rs` drops an unknown service.
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::Receiver as Rx;

    /// Everything the agent wrote toward the client, for the tests that have no socket.
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

    /// A forward registered by hand, with nothing draining it — the state a socket writer parked on
    /// a peer that has stopped reading would be in, without needing a peer that stops reading.
    fn stalled(forwards: &Forwards, stream: u32) -> Rx<Msg> {
        let (tx, rx) = channel();
        forwards.live.fetch_add(1, Ordering::AcqRel);
        forwards.open.lock().unwrap().insert(
            stream,
            Conn {
                tx,
                queued: Arc::new(AtomicUsize::new(0)),
                socket: Arc::new(Mutex::new(None)),
                token: 0,
                killed: Arc::new(AtomicBool::new(false)),
                half_closed: AtomicBool::new(false),
            },
        );
        rx
    }

    fn killed(forwards: &Forwards, stream: u32) -> bool {
        forwards.open.lock().unwrap()[&stream]
            .killed
            .load(Ordering::Acquire)
    }

    /// The opcodes the agent wrote toward the client, in order, with their streams.
    fn sent(capture: &Capture) -> Vec<(u32, u8)> {
        let written = capture.0.lock().unwrap().clone();
        let mut decoder = crate::protocol::envelope::EnvelopeDecoder::new();
        decoder.push(&written);
        std::iter::from_fn(|| decoder.next_envelope().unwrap())
            .map(|e| (e.stream, e.payload[0]))
            .collect()
    }

    /// A task as `open` would have built it, for the connect-window tests.
    fn task_for(forwards: &Forwards, port: u16, writer: SharedWriter) -> (ForwardTask, Rx<Msg>) {
        let (tx, rx) = channel();
        let (_, probe) = channel();
        let killed = Arc::new(AtomicBool::new(false));
        let socket = Arc::new(Mutex::new(None));
        let conn = Conn {
            tx,
            queued: Arc::new(AtomicUsize::new(0)),
            socket: Arc::clone(&socket),
            token: 0,
            killed: Arc::clone(&killed),
            half_closed: AtomicBool::new(false),
        };
        forwards.open.lock().unwrap().insert(1, conn);
        let task = ForwardTask {
            stream: 1,
            token: 0,
            addresses: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            port,
            rx,
            queued: Arc::new(AtomicUsize::new(0)),
            socket,
            killed,
            open: Arc::clone(&forwards.open),
            writer,
        };
        (task, probe)
    }

    fn refusal(body: &[u8]) -> Value {
        match target(body) {
            Err(refusal) => refusal.value(),
            Ok(_) => panic!("expected a refusal"),
        }
    }

    #[test]
    fn only_the_three_loopback_literals_are_accepted() {
        assert_eq!(
            loopback_addresses("127.0.0.1"),
            Some(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)])
        );
        assert_eq!(
            loopback_addresses("::1"),
            Some(vec![IpAddr::V6(Ipv6Addr::LOCALHOST)])
        );
        // Both, because a server may be bound to only one of them.
        assert_eq!(loopback_addresses("localhost").unwrap().len(), 2);
        assert_eq!(loopback_addresses("LocalHost").unwrap().len(), 2);
    }

    /// The allowlist is a list of literals, not a range and not a resolution: anything else is
    /// refused, including addresses that WOULD resolve to the loopback interface.
    #[test]
    fn everything_else_is_not_loopback() {
        for host in [
            "127.0.0.2",
            "127.1",
            "0.0.0.0",
            "localhost.evil.test",
            "evil.test",
            "10.0.0.1",
            "[::1]",
            "::ffff:127.0.0.1",
            "",
            " 127.0.0.1",
        ] {
            assert!(loopback_addresses(host).is_none(), "{host:?}");
        }
    }

    #[test]
    fn an_open_request_parses_to_an_address_and_a_port() {
        let (addresses, port) = target(br#"{"method":"open","host":"127.0.0.1","port":5173}"#)
            .ok()
            .expect("parsed");
        assert_eq!(addresses, vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]);
        assert_eq!(port, 5173);
    }

    #[test]
    fn a_non_loopback_host_is_refused_by_the_parser_before_any_socket_work() {
        let error = refusal(br#"{"method":"open","host":"10.0.0.1","port":80}"#);
        assert_eq!(
            error["error"]["refused"],
            "10.0.0.1 is not a loopback address"
        );
        assert_eq!(error["version"], FORWARD_SERVICE_VERSION);
    }

    #[test]
    fn a_malformed_request_is_unsupported_rather_than_a_dropped_stream() {
        // Not JSON at all — a DATA payload that arrived before its OPEN, say.
        assert_eq!(
            refusal(b"\x00\x01binary")["error"]["unsupported"],
            "forward requests are a single JSON object"
        );
        for body in [
            &br#"{"method":"open","host":"127.0.0.1"}"#[..],
            br#"{"method":"open","port":5173}"#,
            br#"{"method":"listen","host":"127.0.0.1","port":5173}"#,
            // Ports are u16: 0 is legal to ASK for, 65536 is not a port at all.
            br#"{"method":"open","host":"127.0.0.1","port":65536}"#,
            br#"{"method":"open","host":"127.0.0.1","port":-1}"#,
            // Unknown fields are refused, so the request shape cannot drift silently.
            br#"{"method":"open","host":"127.0.0.1","port":80,"bind":"0.0.0.0"}"#,
            br#"{"#,
        ] {
            assert!(
                refusal(body)["error"]["unsupported"].is_string(),
                "{}",
                String::from_utf8_lossy(body)
            );
        }
    }

    /// The branch the whole backpressure argument rests on: a forward whose bytes are not being
    /// taken is killed at the budget rather than buffered without limit. Killed, not closed from
    /// here: the writer parked on `recv` gets the message, the entry stays so the id cannot be
    /// re-opened under it, and the CLOSE is the threads' to send once they are out.
    #[test]
    fn a_forward_that_falls_past_the_queue_budget_is_killed_rather_than_buffered() {
        let forwards = Forwards::new();
        let capture = Capture::default();
        let rx = stalled(&forwards, 1);

        let chunk = vec![7u8; 256 * 1024];
        let mut delivered = 0;
        while !killed(&forwards, 1) {
            forwards.deliver(1, &chunk);
            delivered += chunk.len();
            assert!(
                delivered <= MAX_QUEUED_BYTES + chunk.len(),
                "the budget was never enforced: {delivered} bytes queued"
            );
        }
        // Enforced at the budget, not somewhere short of it: bytes plus the per-message overhead.
        let charged = delivered + MESSAGE_OVERHEAD * (delivered / chunk.len());
        assert!(charged > MAX_QUEUED_BYTES, "killed early at {delivered}");
        // Every chunk but the one that overflowed, then the kill that unparks the writer.
        let mut messages = 0;
        loop {
            match rx.try_recv() {
                Ok(Msg::Data(_)) => messages += 1,
                Ok(Msg::Kill) => break,
                other => panic!("expected the kill after the data, got {}", other.is_ok()),
            }
        }
        assert_eq!(messages, delivered / chunk.len() - 1);
        // Nothing said from here, and nothing more queued: the forward is over.
        assert!(sent(&capture).is_empty());
        forwards.deliver(1, &chunk);
        assert!(rx.try_recv().is_err());
        assert!(
            forwards.open.lock().unwrap().contains_key(&1),
            "the id is still held"
        );
    }

    /// Empty DATA and a second EOF are not free: each would be a channel node behind a stalled
    /// writer. Empty DATA is dropped (nothing to write), EOF is queued once.
    #[test]
    fn empty_messages_do_not_grow_the_queue() {
        let forwards = Forwards::new();
        let rx = stalled(&forwards, 1);
        for _ in 0..10_000 {
            forwards.deliver(1, &[]);
            forwards.half_close(1);
        }
        let mut eofs = 0;
        while let Ok(message) = rx.try_recv() {
            assert!(matches!(message, Msg::Eof));
            eofs += 1;
        }
        assert_eq!(eofs, 1);
        assert!(!killed(&forwards, 1));
    }

    /// After the client's own EOF there is no writer to take its bytes, so they are dropped rather
    /// than charged to a budget that would eventually kill a healthy forward still relaying the
    /// peer's reply.
    #[test]
    fn data_after_the_clients_eof_is_dropped_not_charged() {
        let forwards = Forwards::new();
        let rx = stalled(&forwards, 1);
        forwards.half_close(1);
        let chunk = vec![7u8; 512 * 1024];
        for _ in 0..8 {
            forwards.deliver(1, &chunk);
        }
        assert!(!killed(&forwards, 1), "charged for bytes nobody would take");
        assert!(matches!(rx.try_recv(), Ok(Msg::Eof)));
        assert!(rx.try_recv().is_err());
    }

    /// A client's CLOSE kills the forward and holds its entry: the threads answer with CLOSE, and
    /// until they have, the id cannot be re-opened under them.
    #[test]
    fn a_client_close_kills_the_forward_and_holds_the_id() {
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let rx = stalled(&forwards, 1);
        forwards.close(1);
        assert!(killed(&forwards, 1));
        assert!(matches!(rx.try_recv(), Ok(Msg::Kill)));
        assert!(
            sent(&capture).is_empty(),
            "the threads say CLOSE, not the dispatcher"
        );
        forwards.open(
            1,
            br#"{"method":"open","host":"127.0.0.1","port":1}"#,
            &writer,
        );
        let reply = sent(&capture);
        assert_eq!(
            reply,
            vec![(1, REPLY)],
            "refused without a CLOSE: {reply:?}"
        );
    }

    /// An OPEN for a stream that is already forwarding is refused whatever its body, and never
    /// closed: a malformed duplicate used to take the parse-error branch first and send a CLOSE
    /// for a healthy forward the agent kept running.
    #[test]
    fn a_malformed_open_for_an_already_forwarding_stream_does_not_close_it() {
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let _rx = stalled(&forwards, 1);
        for body in [
            &br#"{"method":"listen"}"#[..],
            b"garbage",
            br#"{"method":"open","host":"10.0.0.1","port":1}"#,
        ] {
            forwards.open(1, body, &writer);
        }
        assert!(forwards.open.lock().unwrap().contains_key(&1));
        assert!(!killed(&forwards, 1));
        let opcodes = sent(&capture);
        assert_eq!(opcodes.len(), 3);
        assert!(opcodes.iter().all(|(_, op)| *op == REPLY), "{opcodes:?}");
    }

    /// The cap counts forwards alive, and the 65th is refused.
    #[test]
    fn the_65th_forward_on_a_connection_is_refused() {
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let _held: Vec<_> = (1..=MAX_FORWARDS as u32)
            .map(|stream| stalled(&forwards, stream))
            .collect();
        forwards.open(
            MAX_FORWARDS as u32 + 1,
            br#"{"method":"open","host":"127.0.0.1","port":1}"#,
            &writer,
        );
        assert_eq!(
            sent(&capture),
            vec![
                (MAX_FORWARDS as u32 + 1, REPLY),
                (MAX_FORWARDS as u32 + 1, CLOSE)
            ]
        );
        assert!(!forwards
            .open
            .lock()
            .unwrap()
            .contains_key(&(MAX_FORWARDS as u32 + 1)));
    }

    /// The connection went away while the connect was still in flight (`Forwards::drop` took the
    /// entry): the socket that connect produces belongs to nobody, so it is shut down on the spot
    /// and nothing is said — there is nobody to say it to.
    #[test]
    fn a_departure_that_lands_during_the_connect_shuts_the_socket_and_says_nothing() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (task, _probe) = task_for(&forwards, port, writer);
        forwards.open.lock().unwrap().clear();
        connect_and_run(task);

        let (mut accepted, _) = listener.accept().unwrap();
        accepted
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        // The peer sees EOF at once: the socket was shut down, not parked on a reader thread.
        assert_eq!(accepted.read(&mut [0u8; 8]).unwrap(), 0);
        assert!(sent(&capture).is_empty(), "no REPLY, no CLOSE");
        assert!(forwards.open.lock().unwrap().is_empty());
    }

    /// The client sent CLOSE while the connect was still in flight: the socket is shut down on the
    /// spot, the client gets the CLOSE it is waiting for and no `opened`, and the id is free.
    #[test]
    fn a_close_that_lands_during_the_connect_is_answered_with_close_alone() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (task, _probe) = task_for(&forwards, port, writer);
        forwards.close(1);
        connect_and_run(task);

        let (mut accepted, _) = listener.accept().unwrap();
        accepted
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        assert_eq!(accepted.read(&mut [0u8; 8]).unwrap(), 0);
        assert_eq!(sent(&capture), vec![(1, CLOSE)]);
        assert!(forwards.open.lock().unwrap().is_empty());
    }

    /// The same, on the failure path: a connect that fails after the client gave up says CLOSE and
    /// no error — and one that fails while the connection is gone says nothing at all.
    #[test]
    fn a_failing_connect_answers_only_what_the_client_is_still_waiting_for() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (task, _probe) = task_for(&forwards, port, writer.clone());
        connect_and_run(task);
        assert_eq!(
            sent(&capture),
            vec![(1, REPLY), (1, CLOSE)],
            "still wanted: error, then CLOSE"
        );

        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (task, _probe) = task_for(&forwards, port, writer.clone());
        forwards.close(1);
        connect_and_run(task);
        assert_eq!(sent(&capture), vec![(1, CLOSE)], "killed: CLOSE alone");

        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (task, _probe) = task_for(&forwards, port, writer);
        forwards.open.lock().unwrap().clear();
        connect_and_run(task);
        assert!(sent(&capture).is_empty(), "gone: nothing");
    }

    /// A host as long as an envelope allows must not produce a reply longer than one: the refusal
    /// abbreviates what it echoes, and `send` refuses rather than asserts in any case.
    #[test]
    fn a_huge_host_gets_a_bounded_refusal_rather_than_a_panic() {
        let host = "h".repeat(MAX_ENVELOPE_PAYLOAD - 64);
        let body = format!(r#"{{"method":"open","host":"{host}","port":1}}"#);
        let error = refusal(body.as_bytes());
        let detail = error["error"]["refused"].as_str().unwrap();
        assert!(detail.len() < 200, "{}", detail.len());
        assert!(detail.ends_with("… is not a loopback address"));

        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        assert!(!send(&writer, 1, DATA, &vec![0u8; MAX_ENVELOPE_PAYLOAD]));
        assert!(sent(&capture).is_empty());
    }

    /// Bytes for a stream nobody opened are dropped, not answered and not queued — the same silence
    /// `serve.rs` gives a service byte it does not handle.
    #[test]
    fn bytes_for_an_unknown_stream_are_dropped() {
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        forwards.deliver(99, b"nobody is listening");
        forwards.half_close(99);
        forwards.close(99);
        assert!(capture.0.lock().unwrap().is_empty());
        drop(writer);
    }

    /// The whole request object, and nothing else: the Swift client is written from this shape.
    #[test]
    fn the_request_is_exactly_method_host_and_port() {
        let request: Request =
            serde_json::from_slice(br#"{"method":"open","host":"localhost","port":0}"#).unwrap();
        assert_eq!(
            request,
            Request {
                method: "open".into(),
                host: Some("localhost".into()),
                port: Some(0),
            }
        );
    }
}
