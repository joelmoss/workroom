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
//! - `{"version":1,"error":{"<kind>":"<detail>"}}` — not connected, followed immediately by CLOSE.
//!
//! **A stream id is free again only once the client has seen its CLOSE**, which is the one rule a
//! client has to keep rather than infer. The agent holds the id from the moment OPEN arrives, so a
//! client that gives up on a slow `open` (the connect is bounded at 3 s, which is longer than a
//! client's own timeout is likely to be) and re-uses the id will be told `"stream <n> is already
//! forwarding"` for a forward that is about to fail and vanish. Wait for CLOSE, then re-use — or
//! simply never re-use, which is what a monotonic stream counter gets for free.
//!
//! The error kinds, exhaustively, with the exact detail strings where they are fixed:
//!
//! | kind | when |
//! |---|---|
//! | `unsupported` | `"forward requests are a single JSON object"` — the OPEN body does not start with `{` |
//! | `unsupported` | a serde message — malformed JSON, an unknown field, a missing or out-of-range `host`/`port` |
//! | `unsupported` | `"forward requests are {\"method\": \"open\", \"host\": …, \"port\": …}"` — a method other than `open` |
//! | `refused` | `"<host> is not a loopback address"` — the host is not one of the three literals below |
//! | `refused` | `"stream <n> is already forwarding"` — OPEN for a stream id that already has a connection |
//! | `refused` | `"too many forwarded connections"` — this multiplex connection already holds 64 |
//! | `connect` | the OS error text — connection refused, timed out (3s), unreachable |
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
//! - The TCP connection fails mid-stream → the agent sends CLOSE.
//! - The client sends EOF → the agent shuts down the socket's write half, so the peer sees EOF.
//! - The client sends CLOSE → the agent shuts the socket down entirely and forgets the stream.
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
//! forward**: the channel is unbounded and the OPEN's `connect` happens on the spawned thread, so a
//! forwarded socket that stalls cannot stop a terminal on the same connection from being read.
//!
//! What bounds the unbounded channel is a byte budget: a forward holding more than
//! [`MAX_QUEUED_BYTES`] of undelivered client bytes is killed with CLOSE rather than allowed to
//! grow. The multiplex has no per-stream flow control, so the choice is between buffering without
//! limit, blocking the reader thread, and dropping one stalled connection; only the third keeps the
//! other streams honest.
//!
//! The *writer* is the process-wide [`SharedWriter`], held for one envelope at a time — the same
//! discipline `vcs::send` and every session's output already use. A forward is not faster or slower
//! to starve than pty output is.
//!
//! A forward takes no request [`Permit`](crate::vcs::Permit): like a `watch` subscription it is a
//! resource that lives across many requests, not a request in flight, so it is capped separately
//! ([`MAX_FORWARDS`] per connection).

use crate::protocol::envelope::{Envelope, Service};
use crate::session::SharedWriter;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
/// loopback connect either completes in microseconds or is never going to.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

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
    let addresses = loopback_addresses(&host)
        .ok_or_else(|| Refusal::refused(format!("{host} is not a loopback address")))?;
    Ok((addresses, port))
}

/// One Forward envelope, written under the shared writer lock — one envelope at a time, exactly as
/// `vcs::send` writes one chunk at a time. `false` means the client is gone.
fn send(writer: &SharedWriter, stream: u32, opcode: u8, body: &[u8]) -> bool {
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

/// One forwarded connection, as the dispatching thread sees it.
struct Conn {
    /// Client bytes for the socket. `None` is the client's EOF. Unbounded, bounded by `queued`.
    tx: Sender<Option<Vec<u8>>>,
    queued: Arc<AtomicUsize>,
    /// A clone of the socket, kept only so another thread can `shutdown` it. `None` until the
    /// connect completes.
    socket: Arc<Mutex<Option<TcpStream>>>,
    /// Distinguishes THIS forward from a later one on the same stream id, so a finishing pair of
    /// threads cannot remove the entry a re-opened stream has since installed.
    token: u64,
}

impl Conn {
    /// Ends the connection now, from any thread: the shutdown unblocks the socket reader and any
    /// write in flight, and dropping `tx` ends the socket writer.
    fn shutdown(&self) {
        if let Ok(socket) = self.socket.lock() {
            if let Some(socket) = socket.as_ref() {
                let _ = socket.shutdown(Shutdown::Both);
            }
        }
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
        }
    }

    fn open(&self, stream: u32, body: &[u8], writer: &SharedWriter) {
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
        let token = self.next_token.fetch_add(1, Ordering::Relaxed) as u64;
        {
            let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
            if open.contains_key(&stream) {
                drop(open);
                send_reply(
                    writer,
                    stream,
                    &Refusal::refused(format!("stream {stream} is already forwarding")).value(),
                );
                // Deliberately NO close: the stream belongs to the forward that is already running
                // there, and closing it would tear down a healthy connection over a client bug.
                return;
            }
            if open.len() >= MAX_FORWARDS {
                drop(open);
                send_reply(
                    writer,
                    stream,
                    &Refusal::refused("too many forwarded connections").value(),
                );
                send(writer, stream, CLOSE, &[]);
                return;
            }
            open.insert(
                stream,
                Conn {
                    tx,
                    queued: Arc::clone(&queued),
                    socket: Arc::clone(&socket),
                    token,
                },
            );
        }

        // The connect runs HERE, not on the caller: `connect_timeout` blocks for up to three
        // seconds, and the caller is the connection's envelope reader.
        let open_map = Arc::clone(&self.open);
        let writer = Arc::clone(writer);
        std::thread::spawn(move || {
            connect_and_run(ForwardTask {
                stream,
                token,
                addresses,
                port,
                rx,
                queued,
                socket,
                open: open_map,
                writer,
            });
        });
    }

    /// Client bytes for a forwarded socket. Dropped if the stream is not forwarding, and the whole
    /// forward is killed if it has fallen too far behind.
    fn deliver(&self, stream: u32, bytes: Vec<u8>, writer: &SharedWriter) {
        let length = bytes.len();
        let overflowed = {
            let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
            let Some(conn) = open.get(&stream) else {
                return;
            };
            if conn.queued.fetch_add(length, Ordering::AcqRel) + length > MAX_QUEUED_BYTES {
                // One stalled forward dies rather than the agent buffering without limit. REMOVED,
                // not merely shut down: the socket writer may be parked on `recv` rather than on the
                // socket, where a shutdown would never reach it, and dropping the sender does.
                if let Some(conn) = open.remove(&stream) {
                    conn.shutdown();
                }
                true
            } else {
                let _ = conn.tx.send(Some(bytes));
                false
            }
        };
        // Said out here, with the map unlocked, and said by this thread because the pair that would
        // normally close the stream no longer owns an entry to close.
        if overflowed {
            send(writer, stream, CLOSE, &[]);
        }
    }

    /// The client will send no more: the socket's write half goes down so the peer sees EOF.
    fn half_close(&self, stream: u32) {
        let open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(conn) = open.get(&stream) {
            let _ = conn.tx.send(None);
        }
    }

    /// The client is done with the stream: the socket goes, and the entry with it.
    fn close(&self, stream: u32) {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(conn) = open.remove(&stream) {
            conn.shutdown();
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
    rx: Receiver<Option<Vec<u8>>>,
    queued: Arc<AtomicUsize>,
    socket: Arc<Mutex<Option<TcpStream>>>,
    open: Arc<Mutex<HashMap<u32, Conn>>>,
    writer: SharedWriter,
}

/// Forget this forward, if it is still the one registered. Returns whether it was.
fn forget(open: &Mutex<HashMap<u32, Conn>>, stream: u32, token: u64) -> bool {
    let mut open = open.lock().unwrap_or_else(|e| e.into_inner());
    match open.get(&stream) {
        Some(conn) if conn.token == token => {
            open.remove(&stream);
            true
        }
        _ => false,
    }
}

/// Connect, answer, then pump client bytes into the socket until either side is done.
///
/// This thread is the socket's WRITER; it spawns the reader. A connect failure is an error reply
/// and a CLOSE, never a dropped stream.
fn connect_and_run(task: ForwardTask) {
    let mut last = None;
    let mut connected = None;
    for address in &task.addresses {
        match TcpStream::connect_timeout(&SocketAddr::new(*address, task.port), CONNECT_TIMEOUT) {
            Ok(socket) => {
                connected = Some(socket);
                break;
            }
            Err(error) => last = Some(error),
        }
    }
    let Some(mut socket) = connected else {
        let detail = last.map_or_else(|| "no address to connect to".into(), |e| e.to_string());
        forget(&task.open, task.stream, task.token);
        send_reply(
            &task.writer,
            task.stream,
            &Refusal("connect", detail).value(),
        );
        send(&task.writer, task.stream, CLOSE, &[]);
        return;
    };

    // The clone is how `Forwards::drop`, a client CLOSE and the overflow kill all reach this
    // socket; the reader thread gets its own.
    let Ok(reader_socket) = socket.try_clone() else {
        forget(&task.open, task.stream, task.token);
        send_reply(
            &task.writer,
            task.stream,
            &Refusal("connect", "could not duplicate the socket".into()).value(),
        );
        send(&task.writer, task.stream, CLOSE, &[]);
        return;
    };
    // Registered under the map lock, so a CLOSE, an overflow kill or the connection's departure
    // that landed DURING the connect cannot be missed: the entry is gone, so is the client's
    // interest, and the socket goes with it. Silently — whoever removed the entry already said
    // CLOSE, or is no longer there to hear one. Without this, the socket would be registered
    // nowhere, the reader would pump DATA onto a stream id the client has since freed, and no
    // shutdown could ever reach it.
    {
        let open = task.open.lock().unwrap_or_else(|e| e.into_inner());
        let wanted = open
            .get(&task.stream)
            .is_some_and(|conn| conn.token == task.token);
        if !wanted {
            drop(open);
            let _ = socket.shutdown(Shutdown::Both);
            return;
        }
        if let Ok(mut held) = task.socket.lock() {
            *held = socket.try_clone().ok();
        }
    }

    // Answered BEFORE the reader starts, so the client can never see DATA ahead of the reply.
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
        let (stream, token) = (task.stream, task.token);
        std::thread::spawn(move || {
            pump_to_client(reader_socket, stream, &writer);
            finish(&halves, &open, stream, token, &writer);
        })
    };

    while let Ok(message) = task.rx.recv() {
        let Some(bytes) = message else {
            // The client half-closed: the peer sees EOF, and this direction is done.
            let _ = socket.shutdown(Shutdown::Write);
            break;
        };
        let wrote = socket.write_all(&bytes).and_then(|()| socket.flush());
        task.queued.fetch_sub(bytes.len(), Ordering::AcqRel);
        if wrote.is_err() {
            let _ = socket.shutdown(Shutdown::Both);
            break;
        }
    }
    finish(&halves, &task.open, task.stream, task.token, &task.writer);
    // Deliberately not joined: the reader is still legitimately blocked on a peer that has not
    // finished sending, and joining would park this thread for exactly as long for nothing.
    drop(reader);
}

/// Socket → client, until the peer closes or the connection fails.
fn pump_to_client(mut socket: TcpStream, stream: u32, writer: &SharedWriter) {
    let mut buffer = vec![0u8; READ_BUFFER];
    loop {
        match socket.read(&mut buffer) {
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
            // A reset, or the shutdown a close/overflow/detach performed. Either way the stream is
            // over; `finish` sends the CLOSE once the other half agrees.
            Err(_) => return,
        }
    }
}

/// One half of a forward is done. The last one out closes the stream toward the client and forgets
/// it — unless the client already forgot it first, in which case it has its own CLOSE.
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
    if forget(open, stream, token) {
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
        DATA => forwards.deliver(envelope.stream, body.to_vec(), writer),
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
    fn stalled(forwards: &Forwards, stream: u32) -> Rx<Option<Vec<u8>>> {
        let (tx, rx) = channel();
        forwards.open.lock().unwrap().insert(
            stream,
            Conn {
                tx,
                queued: Arc::new(AtomicUsize::new(0)),
                socket: Arc::new(Mutex::new(None)),
                token: 0,
            },
        );
        rx
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
    /// taken is dropped at the budget rather than buffered without limit, it is dropped
    /// COMPLETELY — the entry goes, so a socket writer parked on `recv` rather than on the socket
    /// still unblocks — and the client is told, so it is never left waiting on a dead stream.
    #[test]
    fn a_forward_that_falls_past_the_queue_budget_is_closed_rather_than_buffered() {
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let rx = stalled(&forwards, 1);

        let chunk = vec![7u8; 256 * 1024];
        let mut delivered = 0;
        while forwards.open.lock().unwrap().contains_key(&1) {
            forwards.deliver(1, chunk.clone(), &writer);
            delivered += chunk.len();
            assert!(
                delivered <= MAX_QUEUED_BYTES + chunk.len(),
                "the budget was never enforced: {delivered} bytes queued"
            );
        }
        // Enforced at the budget, not somewhere short of it.
        assert!(delivered > MAX_QUEUED_BYTES, "killed early at {delivered}");
        // This terminates at all only because the sender went with the entry, which is exactly what
        // unparks a socket writer blocked on `recv`; every chunk but the one that overflowed is here.
        assert_eq!(rx.iter().count(), delivered / chunk.len() - 1);
        // And the client was told, exactly once, on that stream.
        let written = capture.0.lock().unwrap().clone();
        let mut decoder = crate::protocol::envelope::EnvelopeDecoder::new();
        decoder.push(&written);
        let sent: Vec<(u32, u8)> = std::iter::from_fn(|| decoder.next_envelope().unwrap())
            .map(|e| (e.stream, e.payload[0]))
            .collect();
        assert_eq!(sent, vec![(1, CLOSE)]);
    }

    /// A CLOSE (or an overflow kill, or the connection going away) that lands while the connect is
    /// still in flight must not be lost: the socket that connect produces belongs to nobody, so it
    /// is shut down on the spot and the client hears nothing more on that stream — its CLOSE was
    /// the last word, and a stream id it has since re-used must never receive this forward's bytes.
    #[test]
    fn a_close_that_lands_during_the_connect_shuts_the_socket_and_says_nothing() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        // The entry a real OPEN would have registered was removed by a CLOSE before the connect
        // finished, so `open` holds nothing for this stream when the connect completes, and the
        // sender went with the entry.
        let (tx, rx) = channel();
        drop(tx);
        let task = ForwardTask {
            stream: 1,
            token: 0,
            addresses: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            port,
            rx,
            queued: Arc::new(AtomicUsize::new(0)),
            socket: Arc::new(Mutex::new(None)),
            open: Arc::clone(&forwards.open),
            writer,
        };
        connect_and_run(task);

        let (mut accepted, _) = listener.accept().unwrap();
        accepted
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        // The peer sees EOF at once: the socket was shut down, not parked on a reader thread.
        assert_eq!(accepted.read(&mut [0u8; 8]).unwrap(), 0);
        assert!(capture.0.lock().unwrap().is_empty(), "no REPLY, no CLOSE");
        assert!(forwards.open.lock().unwrap().is_empty());
    }

    /// Bytes for a stream nobody opened are dropped, not answered and not queued — the same silence
    /// `serve.rs` gives a service byte it does not handle.
    #[test]
    fn bytes_for_an_unknown_stream_are_dropped() {
        let forwards = Forwards::new();
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        forwards.deliver(99, b"nobody is listening".to_vec(), &writer);
        forwards.half_close(99);
        forwards.close(99);
        assert!(capture.0.lock().unwrap().is_empty());
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
