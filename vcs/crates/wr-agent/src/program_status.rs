//! Program status (OSC 7501, #358): what each session's program says it is doing, and the
//! `Service::ProgramStatus` that publishes it to the app.
//!
//! **Why the agent keeps the records.** A daemon-backed pane's process is the `wr-agent attach`
//! relay, which only copies output bytes into the pane, and GhosttyKit's apprt ignores 7501 anyway.
//! So the app's own terminal never sees a report. The shadow terminal does (`terminal.rs`): it
//! answers the program's support probe, and hands every report here. The terminal stores nothing;
//! [`Store`] applies the record rules terminal.h gives the embedder, and the service pushes each
//! session's records to every subscribed connection on stream 0, the way File's `watch` pushes
//! changes (`watch.rs`).
//!
//! The pure record rules are [`Store`]; the publisher is [`Hub`]; the requests are [`dispatch`].
//! The wire is pinned by `testdata/program-status/*.json`, which the app's decoder tests share.
//!
//! Methods, as JSON on one envelope per request, each answered `Reply::new(1, …)`:
//!
//! - `subscribe` — `{"available":true}`, then one `status` event per live session, then
//!   `snapshot-complete`, then live events. Without `terminal-state`, `{"available":false,…}`.
//! - `unsubscribe` — `{"ok":true}`.
//! - `seen {session, revision, states?}` — drops the session's `done`/`error` records the app has
//!   shown (as of `revision`); `{"ok":true}`, or `unknown_session`.
//! - `clear {session}` — drops every record (the app's "Clear status"); the same replies.

use std::collections::{HashMap, VecDeque};
use std::io::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::rpc::SharedWriter;
use crate::session::{SessionId, SessionStore};
use crate::transport::Closer;
use wr_protocol::envelope::{Envelope, MAX_ENVELOPE_PAYLOAD, Service};
use wr_protocol::reply::Reply;

/// The Rust half of the plan's constants; `ProgramStatusLimits` is the app's.
pub mod limits {
    use std::time::Duration;

    /// The least time between two status events to one subscriber, past the first after quiet:
    /// an agent streaming `working:msg=…` per token must not cost the app a decode per token.
    pub const PUBLISH_THROTTLE: Duration = Duration::from_millis(50);
    /// Records kept per session: the minimum terminal.h asks every embedder to allow.
    pub const MAX_RECORDS: usize = 64;
    /// The most bytes of a `title` or `message` kept: a tooltip line and a notification body, with
    /// room to spare, and 64 of them stay far under one envelope.
    pub const MAX_TEXT: usize = 512;
}

/// The wire version of this service, in every reply. Separate from `PROTOCOL_VERSION`, which says
/// whether the service exists at all.
pub const SERVICE_VERSION: u32 = 1;

/// A process group, as `tcgetpgrp` names it. 0 when the foreground could not be read, and never
/// probed for liveness.
pub type Group = libc::pid_t;

/// What a record says its program is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

impl State {
    /// Working and blocked describe a program that is running; they go when it does.
    fn is_live(self) -> bool {
        matches!(self, State::Working | State::Blocked)
    }
}

/// What a blocked program needs from the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    None,
    Permission,
    Question,
    Auth,
}

/// One report, as libghostty decoded it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub id: String,
    pub state: State,
    pub kind: Kind,
    pub progress: i8,
    pub app: String,
    pub title: String,
    pub message: String,
}

/// What the shadow terminal saw during one write, in order. Applied after the write, with the
/// pty's foreground group read once for all of them (`Shadow::write_from_pty`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Report(Report),
    /// A CLEAR report: this id and its subtree, or every record for an empty id.
    Clear(String),
    /// OSC 133 PROMPT_START: the shell is back.
    Prompt,
    /// RIS. libghostty sends a CLEAR with an empty id first.
    Reset,
    /// The agent answered a support probe from the foreground group.
    Probed,
}

/// One record, as the session keeps it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    id: String,
    state: State,
    kind: Kind,
    progress: i8,
    /// As reported; resolved from the nearest ancestor when serialised.
    app: String,
    title: String,
    message: String,
    /// The foreground group when the report arrived: the program that sent it.
    owner: Group,
    /// The revision that last changed it, which `seen` is gated on.
    updated: u64,
    /// Which time this record blocked, numbered across the session; 0 until it first blocks.
    episode: u64,
    /// Whether its sender is the program that asked whether the agent supports the protocol, so
    /// the app may alert for it. A `cat` of a file full of 7501 never probed.
    notify: bool,
}

/// What `Store` logs once per session.
const LOGGED_INVALID: u8 = 1;
const LOGGED_EVICTED: u8 = 2;
const LOGGED_TITLE: u8 = 4;
const LOGGED_MESSAGE: u8 = 8;

/// One session's records and the rules terminal.h gives for them. Pure: no FFI and no clock.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Store {
    /// Oldest update first, which is the eviction order.
    records: Vec<Record>,
    /// Bumped by each `commit` that publishes a change.
    revision: u64,
    /// The last episode handed out.
    episode: u64,
    /// The group of the program run that is reporting, until its prompt, reset or death.
    reporting: Option<Group>,
    /// The group that was foreground when the agent answered a probe in this run.
    probed: Option<Group>,
    /// Changed since the last `commit`. Never carried: a hand-off freezes between commits.
    #[serde(skip)]
    dirty: bool,
    /// A record entered blocked since the last `commit`.
    #[serde(skip)]
    blocked: bool,
    #[serde(skip)]
    logged: u8,
}

impl Store {
    /// One event from the terminal, sent while `owner` was in the foreground.
    pub fn apply(&mut self, event: Event, owner: Group) {
        match event {
            Event::Report(report) => self.report(report, owner),
            Event::Clear(id) => self.clear(&id),
            Event::Prompt => self.drop_on_prompt(),
            Event::Reset => self.reset(),
            Event::Probed => self.probed = Some(owner),
        }
    }

    /// One read's events, in order, except that a probe counts only after the reports read with
    /// it. A prober has to read the agent's answer before it can report, so a probe and a report
    /// in one read are bytes replayed by something else (a `cat` of a recorded session), which
    /// must not alert. A prompt or reset after the probe ends that run, and the probe with it.
    pub fn apply_read(&mut self, events: Vec<Event>, owner: Group) {
        let mut probed = false;
        for event in events {
            match event {
                Event::Probed => probed = true,
                Event::Prompt | Event::Reset => {
                    probed = false;
                    self.apply(event, owner);
                }
                event => self.apply(event, owner),
            }
        }
        if probed {
            self.probed = Some(owner);
        }
    }

    /// Replaces the report's record completely (terminal.h: a value it leaves out is gone).
    pub fn report(&mut self, report: Report, owner: Group) {
        if !printable(&report.id) || !printable(&report.app) {
            self.log_once(
                LOGGED_INVALID,
                "a report whose id or app is not printable ASCII was dropped",
                owner,
            );
            return;
        }
        let title = self.sanitized(&report.title, LOGGED_TITLE, owner);
        let message = self.sanitized(&report.message, LOGGED_MESSAGE, owner);
        if self.reporting.replace(owner).is_none() {
            self.dirty = true;
        }
        let previous = self
            .records
            .iter()
            .position(|r| r.id == report.id)
            .map(|index| self.records.remove(index));
        let was_blocked = previous.as_ref().map(|p| p.state) == Some(State::Blocked);
        let episode = if report.state == State::Blocked && !was_blocked {
            self.episode += 1;
            self.blocked = true;
            self.episode
        } else {
            previous.as_ref().map_or(0, |p| p.episode)
        };
        let mut record = Record {
            id: report.id,
            state: report.state,
            kind: report.kind,
            progress: report.progress,
            app: report.app,
            title,
            message,
            owner,
            updated: self.revision + 1,
            episode,
            notify: self.probed == Some(owner),
        };
        match &previous {
            // Progress alone is not worth an event: the app shows none of it.
            Some(p) if p.same_apart_from_progress(&record) => record.updated = p.updated,
            _ => self.dirty = true,
        }
        if previous.is_none() && self.records.len() >= limits::MAX_RECORDS {
            self.records.remove(0);
            self.log_once(
                LOGGED_EVICTED,
                "a record over the cap evicted the oldest",
                owner,
            );
        }
        self.records.push(record);
    }

    /// Removes `id` and every record beneath it (`a` takes `a/b`, not `ab`); an empty id removes
    /// every record.
    pub fn clear(&mut self, id: &str) {
        self.retain(|r| {
            !(id.is_empty()
                || r.id
                    .strip_prefix(id)
                    .is_some_and(|rest| rest.is_empty() || rest.starts_with('/')))
        });
    }

    /// RIS: the records are gone already (libghostty CLEARs first); so is the run that sent them.
    pub fn reset(&mut self) {
        self.end_run();
    }

    /// A new shell prompt: the program that reported has finished. `done` and `error` stay until
    /// the user has seen them.
    pub fn drop_on_prompt(&mut self) {
        self.retain(|r| !(r.state.is_live() || r.state == State::Idle));
        self.end_run();
    }

    /// The session's program exited.
    pub fn drop_on_exit(&mut self) {
        self.retain(|r| !r.state.is_live());
    }

    /// Drops working and blocked records whose sender's group no longer exists, and forgets the
    /// reporting and probing groups once theirs is gone. A group that only left the foreground
    /// (^Z, `sudo`, an editor) still exists, so nothing goes.
    pub fn drop_dead_owners(&mut self, alive: impl Fn(Group) -> bool) {
        self.retain(|r| !r.state.is_live() || alive(r.owner));
        if self.reporting.is_some_and(|group| !alive(group)) {
            self.reporting = None;
            self.dirty = true;
        }
        if self.probed.is_some_and(|group| !alive(group)) {
            self.probed = None;
        }
    }

    /// Whether `drop_dead_owners` has anything to look at.
    pub fn has_live(&self) -> bool {
        self.records.iter().any(|r| r.state.is_live())
    }

    /// The app showed the session as of `revision`: its `done`/`error` records (those in `states`)
    /// from then or before go. One that changed after is newer than what was seen, and stays.
    pub fn seen(&mut self, revision: u64, states: &[State]) {
        self.retain(|r| {
            let seen = matches!(r.state, State::Done | State::Error) && states.contains(&r.state);
            !(seen && r.updated <= revision)
        });
    }

    /// The app's "Clear status": every record, and `reporting`. Not `probed`: that names the
    /// program, which is still running and asked once, so its later requests still notify.
    pub fn clear_all(&mut self) {
        self.retain(|_| false);
        if self.reporting.take().is_some() {
            self.dirty = true;
        }
    }

    /// Takes the changes since the last commit as one revision. `Some(blocked)` when there is one
    /// to publish, `blocked` when a record entered blocked, which skips the throttle.
    pub fn commit(&mut self) -> Option<bool> {
        if !std::mem::take(&mut self.dirty) {
            return None;
        }
        self.revision += 1;
        Some(std::mem::take(&mut self.blocked))
    }

    /// The `status` event for this store.
    pub fn event(&self, boot: SessionId, session: SessionId) -> Vec<u8> {
        let records: Vec<WireRecord> = self
            .records
            .iter()
            .map(|r| WireRecord {
                id: &r.id,
                state: r.state,
                kind: r.kind,
                progress: r.progress,
                app: self.app_of(r),
                title: &r.title,
                message: &r.message,
                episode: r.episode,
                notify: r.notify,
            })
            .collect();
        serde_json::to_vec(&StatusEvent {
            event: "status",
            boot: boot.to_hyphenated(),
            session: session.to_hyphenated(),
            revision: self.revision,
            reporting: self.reporting.is_some(),
            records,
        })
        .expect("a status event serializes")
    }

    /// The record's own app, or its nearest ancestor's: `a/b` looks at `a`, then the root.
    fn app_of<'a>(&'a self, record: &'a Record) -> &'a str {
        let mut id = record.id.as_str();
        let mut app = record.app.as_str();
        while app.is_empty() && !id.is_empty() {
            id = id.rsplit_once('/').map_or("", |(parent, _)| parent);
            app = self
                .records
                .iter()
                .find(|r| r.id == id)
                .map_or("", |r| r.app.as_str());
        }
        app
    }

    fn end_run(&mut self) {
        if self.reporting.take().is_some() {
            self.dirty = true;
        }
        self.probed = None;
    }

    fn retain(&mut self, keep: impl FnMut(&Record) -> bool) {
        let before = self.records.len();
        self.records.retain(keep);
        if self.records.len() != before {
            self.dirty = true;
        }
    }

    /// `text` safe to show outside the terminal: invisible formatting characters dropped, controls
    /// and line breaks folded to spaces, at most `MAX_TEXT` bytes on a character boundary.
    fn sanitized(&mut self, text: &str, kind: u8, owner: Group) -> String {
        let mut out = String::with_capacity(text.len().min(limits::MAX_TEXT));
        for c in text.chars().filter(|c| !invisible(*c)) {
            let c = if c.is_control() || matches!(c, '\u{2028}' | '\u{2029}') {
                ' '
            } else {
                c
            };
            if out.len() + c.len_utf8() > limits::MAX_TEXT {
                self.log_once(kind, "a title or message over the cap was truncated", owner);
                break;
            }
            out.push(c);
        }
        out
    }

    fn log_once(&mut self, kind: u8, what: &str, owner: Group) {
        if self.logged & kind == 0 {
            self.logged |= kind;
            crate::note!("program status: {what} (process group {owner})");
        }
    }
}

impl Record {
    fn same_apart_from_progress(&self, other: &Record) -> bool {
        self.state == other.state
            && self.kind == other.kind
            && self.app == other.app
            && self.title == other.title
            && self.message == other.message
            && self.episode == other.episode
            && self.notify == other.notify
    }
}

/// An id or app is a key, not text: printable ASCII only (`/` included, for ids).
fn printable(text: &str) -> bool {
    text.bytes().all(|b| (0x21..=0x7E).contains(&b))
}

/// Unicode's `Cf` (format) characters as of 15.1, which include every direction override, plus the
/// whole tag block: text the user cannot see that can reorder or hide what they can.
fn invisible(c: char) -> bool {
    matches!(c as u32,
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2
        | 0x180E | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F
        | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F
        | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0000..=0xE007F)
}

/// Whether any process is left in `group`. A zombie counts until it is reaped (macOS answers EPERM
/// for one, Linux success), which the shell does at once; an unknown group always counts, and so
/// does 1, for which `kill(-1, …)` would mean every process.
pub fn group_alive(group: Group) -> bool {
    if group <= 1 {
        return true;
    }
    // SAFETY: `kill` takes no pointers, and signal 0 only checks that the group exists.
    let rc = unsafe { libc::kill(-group, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

#[derive(Serialize)]
struct StatusEvent<'a> {
    event: &'static str,
    boot: String,
    session: String,
    revision: u64,
    reporting: bool,
    records: Vec<WireRecord<'a>>,
}

#[derive(Serialize)]
struct WireRecord<'a> {
    id: &'a str,
    state: State,
    kind: Kind,
    progress: i8,
    app: &'a str,
    title: &'a str,
    message: &'a str,
    episode: u64,
    notify: bool,
}

#[derive(Serialize)]
struct EndedEvent {
    event: &'static str,
    boot: String,
    session: String,
}

#[derive(Serialize)]
struct SnapshotComplete {
    event: &'static str,
    boot: String,
    sessions: Vec<String>,
}

fn ended_event(boot: SessionId, session: SessionId) -> Vec<u8> {
    serde_json::to_vec(&EndedEvent {
        event: "ended",
        boot: boot.to_hyphenated(),
        session: session.to_hyphenated(),
    })
    .expect("an ended event serializes")
}

fn snapshot_complete(boot: SessionId, sessions: &[SessionId]) -> Vec<u8> {
    serde_json::to_vec(&SnapshotComplete {
        event: "snapshot-complete",
        boot: boot.to_hyphenated(),
        sessions: sessions.iter().map(|s| s.to_hyphenated()).collect(),
    })
    .expect("a snapshot-complete event serializes")
}

/// A fresh v4 uuid naming a session store, so the app can tell an agent that kept its records
/// (a hand-off) from one that started over.
fn new_boot() -> SessionId {
    let mut bytes = [0u8; 16];
    // Should the system's randomness fail, a zero boot still names one store; the app only
    // compares it with the last one it saw.
    let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    SessionId(bytes)
}

/// The publisher one session store shares between its readers and its subscribed connections.
/// Readers only mark a session dirty and wake each subscriber's sink, so a peer that stops reading
/// never stalls a pty.
pub struct Hub {
    boot: Mutex<SessionId>,
    subscribers: Mutex<Vec<Arc<Subscriber>>>,
    /// Probe replies the pty could not take whole, for `wr-agent program-status`.
    dropped_replies: AtomicU64,
}

impl Default for Hub {
    fn default() -> Self {
        Hub {
            boot: Mutex::new(new_boot()),
            subscribers: Mutex::new(Vec::new()),
            dropped_replies: AtomicU64::new(0),
        }
    }
}

impl Hub {
    pub fn boot(&self) -> SessionId {
        *self.boot.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The boot a hand-off carried, set before anything is served.
    pub fn set_boot(&self, boot: SessionId) {
        *self.boot.lock().unwrap_or_else(|e| e.into_inner()) = boot;
    }

    pub fn reply_dropped(&self) {
        self.dropped_replies.fetch_add(1, Ordering::Relaxed);
    }

    /// The session's latest status event, for every subscriber's sink to send when its throttle
    /// allows; `blocked` sends it at once.
    pub fn publish(&self, session: SessionId, event: Vec<u8>, blocked: bool) {
        for subscriber in self.subscribers() {
            let mut queue = subscriber.lock();
            let pending = queue
                .dirty
                .entry(session)
                .or_insert_with(|| (Vec::new(), false));
            pending.0.clone_from(&event);
            pending.1 |= blocked;
            drop(queue);
            subscriber.wake.notify_one();
        }
    }

    /// The session has ended: after its pending status, every subscriber is told.
    pub fn ended(&self, session: SessionId) {
        let event = ended_event(self.boot(), session);
        for subscriber in self.subscribers() {
            subscriber
                .lock()
                .ordered
                .push_back(Item::Ended(session, event.clone()));
            subscriber.wake.notify_one();
        }
    }

    /// A copy of the list, so no subscriber's lock is taken under the list's: `subscribe` holds a
    /// subscriber's lock while it registers.
    fn subscribers(&self) -> Vec<Arc<Subscriber>> {
        self.subscribers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    fn unregister(&self, subscriber: &Arc<Subscriber>) {
        self.subscribers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|s| !Arc::ptr_eq(s, subscriber));
    }
}

/// One subscribed connection's queue, drained by its sink thread.
#[derive(Default)]
struct Subscriber {
    queue: Mutex<Queue>,
    wake: Condvar,
}

impl Subscriber {
    fn lock(&self) -> std::sync::MutexGuard<'_, Queue> {
        self.queue.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn close(&self) {
        self.lock().closed = true;
        self.wake.notify_one();
    }
}

#[derive(Default)]
struct Queue {
    /// In order, ahead of any live status: the snapshot, its end, and each session's end.
    ordered: VecDeque<Item>,
    /// The latest unsent status event per session, and whether a record entered blocked in it.
    dirty: HashMap<SessionId, (Vec<u8>, bool)>,
    closed: bool,
}

enum Item {
    Status(SessionId, Vec<u8>),
    Ended(SessionId, Vec<u8>),
    Complete(Vec<u8>),
}

/// Throttle, not debounce: the first change after quiet goes at once, later ones at most every
/// `PUBLISH_THROTTLE`, and one entering blocked at once.
#[derive(Default)]
struct Throttle {
    last: Option<Instant>,
}

impl Throttle {
    /// How long a pending change waits before it may go.
    fn wait(&self, now: Instant, blocked: bool) -> Option<Duration> {
        if blocked {
            return None;
        }
        let due = self.last? + limits::PUBLISH_THROTTLE;
        (due > now).then(|| due - now)
    }
}

/// Writes events to one connection, remembering what each session was last sent.
struct Sink {
    writer: SharedWriter,
    closer: Closer,
    sent: HashMap<SessionId, Vec<u8>>,
}

impl Sink {
    /// One event, one final envelope on stream 0 (`[1] + json`, as every reply chunk is). A failed
    /// write closes the connection, so the app reconnects and resubscribes rather than showing
    /// records that never update (`watch.rs`).
    fn send(&self, event: &[u8]) -> bool {
        let mut payload = Vec::with_capacity(event.len() + 1);
        payload.push(1);
        payload.extend_from_slice(event);
        debug_assert!(payload.len() <= MAX_ENVELOPE_PAYLOAD);
        let written = self.writer.lock().is_ok_and(|mut writer| {
            writer
                .write_all(&Envelope::new(Service::ProgramStatus, 0, payload).encode())
                .and_then(|()| writer.flush())
                .is_ok()
        });
        if !written {
            (self.closer)();
        }
        written
    }

    /// A status event, unless it is byte-identical to the one this session was last sent.
    fn status(&mut self, session: SessionId, event: Vec<u8>) -> bool {
        if self.sent.get(&session) == Some(&event) {
            return true;
        }
        let written = self.send(&event);
        self.sent.insert(session, event);
        written
    }
}

/// The sink thread for one subscription. Ends when the connection drops it or a write fails.
fn run(subscriber: &Subscriber, mut sink: Sink) {
    let mut throttle = Throttle::default();
    let mut queue = subscriber.lock();
    loop {
        if queue.closed {
            return;
        }
        if let Some(item) = queue.ordered.pop_front() {
            let pending = match &item {
                Item::Ended(session, _) => queue.dirty.remove(session),
                _ => None,
            };
            drop(queue);
            let written = match item {
                Item::Status(session, event) => sink.status(session, event),
                Item::Complete(event) => sink.send(&event),
                Item::Ended(session, event) => {
                    let flushed = pending.is_none_or(|(status, _)| sink.status(session, status));
                    sink.sent.remove(&session);
                    flushed && sink.send(&event)
                }
            };
            if !written {
                crate::note!("program status: a subscriber stopped reading; closing it");
                return;
            }
            queue = subscriber.lock();
            continue;
        }
        if queue.dirty.is_empty() {
            queue = subscriber
                .wake
                .wait(queue)
                .unwrap_or_else(|e| e.into_inner());
            continue;
        }
        let blocked = queue.dirty.values().any(|(_, blocked)| *blocked);
        let now = Instant::now();
        if let Some(wait) = throttle.wait(now, blocked) {
            queue = subscriber
                .wake
                .wait_timeout(queue, wait)
                .map_or_else(|e| e.into_inner().0, |(queue, _)| queue);
            continue;
        }
        let batch = std::mem::take(&mut queue.dirty);
        drop(queue);
        throttle.last = Some(now);
        for (session, (event, _)) in batch {
            if !sink.status(session, event) {
                crate::note!("program status: a subscriber stopped reading; closing it");
                return;
            }
        }
        queue = subscriber.lock();
    }
}

/// One connection's side of the service, dropped with it: dropping ends its subscription.
pub struct Connection {
    hub: Arc<Hub>,
    writer: SharedWriter,
    closer: Closer,
    subscriber: Option<Arc<Subscriber>>,
}

impl Connection {
    pub fn new(hub: Arc<Hub>, writer: SharedWriter, closer: Closer) -> Self {
        Connection {
            hub,
            writer,
            closer,
            subscriber: None,
        }
    }

    /// Registers before reading the snapshot, under the new subscriber's own lock: a change that
    /// lands meanwhile waits for the lock, then queues behind `snapshot-complete`. The reply is
    /// written after the lock is released, since a reader publishing a change waits on it and a
    /// peer slow to drain must never stall a pty; only the sink writes events, and it starts after
    /// the reply, so nothing overtakes it.
    fn subscribe(&mut self, sessions: &SessionStore, reply: impl FnOnce(Value)) {
        self.unsubscribe();
        let subscriber = Arc::new(Subscriber::default());
        let mut queue = subscriber.lock();
        self.hub
            .subscribers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(Arc::clone(&subscriber));
        let boot = self.hub.boot();
        let snapshot = sessions.program_status_events();
        let ids: Vec<SessionId> = snapshot.iter().map(|(id, _)| *id).collect();
        for (id, event) in snapshot {
            queue.ordered.push_back(Item::Status(id, event));
        }
        queue
            .ordered
            .push_back(Item::Complete(snapshot_complete(boot, &ids)));
        drop(queue);
        // `droppedReplies` is for `wr-agent program-status`; the app ignores it.
        reply(json!({
            "available": true,
            "droppedReplies": self.hub.dropped_replies.load(Ordering::Relaxed),
        }));
        let sink = Sink {
            writer: Arc::clone(&self.writer),
            closer: Arc::clone(&self.closer),
            sent: HashMap::new(),
        };
        let running = Arc::clone(&subscriber);
        if std::thread::Builder::new()
            .spawn(move || run(&running, sink))
            .is_err()
        {
            self.hub.unregister(&subscriber);
            crate::note!("program status: no thread for a subscriber; closing it");
            (self.closer)();
            return;
        }
        crate::note!("program status: subscribed, {} sessions", ids.len());
        self.subscriber = Some(subscriber);
    }

    fn unsubscribe(&mut self) {
        if let Some(subscriber) = self.subscriber.take() {
            self.hub.unregister(&subscriber);
            subscriber.close();
            crate::note!(
                "program status: unsubscribed, {} subscribers left",
                self.hub.subscribers().len()
            );
        }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.unsubscribe();
    }
}

pub fn dispatch(envelope: &Envelope, sessions: &SessionStore, connection: &mut Connection) {
    // Stream 0 belongs to the agent's events, never to a request.
    if envelope.stream == 0 {
        return;
    }
    let writer = Arc::clone(&connection.writer);
    let stream = envelope.stream;
    let reply = |result: Result<Value, &str>| {
        crate::rpc::send(
            &writer,
            Service::ProgramStatus,
            stream,
            json!(Reply::new(SERVICE_VERSION, result)),
        );
    };
    let Ok(request) = serde_json::from_slice::<Value>(&envelope.payload) else {
        return reply(Err("unsupported"));
    };
    match request.get("method").and_then(Value::as_str) {
        Some("subscribe") if !cfg!(feature = "terminal-state") => reply(Ok(json!({
            "available": false,
            "reason": "wr-agent was built without terminal-state; build with --features terminal-state",
        }))),
        Some("subscribe") => connection.subscribe(sessions, |result| reply(Ok(result))),
        Some("unsubscribe") => {
            connection.unsubscribe();
            reply(Ok(json!({"ok": true})));
        }
        Some(method @ ("seen" | "clear")) => reply(update(method, &request, sessions)),
        _ => reply(Err("unsupported")),
    }
}

/// `seen` or `clear` against one session's store.
fn update(method: &str, request: &Value, sessions: &SessionStore) -> Result<Value, &'static str> {
    let session = request
        .get("session")
        .and_then(Value::as_str)
        .and_then(|text| crate::serve::parse_session_id(std::ffi::OsStr::new(text)))
        .ok_or("unsupported")?;
    // `None` for `clear`; for `seen`, the revision shown and the states it covers.
    let seen = if method == "clear" {
        None
    } else {
        let revision = request
            .get("revision")
            .and_then(Value::as_u64)
            .ok_or("unsupported")?;
        let states = match request.get("states") {
            None => vec![State::Done, State::Error],
            Some(states) => {
                serde_json::from_value::<Vec<State>>(states.clone()).map_err(|_| "unsupported")?
            }
        };
        Some((revision, states))
    };
    let known = sessions.update_program_status(session, |store| match &seen {
        None => store.clear_all(),
        Some((revision, states)) => store.seen(*revision, states),
    });
    if known {
        Ok(json!({"ok": true}))
    } else {
        Err("unknown_session")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(id: &str, state: State) -> Report {
        Report {
            id: id.into(),
            state,
            kind: Kind::None,
            progress: -1,
            app: String::new(),
            title: String::new(),
            message: String::new(),
        }
    }

    fn ids(store: &Store) -> Vec<&str> {
        store.records.iter().map(|r| r.id.as_str()).collect()
    }

    fn fixture(name: &str) -> &'static str {
        match name {
            "status" => include_str!("../../../../testdata/program-status/status.json"),
            "ended" => include_str!("../../../../testdata/program-status/ended.json"),
            _ => include_str!("../../../../testdata/program-status/snapshot-complete.json"),
        }
        .trim_end()
    }

    fn uuid(text: &str) -> SessionId {
        crate::serve::parse_session_id(std::ffi::OsStr::new(text)).unwrap()
    }

    const BOOT: &str = "6f1c2e0a-3b4d-4e5f-8a9b-0c1d2e3f4a5b";
    const SESSION: &str = "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a";

    /// The three events, byte for byte as the app's decoder tests read them.
    /// Value: protects=the wire shape and field order the Swift decoder is pinned to; fails_when=a field is renamed, reordered or retyped; why_new=the fixtures are the cross-language contract; seam=none
    #[test]
    fn events_match_the_shared_fixtures() {
        let mut store = Store::default();
        store.apply(Event::Probed, 10);
        store.revision = 6;
        store.report(
            Report {
                kind: Kind::Permission,
                app: "claude-code".into(),
                message: "Apply?".into(),
                ..report("", State::Blocked)
            },
            10,
        );
        assert_eq!(store.commit(), Some(true));
        let event = store.event(uuid(BOOT), uuid(SESSION));
        assert_eq!(String::from_utf8(event).unwrap(), fixture("status"));
        assert_eq!(
            String::from_utf8(ended_event(uuid(BOOT), uuid(SESSION))).unwrap(),
            fixture("ended")
        );
        assert_eq!(
            String::from_utf8(snapshot_complete(uuid(BOOT), &[uuid(SESSION)])).unwrap(),
            fixture("snapshot-complete")
        );
    }

    /// A report replaces its record whole, and moves it to the newest end.
    #[test]
    fn a_report_replaces_its_record_completely() {
        let mut store = Store::default();
        store.report(
            Report {
                message: "first".into(),
                ..report("a", State::Working)
            },
            1,
        );
        store.report(report("b", State::Working), 1);
        store.report(report("a", State::Done), 1);
        assert_eq!(ids(&store), ["b", "a"]);
        assert_eq!(store.records[1].message, "", "a value left out is gone");
        assert_eq!(store.records[1].state, State::Done);
        assert_eq!(store.reporting, Some(1));
    }

    /// Value: protects=CLEAR removes the id and its subtree only, and an empty id removes all; fails_when=the subtree test is a bare prefix (`a` takes `ab`) or misses `a/b`; why_new=terminal.h's subtree rule has no other check; seam=none
    #[test]
    fn clear_removes_the_subtree_and_nothing_beside_it() {
        let mut store = Store::default();
        for id in ["a", "a/b", "a/b/c", "ab", "b"] {
            store.report(report(id, State::Working), 1);
        }
        store.clear("a");
        assert_eq!(ids(&store), ["ab", "b"]);
        store.clear("");
        assert!(store.records.is_empty());
    }

    #[test]
    fn episodes_number_each_entry_into_blocked() {
        let mut store = Store::default();
        store.report(report("", State::Working), 1);
        assert_eq!(store.records[0].episode, 0, "0 until it first blocks");
        store.report(report("", State::Blocked), 1);
        assert_eq!(store.records[0].episode, 1);
        store.report(
            Report {
                message: "still".into(),
                ..report("", State::Blocked)
            },
            1,
        );
        assert_eq!(store.records[0].episode, 1, "staying blocked keeps it");
        store.report(report("", State::Working), 1);
        store.report(report("", State::Blocked), 1);
        assert_eq!(
            store.records[0].episode, 2,
            "a second permission in one turn"
        );
        // Across a CLEAR and a prompt the counter keeps going, so an old episode never repeats.
        store.clear("");
        store.report(report("", State::Blocked), 1);
        assert_eq!(store.records[0].episode, 3);
        store.drop_on_prompt();
        store.report(report("x", State::Blocked), 1);
        assert_eq!(store.records[0].episode, 4);
    }

    /// Only the group that was foreground when the agent answered a probe is trusted to alert.
    #[test]
    fn notify_follows_the_probing_group() {
        let mut store = Store::default();
        store.report(report("", State::Blocked), 7);
        assert!(!store.records[0].notify, "nothing probed");
        store.apply(Event::Probed, 7);
        store.report(report("other", State::Blocked), 8);
        assert!(!store.records[1].notify, "another group probed");
        store.report(report("", State::Blocked), 7);
        assert!(store.records[1].notify);
        store.reset();
        assert_eq!((store.reporting, store.probed), (None, None));
    }

    /// A probe and a report in one read (a `cat` of a recorded session) never alert; the same
    /// report in a later read does, and a prompt after the probe voids it.
    #[test]
    fn a_probe_counts_only_after_the_reports_read_with_it() {
        let blocked = || Event::Report(report("", State::Blocked));
        let mut store = Store::default();
        store.apply_read(vec![Event::Probed, blocked()], 7);
        assert!(!store.records[0].notify, "probe and report in one read");
        store.apply_read(vec![blocked()], 7);
        assert!(
            store.records[0].notify,
            "the probe counts from the next read"
        );

        let mut store = Store::default();
        store.apply_read(vec![Event::Probed, Event::Prompt], 7);
        assert_eq!(store.probed, None, "a prompt ends the run that probed");
        store.apply_read(vec![Event::Prompt, Event::Probed], 7);
        assert_eq!(store.probed, Some(7));
    }

    #[test]
    fn a_prompt_keeps_only_what_the_user_has_not_seen() {
        let mut store = Store::default();
        for (id, state) in [
            ("i", State::Idle),
            ("w", State::Working),
            ("b", State::Blocked),
            ("d", State::Done),
            ("e", State::Error),
        ] {
            store.report(report(id, state), 1);
        }
        let mut exited = store.clone();
        store.drop_on_prompt();
        assert_eq!(ids(&store), ["d", "e"]);
        assert_eq!(store.reporting, None);
        exited.drop_on_exit();
        assert_eq!(ids(&exited), ["i", "d", "e"]);
    }

    #[test]
    fn only_a_real_change_is_a_revision() {
        let mut store = Store::default();
        assert_eq!(store.commit(), None);
        store.report(report("", State::Working), 1);
        assert_eq!(store.commit(), Some(false));
        assert_eq!(store.revision, 1);
        store.report(
            Report {
                progress: 40,
                ..report("", State::Working)
            },
            1,
        );
        assert_eq!(store.commit(), None, "progress alone");
        assert_eq!(store.records[0].progress, 40, "but it is kept");
        store.report(report("", State::Working), 1);
        assert_eq!(store.commit(), None, "the same report again");
        store.clear("missing");
        assert_eq!(store.commit(), None);
        store.report(report("", State::Blocked), 1);
        assert_eq!(store.commit(), Some(true));
        assert_eq!(store.revision, 2);
    }

    /// Value: protects=seen removes only what the app saw, as of the revision it names; fails_when=the `updated <= revision` gate is dropped, so a done that arrived after the focus goes unseen; why_new=the gate is what makes a focus racing a new report safe; seam=none
    #[test]
    fn seen_is_gated_on_the_revision_the_app_showed() {
        let mut store = Store::default();
        store.report(report("old", State::Done), 1);
        store.report(report("err", State::Error), 1);
        store.commit();
        let shown = store.revision;
        store.report(report("new", State::Done), 1);
        store.commit();
        let mut done_only = store.clone();
        store.seen(shown, &[State::Done, State::Error]);
        assert_eq!(ids(&store), ["new"]);
        assert_eq!(store.commit(), Some(false));
        done_only.seen(done_only.revision, &[State::Done]);
        assert_eq!(ids(&done_only), ["err"]);
    }

    #[test]
    fn clear_all_ends_reporting_but_keeps_the_probe() {
        let mut store = Store::default();
        store.apply(Event::Probed, 3);
        store.report(report("", State::Error), 3);
        store.clear_all();
        assert!(store.records.is_empty());
        assert_eq!((store.reporting, store.probed), (None, Some(3)));
        // The same run's next request still notifies: it asked once, and is still running.
        store.report(report("", State::Blocked), 3);
        assert!(store.records[0].notify);
    }

    #[test]
    fn the_oldest_record_goes_past_the_cap() {
        let mut store = Store::default();
        for n in 0..limits::MAX_RECORDS {
            store.report(report(&format!("r{n}"), State::Working), 1);
        }
        store.report(report("r0", State::Done), 1);
        assert_eq!(
            store.records.len(),
            limits::MAX_RECORDS,
            "an update adds none"
        );
        store.report(report("new", State::Working), 1);
        assert_eq!(store.records.len(), limits::MAX_RECORDS);
        assert_eq!(store.records[0].id, "r2", "r1 was updated longest ago");
        assert_eq!(store.records.last().unwrap().id, "new");
    }

    #[test]
    fn keys_must_be_printable_ascii() {
        let mut store = Store::default();
        for (id, app) in [("a b", ""), ("é", ""), ("ok", "x\u{7}"), ("ok", "a b")] {
            store.report(
                Report {
                    app: app.into(),
                    ..report(id, State::Working)
                },
                1,
            );
        }
        assert!(store.records.is_empty());
        store.report(
            Report {
                app: "cargo".into(),
                ..report("build/test", State::Working)
            },
            1,
        );
        assert_eq!(ids(&store), ["build/test"]);
    }

    #[test]
    fn text_is_made_safe_to_show_outside_the_terminal() {
        let mut store = Store::default();
        let hostile = "a\u{202E}b\u{200B}c\u{E0041}d\u{00AD}e\u{061C}f\u{180E}g\u{FFF9}h\u{FEFF}i\
                       \nj\rk\u{7f}l\u{85}m\u{2028}n";
        assert_eq!(
            store.sanitized(hostile, LOGGED_TITLE, 1),
            "abcdefghi j k l m n"
        );
        // Cut on a character boundary, never inside one.
        let long = "é".repeat(limits::MAX_TEXT);
        let cut = store.sanitized(&long, LOGGED_MESSAGE, 1);
        assert_eq!(cut.len(), limits::MAX_TEXT);
        assert!(cut.chars().all(|c| c == 'é'));
        let odd = format!("x{long}");
        assert_eq!(
            store.sanitized(&odd, LOGGED_MESSAGE, 1).len(),
            limits::MAX_TEXT - 1
        );
    }

    #[test]
    fn a_record_without_an_app_takes_its_nearest_ancestors() {
        let mut store = Store::default();
        let with_app = |id: &str, app: &str| Report {
            app: app.into(),
            ..report(id, State::Working)
        };
        store.report(with_app("", "deploy"), 1);
        store.report(with_app("us-east", ""), 1);
        store.report(with_app("eu", "terraform"), 1);
        store.report(with_app("eu/a/b", ""), 1);
        let event: Value =
            serde_json::from_slice(&store.event(SessionId([0; 16]), SessionId([1; 16]))).unwrap();
        let apps: Vec<&str> = event["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["app"].as_str().unwrap())
            .collect();
        assert_eq!(apps, ["deploy", "deploy", "terraform", "terraform"]);
    }

    /// Value: protects=only a group that is gone loses its working/blocked records; fails_when=the liveness drop is removed, or it drops on a foreground change; why_new=owner death is the only way a killed agent's blocked clears without a prompt; seam=alive
    #[test]
    fn a_dead_owner_loses_its_live_records_and_a_stopped_one_does_not() {
        let mut store = Store::default();
        store.apply(Event::Probed, 5);
        store.report(report("w", State::Working), 5);
        store.report(report("b", State::Blocked), 5);
        store.report(report("d", State::Done), 5);
        store.report(report("other", State::Blocked), 6);
        store.commit();
        store.drop_dead_owners(|_| true);
        assert_eq!(store.commit(), None, "nothing is gone");
        store.drop_dead_owners(|group| group != 5);
        assert_eq!(ids(&store), ["d", "other"]);
        assert_eq!(store.probed, None);
        assert_eq!(store.reporting, Some(6));
        assert!(store.commit().is_some());
    }

    /// The liveness probe against real processes: a stopped group (^Z) and a zombie both still
    /// exist; a reaped one does not; a group whose leader left lives on in its children (a wrapper
    /// that forked the real program).
    #[test]
    fn the_liveness_probe_matches_real_process_groups() {
        use std::os::unix::process::CommandExt;
        let spawn = |script: &str| {
            std::process::Command::new("/bin/sh")
                .args(["-c", script])
                .process_group(0)
                .spawn()
                .unwrap()
        };
        let mut sleeper = spawn("exec sleep 30");
        let group = sleeper.id() as Group;
        assert!(group_alive(group));
        // SAFETY: `kill` takes no pointers; the group is this test's own child's.
        unsafe { libc::kill(-group, libc::SIGSTOP) };
        assert!(group_alive(group), "a stopped job is still there");
        sleeper.kill().unwrap();
        std::thread::sleep(Duration::from_millis(100));
        assert!(group_alive(group), "a zombie counts until it is reaped");
        sleeper.wait().unwrap();
        assert!(!group_alive(group), "a reaped group is gone");

        let mut wrapper = spawn("sleep 30 & exit 0");
        let group = wrapper.id() as Group;
        wrapper.wait().unwrap();
        assert!(group_alive(group), "the wrapper's child keeps the group");
        // SAFETY: as above.
        unsafe { libc::kill(-group, libc::SIGKILL) };
        assert!(group_alive(0), "an unknown group always counts");
    }

    #[test]
    fn the_throttle_lets_the_first_change_and_blocked_through_at_once() {
        let mut throttle = Throttle::default();
        let t0 = Instant::now();
        assert_eq!(throttle.wait(t0, false), None, "first after quiet");
        throttle.last = Some(t0);
        let soon = t0 + Duration::from_millis(10);
        assert_eq!(throttle.wait(soon, false), Some(Duration::from_millis(40)));
        assert_eq!(throttle.wait(soon, true), None, "blocked skips it");
        assert_eq!(throttle.wait(t0 + limits::PUBLISH_THROTTLE, false), None);
    }

    /// The hand-off carries every field but the per-write ones.
    #[test]
    fn a_store_survives_serialization() {
        let mut store = Store::default();
        store.apply(Event::Probed, 4);
        store.report(report("", State::Blocked), 4);
        store.commit();
        let back: Store = serde_json::from_slice(&serde_json::to_vec(&store).unwrap()).unwrap();
        assert_eq!(back, store);
        assert_eq!((back.records[0].episode, back.records[0].notify), (1, true));
    }
}
