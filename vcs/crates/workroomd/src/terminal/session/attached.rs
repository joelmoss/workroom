//! Attached clients: attaching, the size owner, and delivering output to each client.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::keepalive::Keepalive;
use super::reader::READ_CHUNK;
use super::{
    Attached, Client, Hooks, NEXT_TOKEN, SessionError, SessionId, SessionInfo, SessionStore, Target,
};
use crate::daemon::rpc::{self, SharedWriter};
use crate::daemon::transport::{Closer, WRITE_TIMEOUT};
use crate::terminal::images;
use crate::terminal::input::InputClassifier;
use crate::terminal::pty::{Pty, Size};
use crate::terminal::shadow::Shadow;
use crate::util::lock_or_recover;
use wr_protocol::envelope::{Envelope, Service};
use wr_protocol::frame::{Frame, FrameKind};

impl SessionStore {
    /// Attaches a client and repaints it. Other clients keep their attachment.
    ///
    /// The repaint is written HERE, under the attachment lock, rather than by the caller after this
    /// returns. That ordering is the point: the reader takes the same lock around every write, so a
    /// repaint cannot be overtaken by output that arrives between registering and painting, and
    /// cannot duplicate output the shadow has already absorbed.
    ///
    /// `columns`/`rows` are what this client's window is; zero means it has none yet. A brand new
    /// session is unowned, so the first client to advertise a size takes it — otherwise a session
    /// would sit at its creation geometry until somebody typed.
    ///
    /// Returns the session's info and the attachment's token — hand that token back to `detach`.
    pub fn attach(
        &self,
        id: SessionId,
        writer: SharedWriter,
        stream: u32,
        size: Size,
    ) -> Result<(SessionInfo, u64), SessionError> {
        self.attach_client(id, writer, stream, size, None)
    }

    /// `attach`, for a client that may have asked to be probed (`keepalive`, #593): one that stops
    /// answering then stops counting as attached, and `keepalive`, which ends its connection, is
    /// called (ADR 0075).
    pub fn attach_client(
        &self,
        id: SessionId,
        writer: SharedWriter,
        stream: u32,
        size: Size,
        keepalive: Option<Closer>,
    ) -> Result<(SessionInfo, u64), SessionError> {
        let (pty, shadow, attached) = self
            .parts(id)
            .ok_or_else(|| SessionError::NotFound(id.to_hyphenated()))?;

        let probed = keepalive.is_some();
        let token = NEXT_TOKEN.fetch_add(1, Ordering::SeqCst);
        // Whether the repaint reached the client WHOLE. A client that only got part of one is not
        // registered below — see `SessionError::RepaintFailed`.
        let mut painted = true;
        let size = {
            let mut attached = lock_or_recover(&attached);
            let mut replay = live_replay(&pty, &shadow);
            if !replay.is_empty() {
                // First, in case this surface was left in a transfer cut off midway.
                replay.splice(0..0, images::ABORT.iter().copied());
                let held = rpc::with_writer(&writer, |writer| {
                    // CHUNKED, because `replay()` can be up to ~4 MiB (`REPAINT_MAX_BYTES`) and
                    // `Frame::encode` PANICS above the 1 MiB cap rather than truncating.
                    //
                    // A repaint is two full screens — `primary_screen()` plus the active one, each
                    // with per-cell SGR runs, palette, modes and tabstops — so a large window
                    // showing a heavily-styled TUI crosses the cap. The panic would unwind out of
                    // here still holding this guard, poisoning the mutex; `read_session` then hits
                    // its own `.expect` on the next chunk and dies, so the pty is never drained
                    // again and the shell blocks on write. One oversized repaint would take the
                    // whole session down for every client on it, permanently.
                    //
                    // Chunking rather than truncating: terminal output is a byte stream, the live
                    // path already delivers it in arbitrary `READ_CHUNK`-sized pieces, and the
                    // envelope codec is explicitly built to survive a stream that chunks
                    // arbitrarily. A truncated repaint would instead leave the client's parser
                    // mid-sequence with the continuation record never arriving. (Every lock is now
                    // recovered from poisoning, so a panic here no longer ends the reader: see the
                    // lock order on `SessionStore`.)
                    // ONE budget for the whole repaint, not one timeout per chunk.
                    //
                    // These writes happen under the attachment lock, which the reader takes around
                    // every delivery — so while this runs, the pty is not drained for ANY client
                    // on the session. Holding it is deliberate (the ordering note above) but it
                    // has to be BOUNDED, and `SO_SNDTIMEO` bounds a single `write`, not a loop of
                    // them: a peer reading just slowly enough that each chunk succeeds just under
                    // the limit would hold the lock for chunks × timeout. Chunking is what made
                    // that reachable, so the bound lands with it.
                    //
                    // A client too slow to take its own repaint inside the budget is not attached
                    // at all — see `SessionError::RepaintFailed`. The budget is enforced BETWEEN
                    // chunks, so a single `write_all` already in progress can overshoot it by up to
                    // one `WRITE_TIMEOUT`; bounding that too would mean a non-blocking writer, and
                    // one chunk of overshoot is the same bound the unchunked version had.
                    //
                    // Removing the lock-hold entirely, as the live path does, needs a per-client
                    // pending queue: releasing it here reverses the repaint against output that
                    // arrives mid-paint, and painting before registering misses that output
                    // instead. Bounded, not eliminated.
                    // The budget SCALES with the payload, and that is not a detail.
                    //
                    // `WRITE_TIMEOUT` means "the peer made no progress for this long" everywhere
                    // else — `FdStream::write` resets it per call. Reusing it as a flat wall-clock
                    // budget for the whole repaint turned it into a THROUGHPUT FLOOR: a peer that
                    // is healthy and reading continuously, but slower than `replay.len()` per ten
                    // seconds, failed deterministically. On the stated remote transport (`serve
                    // --stdio` over ssh) with a large styled screen that is a real link, and the
                    // penalty is not slowness but a permanently unattachable session, since every
                    // retry repeats it.
                    //
                    // So: `WRITE_TIMEOUT` of slack, plus the time the payload needs at a floor
                    // throughput. Still bounded — that is what keeps the lock hold finite — but the
                    // bound is one a working peer cannot trip.
                    let deadline = Instant::now() + repaint_budget(replay.len());
                    for chunk in replay.chunks(READ_CHUNK) {
                        if Instant::now() >= deadline {
                            painted = false;
                            break;
                        }
                        let bytes = terminal_envelope(
                            stream,
                            Frame::new(FrameKind::Output, chunk.to_vec()),
                        );
                        if writer
                            .write_all(&bytes)
                            .and_then(|()| writer.flush())
                            .is_err()
                        {
                            painted = false;
                            break;
                        }
                    }
                    // A partial repaint is bytes the client has ALREADY rendered, mid-escape-
                    // sequence at an arbitrary chunk boundary. Failing the attach stops it
                    // receiving more, but it does not un-draw what arrived — the comment on
                    // `RepaintFailed` used to claim otherwise, and that claim was simply wrong.
                    //
                    // RIS puts the terminal back to a known state, so the pane the caller falls
                    // back to starts clean instead of inheriting a half-parsed escape. Best
                    // effort: if this write fails too, the peer is gone and there is nothing left
                    // to reset.
                    if !painted {
                        let reset = terminal_envelope(
                            stream,
                            Frame::new(FrameKind::Output, b"\x1bc".to_vec()),
                        );
                        let _ = writer.write_all(&reset).and_then(|()| writer.flush());
                    }
                });
                if held.is_none() {
                    // The connection is gone (`rpc::with_writer`): nothing was painted, so do not
                    // register.
                    painted = false;
                }
            }
            if painted {
                let visible = lock_or_recover(&shadow).visible_images();
                let transfer = images::start_transfer(visible, &shadow, &pty);
                attached.clients.push(Client {
                    writer,
                    stream,
                    token,
                    columns: size.columns,
                    rows: size.rows,
                    pixels: (size.x_pixels, size.y_pixels),
                    classifier: InputClassifier::new(),
                    transfer,
                    keepalive: keepalive.map(Keepalive::new),
                });
                // Attaching does not TAKE the size from a client that has it — that needs an act.
                // It only fills a vacancy.
                match attached.owner {
                    Some(_) => None,
                    None => attached.claim(token),
                }
            } else {
                // Not registered, so it owns no size and receives no live output. The caller turns
                // this into a `Failure` frame.
                None
            }
        };
        // The repaint read the shadow, which re-inflates its compressed history: the screens
        // thread compresses it again on its next pass, even when this client claimed no size or
        // its connection dropped mid-repaint.
        self.hooks.screen_changed();
        // Checked after the lock is released, so the early `return None` above leaves nothing
        // registered and nothing half-owned.
        if !painted {
            return Err(SessionError::RepaintFailed(id.to_hyphenated()));
        }
        apply_size(&pty, &shadow, &attached, size, &self.hooks);
        if probed {
            self.start_keepalive();
        }

        let sessions = lock_or_recover(&self.sessions);
        let session = sessions
            .get(&id)
            .ok_or_else(|| SessionError::NotFound(id.to_hyphenated()))?;
        Ok((session.info(), token))
    }

    /// The client went away. The session and its pty keep running — that is the entire point, and
    /// the reader keeps draining the pty so a detached job neither stalls nor goes unrecorded.
    ///
    /// Only removes the client holding `token`: a superseded client's connection ending must not
    /// detach the client that superseded it.
    ///
    /// **If exactly one client is left, it takes the size immediately** rather than waiting to be
    /// claimed. Closing one laptop must not strand the terminal at the geometry of the window that
    /// just went away. Unless it has stopped answering its probes (#593): that one's window is on
    /// a Mac nobody is at, so the size stays free for the next client to fill.
    pub fn detach(&self, id: SessionId, token: u64) {
        let Some((pty, shadow, attached)) = self.parts(id) else {
            return;
        };
        let size = {
            let mut attached = lock_or_recover(&attached);
            attached.clients.retain(|client| client.token != token);
            if attached.owner == Some(token) {
                attached.owner = None;
            }
            attached.claim_for_sole_survivor()
        };
        apply_size(&pty, &shadow, &attached, size, &self.hooks);
    }

    /// A client's window changed size.
    ///
    /// Always recorded, applied only if that client owns the size or nobody does. A background
    /// window resizing must not move the pty out from under the person typing in another one.
    pub fn resize(&self, id: SessionId, token: u64, size: Size) {
        let Some((pty, shadow, attached)) = self.parts(id) else {
            return;
        };
        let size = {
            let mut attached = lock_or_recover(&attached);
            let Some(client) = attached.client(token) else {
                return;
            };
            client.columns = size.columns;
            client.rows = size.rows;
            client.pixels = (size.x_pixels, size.y_pixels);
            match attached.owner {
                Some(owner) if owner == token => attached.owned_size(),
                Some(_) => None,
                None => attached.claim(token),
            }
        };
        apply_size(&pty, &shadow, &attached, size, &self.hooks);
    }

    /// Input from a client: claims the size if it is the USER acting, then goes to the pty.
    ///
    /// Typing or clicking in a pane is what makes it yours. A terminal answering a query is not —
    /// see `crate::terminal::input` for why that distinction needs a parser.
    ///
    /// From a probed client (`keepalive`), any input shows it is still there, and its answers to
    /// the probe are taken out first: they are for the daemon, never the program. One that had
    /// stopped answering is attached again, and fills the size if nobody holds it, as an attach
    /// does.
    pub fn write_input(&self, id: SessionId, token: u64, bytes: &[u8]) {
        let Some((pty, shadow, attached)) = self.parts(id) else {
            return;
        };
        let mut stripped = None;
        let size = {
            let mut attached = lock_or_recover(&attached);
            let mut returned = false;
            if let Some(keepalive) = attached
                .client(token)
                .and_then(|client| client.keepalive.as_mut())
            {
                returned = keepalive.heard();
                stripped = Some(keepalive.strip(bytes));
            }
            let input = stripped.as_deref().unwrap_or(bytes);
            let acted = attached
                .client(token)
                .is_some_and(|client| client.classifier.is_user_input(input));
            let vacant = attached.owner.is_none();
            if (acted && attached.owner != Some(token)) || (returned && vacant) {
                attached.claim(token)
            } else {
                None
            }
        };
        apply_size(&pty, &shadow, &attached, size, &self.hooks);
        let input = stripped.as_deref().unwrap_or(bytes);
        if !input.is_empty() {
            let _ = pty.write_all(input);
        }
    }

    /// Who owns the size, for tests and diagnostics.
    #[cfg(any(test, feature = "test-support"))]
    pub fn size_owner(&self, id: SessionId) -> Option<u64> {
        let (_, _, attached) = self.parts(id)?;

        lock_or_recover(&attached).owner
    }

    /// What a client attaching to this session should be sent before anything else, so it sees
    /// the screen rather than waiting for the next keystroke to produce output.
    #[cfg(any(test, feature = "test-support"))]
    pub fn replay_bytes(&self, id: SessionId) -> Vec<u8> {
        match self.parts(id) {
            Some((pty, shadow, _)) => live_replay(&pty, &shadow),
            None => Vec::new(),
        }
    }
}

impl Client {
    pub(super) fn target(&self) -> Target {
        Target {
            writer: Arc::clone(&self.writer),
            stream: self.stream,
            token: self.token,
            abort_at: None,
        }
    }
}

/// Every attached client, as detached copies.
pub(super) fn targets(attached: &Arc<Mutex<Attached>>) -> Vec<Target> {
    lock_or_recover(attached)
        .clients
        .iter()
        .map(Client::target)
        .collect()
}

/// Writes to one client, and EVICTS it if the write fails.
///
/// Eviction is the point. A client that has stopped reading fails its write after the transport's
/// deadline, and leaving it installed means paying that deadline again on the very next chunk of
/// output — the session would spend its life stalling on a peer that is never coming back. Dropping
/// it costs nothing: the session and its pty carry on, and the client reattaches like any other.
///
/// Returns a size to apply if evicting left exactly one client, which then owns it — the same rule
/// `detach` follows, for the same reason: a peer that died must not strand the survivor at a
/// geometry belonging to a window nobody is looking at.
pub(super) fn deliver(
    attached: &Arc<Mutex<Attached>>,
    target: &Target,
    bytes: &[u8],
) -> Option<Size> {
    let delivered = rpc::write(&target.writer, bytes);
    if delivered {
        return None;
    }
    let mut attached = lock_or_recover(attached);
    attached
        .clients
        .retain(|client| client.token != target.token);
    if attached.owner == Some(target.token) {
        attached.owner = None;
    }
    attached.claim_for_sole_survivor()
}

/// Resizes the pty and the shadow together, if there is a size to apply.
///
/// The shadow has to follow the pty or a reattaching client is repainted at the wrong geometry and
/// every wrapped line is wrong. Both happen under the attachment lock, so a hand-off freezing the
/// session (`SessionStore::frozen`) never records one size with a screen drawn at the other.
pub(super) fn apply_size(
    pty: &Pty,
    shadow: &Mutex<Shadow>,
    attached: &Mutex<Attached>,
    size: Option<Size>,
    hooks: &Hooks,
) {
    let Some(size) = size else {
        return;
    };
    let mut held = lock_or_recover(attached);
    let _ = pty.resize(size);
    lock_or_recover(shadow).resize(size);
    // A resize reflows the screen even when the program prints nothing after it.
    held.changed = true;
    hooks.screen_changed();
}

/// What a client attaching to a live session is shown: its screen, busy only while the program
/// that reported busy still owns the pty (`Shadow::replay_for`). `attach` and `replay_bytes` share
/// it, so the tests that read the one cover the other.
fn live_replay(pty: &Pty, shadow: &Mutex<Shadow>) -> Vec<u8> {
    lock_or_recover(shadow).replay_for(pty.foreground_pgid())
}

/// One step of the image transfers on this session, for the reader between reads: at ground, a
/// placement or a chunk per client. Every client has the shadow's bytes by now, because this
/// thread delivered them, so the shadow's parser and positions are theirs too. Comes back through
/// the wait while chunks remain, so the pty is always looked at first.
pub(super) fn send_images(
    pty: &Pty,
    shadow: &Mutex<Shadow>,
    attached: &Arc<Mutex<Attached>>,
    hooks: &Hooks,
) {
    let mut more = false;
    let sends = {
        let mut held = lock_or_recover(attached);
        if held.clients.iter().all(|client| client.transfer.is_none()) {
            return;
        }
        let mut shadow = lock_or_recover(shadow);
        // Output finishes the sequence, and brings the reader back here.
        if !shadow.at_ground() {
            return;
        }
        let mut sends = Vec::new();
        for client in &mut held.clients {
            let Some(transfer) = client.transfer.clone() else {
                continue;
            };
            if let Some(bytes) = transfer.next_bytes(&shadow) {
                sends.push((client.target(), bytes));
            }
            more |= transfer.has_more();
            if transfer.is_finished() {
                client.transfer = None;
            }
        }
        sends
    };
    for (target, bytes) in sends {
        let frame = Frame::new(FrameKind::Output, bytes);
        let size = deliver(attached, &target, &terminal_envelope(target.stream, frame));
        apply_size(pty, shadow, attached, size, hooks);
    }
    if more {
        pty.wake_reader();
    }
}

pub(super) fn terminal_envelope(stream: u32, frame: Frame) -> Vec<u8> {
    Envelope::new(Service::Terminal, stream, frame.encode()).encode()
}

/// The slowest a peer may take its repaint before the daemon gives up on it, in bytes per second.
///
/// Only a floor, not a target: a local socket moves a megabyte in microseconds and an ssh hop in a
/// fraction of a second. It exists so the repaint's budget scales with the screen instead of being
/// a flat wall-clock limit, which made a healthy-but-slow peer permanently unattachable.
const REPAINT_MIN_THROUGHPUT: usize = 64 * 1024;

/// How long a client gets to accept a repaint of `bytes` before the daemon gives up on it.
///
/// `WRITE_TIMEOUT` of slack plus the time the payload needs at `REPAINT_MIN_THROUGHPUT`. Pure and
/// named because the SCALING is the part that was wrong: a flat `WRITE_TIMEOUT` for the whole
/// repaint is a throughput floor, and a healthy peer slower than `replay.len()` per ten seconds
/// failed it deterministically — permanently, since every retry repeats it.
pub(super) fn repaint_budget(bytes: usize) -> Duration {
    WRITE_TIMEOUT + Duration::from_secs((bytes / REPAINT_MIN_THROUGHPUT) as u64)
}
