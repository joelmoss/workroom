//! The request/reply plumbing every request-per-stream service shares: the connection's writer,
//! chunked replies, chunked-request reassembly, and the one admission budget that a hand-off and
//! idle-exit both consult. Services depend on this rather than on each other: it used to live in
//! `vcs` and `session`, which made every service depend on both.
use serde_json::{Value, json};
use std::io::Write;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use wr_protocol::envelope::{Envelope, MAX_ENVELOPE_PAYLOAD, Service};
use wr_protocol::reply::Reply;
use wr_vcs_model::VcsError;

/// A connection's write half, shared with whichever session it is attached to.
///
/// Boxed because the reader below holds it for the session's life and must not be generic over the
/// transport — a session outlives the connection that created it, and the next one may arrive over
/// a different kind of stream entirely.
pub type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;

pub(crate) const MAX_RESPONSE: usize = 16 * 1024 * 1024;

/// Headroom left for everything in an exec reply that is not the two captured streams: the keys,
/// the exit code, the two booleans, the envelope framing, and JSON's own punctuation. Generous on
/// purpose — the cost of over-reserving is a few KiB of output, the cost of under-reserving is the
/// whole reply being replaced by an error.
pub(crate) const EXEC_REPLY_RESERVE: usize = 64 * 1024;

/// An UPPER BOUND on what this text costs once JSON-escaped, which is what `MAX_RESPONSE` bounds.
///
/// A bound, not an exact count: serde emits `\b` (0x08) and `\f` (0x0C) as two bytes where this
/// charges six. Over-estimating is the safe direction — it truncates fractionally early and can
/// never overflow the ceiling — and getting it exact would mean tracking serde's escape table here,
/// which is a coupling worth more than the handful of bytes it buys.
///
/// The expansion is why the two caps could not both be satisfied: a control byte serializes as
/// `\u0001`, six bytes for one, so two streams at `exec::MAX_EXEC_STREAM` (4 MiB each) reach 48 MiB
/// of wire form against a 16 MiB ceiling. Codex reproduced it with 3 MiB of `0x01`.
pub(crate) fn escaped_len(text: &str) -> usize {
    text.chars()
        .map(|c| match c {
            '"' | '\\' | '\n' | '\r' | '\t' => 2,
            c if (c as u32) < 0x20 => 6,
            c => c.len_utf8(),
        })
        .sum()
}
/// The reassembled ceiling for a CHUNKED request, mirroring `MAX_RESPONSE` on the reply side. A
/// single-envelope request is still bounded by `MAX_ENVELOPE_PAYLOAD` (1 MiB) as before.
const MAX_REQUEST: usize = 16 * 1024 * 1024;
/// First byte of a chunked request envelope. A whole request is JSON and therefore always starts
/// `{`, so this is unambiguous — and it is what keeps an UNCHUNKED request byte-identical to what
/// the previous protocol sent, rather than adding a header to every request to serve the rare one.
const REQUEST_CHUNK_MARKER: u8 = 0x02;
/// Every byte buffered across all of ONE connection's partial requests. Per-stream caps alone would
/// still allow 32 × `MAX_REQUEST` = 512 MiB of peer-controlled memory, which is not a bound worth
/// having on a background daemon.
const MAX_PARTIAL_TOTAL: usize = 32 * 1024 * 1024;

/// In-progress chunked requests for ONE connection, keyed by stream.
///
/// Owned by `handle_connection` and threaded in, exactly as `attached` and `token` already are —
/// NOT a process-global, which the first version of this was and which was wrong three ways at once.
/// Stream ids restart at 1 on every connect (`DaemonVCSConnection.nextStream`) while the daemon is
/// deliberately long-lived ("negotiated with, never replaced"), so a global keyed by stream alone
/// let one app launch's abandoned buffer corrupt the next launch's identically-numbered request. A
/// global also had no teardown: a client that vanished mid-request left its entry behind forever,
/// and since `is_busy()` consulted it, that entry kept the daemon from ever idle-exiting.
///
/// Per-connection state fixes all three by construction: the map dies with the connection, ids
/// cannot collide across connections, and a live connection is already counted busy by `serve`'s own
/// `connections > 0` check — so `is_busy()` does not need to know about partial requests at all.
#[derive(Default)]
pub struct PartialRequests {
    /// `None` buffer ⇒ POISONED: the request was already refused and its remaining chunks must be
    /// swallowed rather than starting a fresh buffer. Without that, the tail of a rejected request
    /// would reassemble as a new one, fail to parse, and produce a SECOND reply on a stream the
    /// client has already completed — and an unknown stream id is a protocol violation that tears
    /// down every other in-flight request on the connection.
    streams: std::collections::HashMap<u32, Option<Vec<u8>>>,
}

static ACTIVE: AtomicUsize = AtomicUsize::new(0);
/// The most request-per-thread requests in flight at once, across every service that takes a
/// `Permit`. A request past it is answered `LockContention` rather than queued.
pub(crate) const MAX_ACTIVE: usize = 32;

/// One of the `MAX_ACTIVE` slots. Held for the whole life of a request's thread, so `is_busy()`
/// stays true until the work — not merely the reply — is finished. Shared by `Service::Vcs` and
/// `Service::File`: one budget for every thread the daemon spawns per request, so neither service
/// can starve the other and idle-exit has a single thing to ask.
pub(crate) struct Permit;

impl Permit {
    pub(crate) fn acquire() -> Option<Permit> {
        admit(&ACTIVE).then_some(Permit)
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::AcqRel);
        crate::daemon::serve::wake_idle();
    }
}

/// Set in `ACTIVE` while a hand-off waits for requests to drain. In the same word as the count, so
/// no request can start between the check and the wait.
const QUIETING: usize = 1 << (usize::BITS - 1);

/// Counts a request in, unless the limit is reached or a hand-off is waiting.
fn admit(count: &AtomicUsize) -> bool {
    count
        .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count & QUIETING == 0 && count < MAX_ACTIVE).then_some(count + 1)
        })
        .is_ok()
}

/// Stops new requests at once, then waits up to `timeout` for the running ones to finish. On
/// timeout it lets requests in again and returns false. Stopping first is what makes the wait end:
/// the count can only fall, where waiting for a moment with nothing running could wait forever
/// under steady traffic.
fn quiesce(count: &AtomicUsize, timeout: std::time::Duration) -> bool {
    count.fetch_or(QUIETING, Ordering::AcqRel);
    let deadline = std::time::Instant::now() + timeout;
    while count.load(Ordering::Acquire) != QUIETING {
        if std::time::Instant::now() >= deadline {
            count.fetch_and(!QUIETING, Ordering::AcqRel);
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    true
}

/// No request running and none able to start, for a hand-off (`crate::daemon::handoff`): proof that
/// no repository command is cut off by the exec. A request that arrives meanwhile is answered
/// `LockContention` rather than queued. Released on drop, which is only reached when the hand-off
/// did not happen.
pub(crate) struct Quiet;

impl Quiet {
    pub(crate) fn acquire(timeout: std::time::Duration) -> Option<Quiet> {
        quiesce(&ACTIVE, timeout).then_some(Quiet)
    }
}

impl Drop for Quiet {
    fn drop(&mut self) {
        ACTIVE.fetch_and(!QUIETING, Ordering::AcqRel);
    }
}

/// Whether any dispatched VCS or File request is still running. Consulted by `serve`'s idle-exit
/// check: a hard process exit while this is nonzero would cut a repository command off mid-flight,
/// not just drop a socket.
pub fn is_busy() -> bool {
    ACTIVE.load(Ordering::Acquire) > 0
}

/// Chunk a JSON reply across envelopes on `service`. Shared by every request/reply service, so the
/// chunk marker byte and the 16 MiB ceiling exist once.
///
/// A reply over the ceiling is replaced by a `VcsError`, the shape the Vcs, Layout and Status
/// clients decode. `Service::File` replies through `send_with`, with an error of its own.
pub(crate) fn send(writer: &SharedWriter, service: Service, stream: u32, value: Value) {
    send_with(writer, service, stream, value, || {
        json!(VcsError::PartialData("VCS reply exceeds 16 MiB".into()))
    });
}

/// `send`, with `too_large` the error that replaces a reply over the ceiling.
pub(crate) fn send_with(
    writer: &SharedWriter,
    service: Service,
    stream: u32,
    value: Value,
    too_large: impl FnOnce() -> Value,
) {
    let mut bytes = serde_json::to_vec(&value).expect("JSON value serializes");
    if bytes.len() > MAX_RESPONSE {
        bytes = serde_json::to_vec(&Reply::error(1, too_large())).unwrap();
    }
    let chunks = bytes.chunks(MAX_ENVELOPE_PAYLOAD - 1);
    let count = chunks.len();
    for (index, chunk) in chunks.enumerate() {
        let mut payload = vec![u8::from(index + 1 == count)];
        payload.extend_from_slice(chunk);
        let Ok(mut writer) = writer.lock() else {
            return;
        };
        if writer
            .write_all(&Envelope::new(service, stream, payload).encode())
            .and_then(|()| writer.flush())
            .is_err()
        {
            return;
        }
    }
}

/// Take the complete request bytes for this envelope, or `None` when more chunks are still coming.
///
/// `Err` is a request that broke the framing contract and gets a typed reply rather than silence.
pub(crate) fn reassemble(
    partial: &mut PartialRequests,
    envelope: &Envelope,
) -> Result<Option<Vec<u8>>, VcsError> {
    let payload = &envelope.payload;
    if payload.first() != Some(&REQUEST_CHUNK_MARKER) {
        // The overwhelmingly common case: one envelope, one request, no copy and no bookkeeping.
        return Ok(Some(payload.clone()));
    }
    let Some(&is_final) = payload.get(1) else {
        return Err(VcsError::PartialData("truncated request chunk".into()));
    };
    let streams = &mut partial.streams;

    // Already refused: swallow the rest in silence and clear on the last chunk. Replying again would
    // put a second reply on a stream the client has finished with.
    if let Some(None) = streams.get(&envelope.stream) {
        if is_final != 0 {
            streams.remove(&envelope.stream);
        }
        return Ok(None);
    }

    // Poison unless this WAS the last chunk, in which case there is nothing left to swallow.
    //
    // Poisoning is itself an insert, so it must never be the thing that breaks a cap: the stream-count
    // refusal below would otherwise add a 33rd entry in the act of enforcing a limit of 32. Refusals
    // that cannot record a poison simply drop the stream and let the tail be refused the same way.
    let refuse =
        |streams: &mut std::collections::HashMap<u32, Option<Vec<u8>>>, error, may_poison: bool| {
            if is_final == 0 && may_poison {
                streams.insert(envelope.stream, None);
            } else {
                streams.remove(&envelope.stream);
            }
            Err(error)
        };

    let incoming = payload.len() - 2;
    // The stream-count cap goes FIRST, because poisoning is itself an insert: refused after it, this
    // stream is either already known or there is room for it, so recording a poison can never be the
    // thing that breaks a cap. (A poison holds no bytes, so it cannot break the byte caps at all.)
    if !streams.contains_key(&envelope.stream) && streams.len() >= 32 {
        return refuse(streams, VcsError::LockContention, false);
    }
    let buffered: usize = streams
        .values()
        .map(|buffer| buffer.as_ref().map_or(0, Vec::len))
        .sum();
    if buffered + incoming > MAX_PARTIAL_TOTAL {
        return refuse(
            streams,
            VcsError::PartialData("too many large VCS requests in flight".into()),
            true,
        );
    }
    let buffer = streams
        .entry(envelope.stream)
        .or_insert_with(|| Some(Vec::new()))
        .get_or_insert_with(Vec::new);
    if buffer.len() + incoming > MAX_REQUEST {
        return refuse(
            streams,
            VcsError::PartialData("VCS request exceeds 16 MiB".into()),
            true,
        );
    }
    buffer.extend_from_slice(&payload[2..]);
    if is_final == 0 {
        return Ok(None);
    }
    Ok(streams.remove(&envelope.stream).flatten())
}

#[cfg(test)]
mod tests;
