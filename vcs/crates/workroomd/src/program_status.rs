//! Program status (OSC 7501, #358): what each session's program says it is doing, and the
//! `Service::ProgramStatus` that publishes it to the app.
//!
//! **Why the daemon keeps the records.** A daemon-backed pane's process is the `workroomd attach`
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
//!   shown (as of `revision`), its command result too; `{"ok":true}`, or `unknown_session`.
//! - `clear {session}` — drops every record (the app's "Clear status"); the same replies.
//!
//! A session also keeps one **command result** (#473): how its shell's last long command ended,
//! from OSC 133 rather than from the program. It is sent as one more record, with an `exitCode`
//! no program's record has, so an app that predates it shows a plain finished or failed mark.

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
    /// How long a shell command runs before its end is a command result (#473): long enough to
    /// switch away over, and longer than the quick commands and typos that would only be noise.
    pub const LONG_COMMAND: Duration = Duration::from_secs(10);
    /// How long a program that never probed (#481) must stay running and in the foreground after
    /// it blocks before it may alert: a `cat` of a recording has exited by then, or the shell's
    /// prompt has dropped the record.
    pub const GRACE: Duration = Duration::from_secs(1);
}

/// The exit status of a command stopped with ^C (128 + SIGINT): the user ended it, so it is
/// neither a pass nor a failure worth a mark.
const INTERRUPTED: i32 = 130;

/// The wire id of a command result. It has a space, which `printable` refuses in a report's id,
/// so no program's record can share it.
const COMMAND_ID: &str = "shell command";

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
    /// The daemon answered a support probe from the foreground group.
    Probed,
    /// The shell's OSC 133 D closed a command whose C the terminal saw, `ran` after it, with
    /// `line` the title the shell gave the command (empty when it gave none).
    Command {
        exit_code: i32,
        ran: Duration,
        line: String,
    },
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
    /// Whether the app may alert for it: its sender asked whether the daemon supports the
    /// protocol, or, never having asked, stayed a running program for `GRACE` after it blocked
    /// (`promote_unprobed`). A `cat` of a file full of 7501 does neither.
    notify: bool,
    /// When an unprobed request blocked, for `promote_unprobed`. Never carried: a hand-off's
    /// starts its grace again at the next tick.
    #[serde(skip)]
    blocked_at: Option<Instant>,
}

/// How the shell's last long command ended (#473), kept apart from the records so no program's
/// report, CLEAR or reset touches it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandResult {
    exit_code: i32,
    line: String,
    /// As `Record::updated`.
    updated: u64,
}

impl CommandResult {
    fn state(&self) -> State {
        if self.exit_code == 0 {
            State::Done
        } else {
            State::Error
        }
    }
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
    /// The group that was foreground when the daemon answered a probe in this run.
    probed: Option<Group>,
    /// The default reads a hand-off from a daemon that kept none.
    #[serde(default)]
    command: Option<CommandResult>,
    /// A run session's state, as its supervisor last wrote it (`crate::run`): `running <pid>`,
    /// `stopped`, `exited <code>` and so on. None for a shell.
    #[serde(default)]
    run: Option<String>,
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
            Event::Command {
                exit_code,
                ran,
                line,
            } => self.command_ended(exit_code, ran, &line, owner),
        }
    }

    /// A long command's end replaces the command result; a quick one or a ^C leaves it alone.
    pub fn command_ended(&mut self, exit_code: i32, ran: Duration, line: &str, owner: Group) {
        if exit_code == INTERRUPTED || ran < limits::LONG_COMMAND {
            return;
        }
        let line = self.sanitized(line, LOGGED_TITLE, owner);
        self.command = Some(CommandResult {
            exit_code,
            line,
            updated: self.revision + 1,
        });
        self.dirty = true;
    }

    /// One read's events, in order, except that a probe counts only after the reports read with
    /// it. A prober has to read the daemon's answer before it can report, so a probe and a report
    /// in one read were printed by something that never read it, which must not alert. A prompt
    /// or reset after the probe ends that run, and the probe with it. `now` is when the read
    /// arrived: it starts the grace of each new unprobed request (`promote_unprobed`, #481).
    ///
    /// shortcut: a replay whose probe and report land in different reads still alerts (a `cat` of
    /// a recorded Claude session: a macOS pty read is at most 1 KiB, and a screen paint separates
    /// them); the probe rule keeps no clock, and telling those apart needs one or the pty's input
    /// queue, if replays ever matter.
    pub fn apply_read(&mut self, events: Vec<Event>, owner: Group, now: Instant) {
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
        for record in self.unprobed_requests() {
            record.blocked_at.get_or_insert(now);
        }
    }

    /// Lets each unprobed request alert once `GRACE` has passed since it blocked and its sender
    /// is still `eligible`: alive, in the foreground, and not the shell itself (#481). One the
    /// tick meets without a start (handed off) starts its grace now.
    pub fn promote_unprobed(&mut self, now: Instant, eligible: impl Fn(Group) -> bool) {
        let revision = self.revision + 1;
        let mut promoted = false;
        for record in self.unprobed_requests() {
            let since = *record.blocked_at.get_or_insert(now);
            if now.duration_since(since) >= limits::GRACE
                && record.owner > 0
                && eligible(record.owner)
            {
                record.notify = true;
                record.updated = revision;
                promoted = true;
            }
        }
        self.dirty |= promoted;
    }

    /// Whether `promote_unprobed` has anything to look at, before the tick reads the pty.
    pub fn has_unprobed_request(&self) -> bool {
        self.records
            .iter()
            .any(|r| r.state == State::Blocked && !r.notify)
    }

    fn unprobed_requests(&mut self) -> impl Iterator<Item = &mut Record> {
        self.records
            .iter_mut()
            .filter(|r| r.state == State::Blocked && !r.notify)
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
        // The same request from the same sender, sent again: it keeps its grace and promotion.
        let again = previous
            .as_ref()
            .filter(|p| was_blocked && report.state == State::Blocked && p.owner == owner);
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
            notify: self.probed == Some(owner) || again.is_some_and(|p| p.notify),
            blocked_at: again.and_then(|p| p.blocked_at),
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

    /// Whether `drop_dead_owners` has anything to look at. A run that cleared its records on exit
    /// (Claude Code does) still holds `reporting` until a prompt, which a shell without OSC 133
    /// never sends.
    pub fn has_live(&self) -> bool {
        self.reporting.is_some()
            || self.probed.is_some()
            || self.records.iter().any(|r| r.state.is_live())
    }

    /// The app showed the session as of `revision`: its `done`/`error` records (those in `states`)
    /// from then or before go. One that changed after is newer than what was seen, and stays.
    pub fn seen(&mut self, revision: u64, states: &[State]) {
        self.retain(|r| {
            let seen = matches!(r.state, State::Done | State::Error) && states.contains(&r.state);
            !(seen && r.updated <= revision)
        });
        if self
            .command
            .as_ref()
            .is_some_and(|c| states.contains(&c.state()) && c.updated <= revision)
        {
            self.command = None;
            self.dirty = true;
        }
    }

    /// The app's "Clear status": every record, the command result, and `reporting`. Not
    /// `probed`: that names the program, which is still running and asked once, so its later
    /// requests still notify.
    pub fn clear_all(&mut self) {
        self.retain(|_| false);
        if self.command.take().is_some() {
            self.dirty = true;
        }
        if self.reporting.take().is_some() {
            self.dirty = true;
        }
    }

    /// A run session's state changed (#522).
    pub fn set_run(&mut self, run: String) {
        if self.run.as_ref() != Some(&run) {
            self.run = Some(run);
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
        let mut records: Vec<WireRecord> = self
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
                exit_code: None,
            })
            .collect();
        // Among the records by when it changed, so the app's latest finished or failed mark is
        // the latest whichever reported it. An older app shows it as a program's record.
        if let Some(command) = &self.command {
            let at = self
                .records
                .iter()
                .position(|r| r.updated > command.updated)
                .unwrap_or(records.len());
            records.insert(
                at,
                WireRecord {
                    id: COMMAND_ID,
                    state: command.state(),
                    kind: Kind::None,
                    progress: -1,
                    app: "",
                    title: "",
                    message: &command.line,
                    episode: 0,
                    notify: false,
                    exit_code: Some(command.exit_code),
                },
            );
        }
        serde_json::to_vec(&StatusEvent {
            event: "status",
            boot: boot.to_hyphenated(),
            session: session.to_hyphenated(),
            revision: self.revision,
            reporting: self.reporting.is_some(),
            records,
            run: self.run.as_deref(),
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
    /// Only on a run session (#522): what its supervisor last wrote. An app that predates it
    /// ignores it.
    #[serde(skip_serializing_if = "Option::is_none")]
    run: Option<&'a str>,
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
    /// Only on the command result (#473): what tells the app the shell reported it.
    #[serde(rename = "exitCode", skip_serializing_if = "Option::is_none")]
    exit_code: Option<i32>,
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

/// A fresh v4 uuid naming a session store, so the app can tell a daemon that kept its records
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
    /// Probe replies the pty could not take whole, for `workroomd program-status`.
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
        // `droppedReplies` is for `workroomd program-status`; the app ignores it.
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
    // Stream 0 belongs to the daemon's events, never to a request.
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
            "reason": "workroomd was built without terminal-state; build with --features terminal-state",
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
            "status-command" => {
                include_str!("../../../../testdata/program-status/status-command.json")
            }
            "status-run" => include_str!("../../../../testdata/program-status/status-run.json"),
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

        let mut store = Store::default();
        store.apply(command(1, limits::LONG_COMMAND), 10);
        store.commit();
        let event = store.event(uuid(BOOT), uuid(SESSION));
        assert_eq!(String::from_utf8(event).unwrap(), fixture("status-command"));

        let mut store = Store::default();
        store.set_run("exited 3".into());
        store.commit();
        let event = store.event(uuid(BOOT), uuid(SESSION));
        assert_eq!(String::from_utf8(event).unwrap(), fixture("status-run"));
    }

    /// Value: protects=a run's state is published only when it changes, so the watcher's re-reads
    /// cost no events; fails_when=set_run marks the store dirty for the same line; why_new=the
    /// watcher reads every run's file every tick; seam=none
    #[test]
    fn the_same_run_state_publishes_nothing() {
        let mut store = Store::default();
        store.set_run("running 7".into());
        assert!(store.commit().is_some());
        store.set_run("running 7".into());
        assert_eq!(store.commit(), None);
        store.set_run("stopped".into());
        assert!(store.commit().is_some());
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

    /// Only the group that was foreground when the daemon answered a probe is trusted to alert.
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

    /// A request from a program that never probed (Codex, #481) alerts once its sender has stayed
    /// a running program for `GRACE` after it blocked; a tick before then leaves it alone.
    /// Value: protects=Codex requests alert at all; fails_when=promotion is missing or ignores the grace; why_new=notify was probe-only; seam=none; no_claim=the tick thread and real pty groups (unit only)
    #[test]
    fn an_unprobed_request_alerts_once_its_sender_outlasts_the_grace() {
        let start = Instant::now();
        let mut store = Store::default();
        store.apply_read(vec![Event::Report(report("", State::Blocked))], 7, start);
        store.commit();
        store.promote_unprobed(start + limits::GRACE / 2, |_| true);
        assert!(!store.records[0].notify, "within the grace");
        assert_eq!(store.commit(), None);
        store.promote_unprobed(start + limits::GRACE, |_| false);
        assert!(
            !store.records[0].notify,
            "a sender gone or in the background"
        );
        store.promote_unprobed(start + limits::GRACE, |group| group == 7);
        assert!(store.records[0].notify);
        assert_eq!(store.commit(), Some(false), "published");
    }

    /// Codex re-sends its state after an external program returns: the same request from the
    /// same sender keeps its grace start and, once promoted, its promotion.
    /// Value: protects=one alert per request across re-reports; fails_when=report() recomputes notify from the probe alone or restarts the grace; why_new=no test re-reports an unprobed request; seam=none; no_claim=none beyond protects
    #[test]
    fn a_repeated_request_keeps_its_grace_and_its_promotion() {
        let start = Instant::now();
        let blocked = || vec![Event::Report(report("", State::Blocked))];
        let mut store = Store::default();
        store.apply_read(blocked(), 7, start);
        store.apply_read(blocked(), 7, start + limits::GRACE / 2);
        store.promote_unprobed(start + limits::GRACE, |_| true);
        assert!(
            store.records[0].notify,
            "the grace ran from the first report"
        );
        store.commit();
        store.apply_read(blocked(), 7, start + limits::GRACE * 2);
        assert!(store.records[0].notify, "still promoted");
        assert_eq!(store.commit(), None, "nothing changed");
        store.apply_read(blocked(), 8, start + limits::GRACE * 2);
        assert!(!store.records[0].notify, "another sender starts over");
    }

    /// A request restored without a grace start (a hand-off does not carry it) starts its grace at
    /// the first tick, and a sender the daemon could not identify (group 0) never alerts.
    /// Value: protects=a handed-off request alerts a grace later, never at once, and an unidentified sender never; fails_when=promote_unprobed treats a missing start as elapsed or drops the owner check; why_new=the other tests always set the start through apply_read; seam=none; no_claim=a real hand-off
    #[test]
    fn a_request_without_a_grace_start_waits_a_grace_from_the_tick() {
        let start = Instant::now();
        let mut store = Store::default();
        store.apply_read(vec![Event::Report(report("", State::Blocked))], 7, start);
        store.records[0].blocked_at = None;
        store.promote_unprobed(start + limits::GRACE * 5, |_| true);
        assert!(!store.records[0].notify, "the tick starts the grace");
        store.promote_unprobed(start + limits::GRACE * 6, |_| true);
        assert!(store.records[0].notify, "a grace after that tick");

        let mut store = Store::default();
        store.apply_read(vec![Event::Report(report("", State::Blocked))], 0, start);
        store.promote_unprobed(start + limits::GRACE * 5, |_| true);
        assert!(!store.records[0].notify, "an unidentified sender");
    }

    /// A probe and a report in one read (a `cat` of a recorded session) never alert; the same
    /// report in a later read does, and a prompt after the probe voids it.
    #[test]
    fn a_probe_counts_only_after_the_reports_read_with_it() {
        let blocked = || Event::Report(report("", State::Blocked));
        let mut store = Store::default();
        store.apply_read(vec![Event::Probed, blocked()], 7, Instant::now());
        assert!(!store.records[0].notify, "probe and report in one read");
        store.apply_read(vec![blocked()], 7, Instant::now());
        assert!(
            store.records[0].notify,
            "the probe counts from the next read"
        );

        let mut store = Store::default();
        store.apply_read(vec![Event::Probed, Event::Prompt], 7, Instant::now());
        assert_eq!(store.probed, None, "a prompt ends the run that probed");
        store.apply_read(vec![Event::Prompt, Event::Probed], 7, Instant::now());
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

    fn command(exit_code: i32, ran: Duration) -> Event {
        Event::Command {
            exit_code,
            ran,
            line: "npm test".into(),
        }
    }

    fn result(store: &Store) -> Option<(State, i32)> {
        store.command.as_ref().map(|c| (c.state(), c.exit_code))
    }

    /// Value: protects=which command ends earn a mark (#473): long ones, passed or failed, never ^C; fails_when=the threshold, the 130 exemption or the exit-0 split goes; why_new=these rules exist nowhere else; seam=none
    #[test]
    fn only_a_long_command_that_was_not_interrupted_leaves_a_result() {
        let long = limits::LONG_COMMAND;
        for (exit_code, ran, expected) in [
            (0, long, Some((State::Done, 0))),
            (2, long, Some((State::Error, 2))),
            (137, long * 6, Some((State::Error, 137))),
            (143, long, Some((State::Error, 143))),
            (130, long * 60, None),
            (0, long - Duration::from_millis(1), None),
            (1, Duration::ZERO, None),
        ] {
            let mut store = Store::default();
            store.apply(command(exit_code, ran), 1);
            assert_eq!(result(&store), expected, "exit {exit_code} after {ran:?}");
            assert_eq!(store.commit().is_some(), expected.is_some());
        }
    }

    /// Value: protects=one result per session that only a later long command replaces; fails_when=a quick command or a ^C clears or replaces it, or a long one does not; why_new=the replace rule is new; seam=none
    #[test]
    fn only_a_later_long_command_replaces_the_result() {
        let long = limits::LONG_COMMAND;
        let mut store = Store::default();
        store.apply(command(2, long), 1);
        store.commit();
        store.apply(command(0, Duration::from_secs(1)), 1);
        store.apply(command(130, long), 1);
        assert_eq!(store.commit(), None, "neither is a change");
        assert_eq!(result(&store), Some((State::Error, 2)));
        store.apply(command(0, long), 1);
        assert_eq!(
            store.commit(),
            Some(false),
            "never counts as entering blocked"
        );
        assert_eq!(result(&store), Some((State::Done, 0)));
    }

    /// Value: protects=the result follows the seen rules and nothing a program sends clears it; fails_when=seen ignores its state or revision, or a prompt, CLEAR, RIS or exit drops it; why_new=it is kept apart from the records those rules walk; seam=none
    #[test]
    fn a_result_goes_only_when_seen_or_cleared_by_the_user() {
        let mut store = Store::default();
        store.apply(command(1, limits::LONG_COMMAND), 1);
        store.commit();
        let shown = store.revision;
        for event in [Event::Prompt, Event::Clear(String::new()), Event::Reset] {
            store.apply(event, 1);
        }
        store.drop_on_exit();
        store.drop_dead_owners(|_| false);
        store.seen(shown - 1, &[State::Done, State::Error]);
        store.seen(shown, &[State::Done]);
        assert_eq!(result(&store), Some((State::Error, 1)));
        store.seen(shown, &[State::Error]);
        assert_eq!(result(&store), None);
        assert_eq!(store.commit(), Some(false));

        store.apply(command(0, limits::LONG_COMMAND), 1);
        store.clear_all();
        assert_eq!(result(&store), None, "Clear status takes it too");
    }

    /// Value: protects=the result sits among the records in the order they changed, with an exitCode no program record has; fails_when=it always goes first or last, or the field leaks onto a program's record; why_new=the app's latest mark and its shell wording read these; seam=none
    #[test]
    fn the_result_is_sent_among_the_records_in_change_order() {
        let mut store = Store::default();
        store.report(report("a", State::Done), 1);
        store.commit();
        store.apply(command(1, limits::LONG_COMMAND), 1);
        store.commit();
        store.report(report("b", State::Done), 1);
        store.commit();
        let event: Value = serde_json::from_slice(&store.event(uuid(BOOT), uuid(SESSION))).unwrap();
        let records = event["records"].as_array().unwrap();
        let shape: Vec<_> = records
            .iter()
            .map(|r| (r["id"].as_str().unwrap(), r.get("exitCode").cloned()))
            .collect();
        assert_eq!(
            shape,
            [("a", None), (COMMAND_ID, Some(json!(1))), ("b", None)]
        );
        assert_eq!(records[1]["state"], "error");
        assert_eq!(records[1]["message"], "npm test");
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

    /// Value: protects=only a group that is gone loses its working/blocked records; fails_when=the liveness drop is removed, or it drops on a foreground change; why_new=owner death is the only way a killed daemon's blocked clears without a prompt; seam=alive
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

    /// A run that cleared its records on exit (Claude Code sends CLEAR) still reports until its
    /// group is gone, so the liveness check keeps running for it: without OSC 133 no prompt ends
    /// it, and while it reports, the pane ignores the next command's OSC 9;4.
    #[test]
    fn a_cleared_run_is_still_checked_until_its_group_is_gone() {
        let mut store = Store::default();
        store.report(report("", State::Working), 5);
        store.clear("");
        assert!(
            store.has_live(),
            "the reporting run still needs its liveness check"
        );
        store.drop_dead_owners(|_| false);
        assert_eq!(store.reporting, None);
        assert!(!store.has_live());
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
        store.apply(command(1, limits::LONG_COMMAND), 4);
        store.commit();
        let back: Store = serde_json::from_slice(&serde_json::to_vec(&store).unwrap()).unwrap();
        assert_eq!(back, store);
        assert_eq!(
            result(&back),
            Some((State::Error, 1)),
            "a command result too"
        );
        assert_eq!((back.records[0].episode, back.records[0].notify), (1, true));
    }
}
