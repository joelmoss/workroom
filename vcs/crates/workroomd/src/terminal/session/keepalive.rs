//! Whether a remote client is still there (#593).
//!
//! A session counts as attached while any client is in `Attached::clients`. On a remote host a
//! client is a `workroomd attach` running under sshd, and when the Mac holding the pane sleeps or
//! loses its network that process does not end: it waits on a channel sshd still thinks is open,
//! for about 2 h on stock Linux, or for good with TCPKeepAlive off. Its session reads attached all
//! that time, and the detached-sessions list on every other Mac hides it (#584).
//!
//! Nothing on the host can tell that client from a quiet one: the relay is alive, and answers
//! anything sent to it. The hop that died is the Mac's, so the only proof of life is the Mac's own
//! terminal answering. The daemon sends the client a mode query no terminal knows (`PROBE`) every
//! `INTERVAL`; the pane's libghostty answers it as it answers any DECRQM, whether or not anyone
//! types, and the answer comes back as input. Any input at all counts. A client that has let
//! `MISSES` probes in a row go unanswered no longer counts as attached, and gives up the size; its
//! first input after that brings it back.
//!
//! **It is not evicted.** Output still goes to it, so a Mac that wakes on a link that survived
//! carries on exactly as before, with nothing missed. One whose link is dead loses it when a write
//! fails, as any client always has; the probes are what give that write something to fail on, so
//! a dead link also ends its relay in sshd's retransmission time (about 15 min) rather than in
//! TCPKeepAlive's.
//!
//! Only a client that asked is probed (`VARIABLE`, which the app sets on a remote pane's attach
//! and no older app sets), so an older app is never probed and never goes stale. An older daemon
//! ignores the variable, as it drops every `WORKROOM_SESSION_*` from the shell's environment.

use std::collections::HashMap;
use std::ffi::OsString;
use std::sync::{Arc, Mutex, Once};
use std::time::Duration;

use super::attached::{apply_size, deliver, terminal_envelope};
use super::{Attached, Hooks, Session, SessionId, SessionStore};
use crate::terminal::pty::Size;
use crate::terminal::shadow::Shadow;
use crate::util::lock_or_recover;
use wr_protocol::frame::{Frame, FrameKind};

/// The attach variable a client sets, to `1`, to be probed.
pub const VARIABLE: &str = "WORKROOM_SESSION_KEEPALIVE";

/// DECRQM for DEC private mode 25930, which no terminal has. Ghostty answers a mode it does not
/// know with `CSI ? 25930 ; 0 $ y` ("not recognized"), and so does every terminal that implements
/// DECRQM at all. Under 32768, because Ghostty packs a mode and its ANSI flag into 16 bits and a
/// higher number could alias a real one.
pub const PROBE: &[u8] = b"\x1b[?25930$p";

/// What every answer to `PROBE` starts with; a state of up to three digits and `$y` follow.
const ANSWER_HEAD: &[u8] = b"\x1b[?25930;";

/// How often a client that asked is probed.
pub(super) const INTERVAL: Duration = Duration::from_secs(15);

/// How many probes in a row may go unanswered before a client stops counting as attached: it does
/// so between `MISSES` and `MISSES + 1` intervals after it was last heard, 45 to 60 s.
pub(super) const MISSES: u32 = 3;

/// Whether an attach request's environment asks for keepalive.
pub fn requested(env: &[(OsString, OsString)]) -> bool {
    env.iter()
        .any(|(key, value)| key == VARIABLE && value == "1")
}

/// One probed client's keepalive.
///
/// Counted in ticks rather than measured in time. A host that is a VM on the sleeping Mac (a
/// container workroom) is paused with it, and on resume its clock can have jumped; the ticker
/// wakes once for all of that, so a pause costs at most one miss, never `MISSES`.
#[derive(Debug, Default)]
pub(super) struct Keepalive {
    /// A probe should go out at the reader's next chance (`send_probes`).
    due: bool,
    /// A probe went out and nothing has come back since.
    outstanding: bool,
    /// Ticks in a row that found a probe still outstanding.
    missed: u32,
    answers: AnswerFilter,
}

impl Keepalive {
    /// Whether this client has stopped answering, and so no longer counts as attached.
    pub(super) fn is_stale(&self) -> bool {
        self.missed >= MISSES
    }

    /// Input came from the client. Returns whether it had been stale, and so is back.
    pub(super) fn heard(&mut self) -> bool {
        let was = self.is_stale();
        self.outstanding = false;
        self.missed = 0;
        was
    }

    /// An interval passed. Returns whether it is this tick that made the client stale.
    fn tick(&mut self) -> bool {
        let was = self.is_stale();
        if self.outstanding {
            self.missed = self.missed.saturating_add(1);
        }
        self.due = true;
        !was && self.is_stale()
    }

    /// Whether a probe should go out now; it is then outstanding.
    fn take_due(&mut self) -> bool {
        if !self.due {
            return false;
        }
        self.due = false;
        self.outstanding = true;
        true
    }

    /// `bytes` from the client without the answers to `PROBE` in them.
    pub(super) fn strip(&mut self, bytes: &[u8]) -> Vec<u8> {
        self.answers.strip(bytes)
    }
}

/// Takes the answers to `PROBE` out of a client's input, so they never reach the program.
///
/// A terminal writes an answer whole, so it nearly always arrives in one frame. It can still be
/// split where the relay's read or ssh's packet ends, under a large paste; then the frame's tail is
/// held for the next one, but only once it is at least `ESC [ ?`, which no key sends. A bare
/// Escape or an Alt-[ at the end of a frame always goes straight through.
///
/// Accepted limit: a held tail whose rest never comes is dropped when the client goes. It is part
/// of a terminal's answer, not anything typed.
#[derive(Debug, Default)]
struct AnswerFilter {
    held: Vec<u8>,
}

/// Whether bytes at an `ESC` are an answer to `PROBE`.
#[derive(Debug, PartialEq, Eq)]
enum Answer {
    /// One, this many bytes long.
    Whole(usize),
    /// The start of one, ending where the bytes do.
    Partial,
    No,
}

/// The shortest tail held for the next frame: `ESC [ ?`.
const MIN_HELD: usize = 3;

/// The most digits a DECRPM state has.
const MAX_STATE_DIGITS: usize = 3;

impl AnswerFilter {
    fn strip(&mut self, bytes: &[u8]) -> Vec<u8> {
        let mut data = std::mem::take(&mut self.held);
        data.extend_from_slice(bytes);
        let mut out = Vec::with_capacity(data.len());
        let mut at = 0;
        while at < data.len() {
            if data[at] == 0x1B {
                match answer_at(&data[at..]) {
                    Answer::Whole(length) => {
                        at += length;
                        continue;
                    }
                    Answer::Partial if data.len() - at >= MIN_HELD => {
                        self.held = data[at..].to_vec();
                        return out;
                    }
                    _ => {}
                }
            }
            out.push(data[at]);
            at += 1;
        }
        out
    }
}

fn answer_at(bytes: &[u8]) -> Answer {
    let head = bytes.len().min(ANSWER_HEAD.len());
    if bytes[..head] != ANSWER_HEAD[..head] {
        return Answer::No;
    }
    if bytes.len() < ANSWER_HEAD.len() {
        return Answer::Partial;
    }
    let digits = bytes[ANSWER_HEAD.len()..]
        .iter()
        .take(MAX_STATE_DIGITS + 1)
        .take_while(|byte| byte.is_ascii_digit())
        .count();
    let after = ANSWER_HEAD.len() + digits;
    if digits > MAX_STATE_DIGITS {
        return Answer::No;
    }
    match (bytes.get(after), bytes.get(after + 1)) {
        (None, _) => Answer::Partial,
        _ if digits == 0 => Answer::No,
        (Some(b'$'), None) => Answer::Partial,
        (Some(b'$'), Some(b'y')) => Answer::Whole(after + 2),
        _ => Answer::No,
    }
}

/// The ticker's interval and whether it has started: one per store, started by the first client
/// that asks for keepalive (`SessionStore::start_keepalive`).
pub(super) struct Ticker {
    interval: Duration,
    started: Once,
}

impl Default for Ticker {
    fn default() -> Ticker {
        Ticker {
            interval: INTERVAL,
            started: Once::new(),
        }
    }
}

impl SessionStore {
    /// A store whose keepalive ticks every `interval` instead of every `INTERVAL`, so a test sees a
    /// client go stale in a fraction of a second.
    #[cfg(any(test, feature = "test-support"))]
    pub fn with_keepalive_interval(interval: Duration) -> SessionStore {
        SessionStore {
            keepalive: Arc::new(Ticker {
                interval,
                started: Once::new(),
            }),
            ..SessionStore::default()
        }
    }

    /// Starts this store's ticker, once. It holds the store only weakly, and ends with it.
    ///
    /// A thread the OS will not give leaves probed clients never probed, so never stale: the same
    /// as before keepalive existed.
    pub(super) fn start_keepalive(&self) {
        self.keepalive.started.call_once(|| {
            let sessions = Arc::downgrade(&self.sessions);
            let hooks = Arc::downgrade(&self.hooks);
            let interval = self.keepalive.interval;
            let spawned = std::thread::Builder::new()
                .name("keepalive".into())
                .spawn(move || {
                    loop {
                        std::thread::sleep(interval);
                        let (Some(sessions), Some(hooks)) = (sessions.upgrade(), hooks.upgrade())
                        else {
                            return;
                        };
                        tick(&sessions, &hooks);
                    }
                });
            if let Err(e) = spawned {
                crate::note!("keepalive is off: no thread for its ticker ({e})");
            }
        });
    }
}

/// One interval: counts each probed client's miss, gives up the size of one that has just gone
/// stale, and wakes each reader that has a probe to send.
///
/// The store map is released before any session's attachment lock is taken, as `changed_screens`
/// does, and each attachment lock is released before its size is applied.
fn tick(sessions: &Mutex<HashMap<SessionId, Session>>, hooks: &Hooks) {
    let parts: Vec<_> = lock_or_recover(sessions)
        .values()
        .map(|session| {
            (
                session.id,
                Arc::clone(&session.pty),
                Arc::clone(&session.shadow),
                Arc::clone(&session.attached),
            )
        })
        .collect();
    for (id, pty, shadow, attached) in parts {
        let (probing, size) = {
            let mut held = lock_or_recover(&attached);
            let mut probing = false;
            let mut gone_stale = Vec::new();
            for client in &mut held.clients {
                if let Some(keepalive) = client.keepalive.as_mut() {
                    probing = true;
                    if keepalive.tick() {
                        gone_stale.push(client.token);
                    }
                }
            }
            if !gone_stale.is_empty() {
                crate::note!(
                    "session {}: a client stopped answering; it no longer counts as attached",
                    id.to_hyphenated()
                );
            }
            (probing, held.release_from(&gone_stale))
        };
        apply_size(&pty, &shadow, &attached, size, hooks);
        if probing {
            pty.wake_reader();
        }
    }
}

impl Attached {
    /// The clients `stale` have stopped answering: one of them that owns the size gives it up, as
    /// a client that detaches does, and a sole client still answering takes it. Returns the size to
    /// apply.
    fn release_from(&mut self, stale: &[u64]) -> Option<Size> {
        if !self.owner.is_some_and(|owner| stale.contains(&owner)) {
            return None;
        }
        self.owner = None;
        let answering: Vec<u64> = self
            .clients
            .iter()
            .filter(|client| !client.is_stale())
            .map(|client| client.token)
            .collect();
        match answering.as_slice() {
            [only] => self.claim(*only),
            _ => None,
        }
    }

    /// After a client goes (`detach`, a failed delivery): a client left on its own takes the
    /// size, unless it has stopped answering, whose window is on a Mac nobody is at. The size then
    /// stays free, and the next client to attach fills it. Returns the size to apply.
    pub(super) fn claim_for_sole_survivor(&mut self) -> Option<Size> {
        match self.clients.as_slice() {
            [only] if !only.is_stale() => {
                let last = only.token;
                self.claim(last)
            }
            _ => None,
        }
    }
}

/// Sends the probes that are due, from the reader: only it sends output, so only between two of
/// its deliveries can a probe go out without landing inside one. Only at ground, so it never lands
/// inside a sequence the program left unfinished either, and never to a client with images on
/// their way, whose chunks must arrive together. A probe that cannot go yet stays due and is not
/// counted as missed.
pub(super) fn send_probes(
    pty: &crate::terminal::pty::Pty,
    shadow: &Mutex<Shadow>,
    attached: &Arc<Mutex<Attached>>,
    hooks: &Hooks,
) {
    let targets: Vec<_> = {
        let mut held = lock_or_recover(attached);
        let due = |client: &super::Client| {
            client.transfer.is_none() && client.keepalive.as_ref().is_some_and(|k| k.due)
        };
        if !held.clients.iter().any(due) {
            return;
        }
        if !lock_or_recover(shadow).at_ground() {
            return;
        }
        held.clients
            .iter_mut()
            .filter(|client| client.transfer.is_none())
            .filter_map(|client| {
                let keepalive = client.keepalive.as_mut()?;
                keepalive.take_due().then(|| client.target())
            })
            .collect()
    };
    for target in targets {
        let probe = terminal_envelope(target.stream, Frame::new(FrameKind::Output, PROBE.to_vec()));
        let size = deliver(attached, &target, &probe);
        apply_size(pty, shadow, attached, size, hooks);
    }
}

#[cfg(test)]
mod tests;
