//! The terminal API's events (#687): what happens to the daemon's sessions, numbered, for
//! `events.subscribe` (`api::events`) to stream.
//!
//! **One numbering per boot.** Every event takes the next `revision` of its [`Hub`], daemon-wide,
//! and names the hub's `boot`. A hand-off carries both, with the last events and what they told
//! ([`Hub::carry`]), so a client that saw `(boot, revision)` can ask the next program for what came
//! after, exactly, and a daemon that started afresh has another boot. Not program status's
//! numbering, which is per session (a session's records change one revision at a time): a
//! client's place in a stream of several sessions' events, and later of events that are no
//! session's state (a client attaching, typing), is one number.
//!
//! **A ring, not a queue per subscriber.** The last [`RING`] events are kept, oldest first, and a
//! subscriber holds only the revision it has sent up to: a publish appends under the hub's lock
//! and wakes the subscribers, and never waits on any of them, so a subscriber that stops reading
//! never slows a session's output. One that falls past the ring's start (lagged), or asks to
//! resume from a place the ring no longer holds, or another boot's, is told so and sent the state
//! as it is now ([`Hub::view`]), which is what the events add up to: the sessions, and each one's
//! coding agent and run state. Nothing is lost silently.
//!
//! **What the events add up to is kept beside them** (`Known` per session), changed by each event
//! under the same lock, so a snapshot taken at revision R is exactly R's, and a subscriber that
//! starts from it hears every event after R and none before.

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::terminal::session::SessionId;
use crate::terminal::wait::RunState;
use crate::util::{lock_or_recover, recover};

/// The most events the ring keeps: what a client can resume across, and how far a subscriber may
/// fall behind before it is sent the state afresh. An implementation limit, not contract.
pub const RING: usize = 1024;

/// The event names, as `event` gives them.
pub mod name {
    /// One session as it is, in a snapshot.
    pub const SESSION: &str = "session";
    /// A snapshot's end.
    pub const SNAPSHOT_COMPLETE: &str = "snapshot-complete";
    /// A subscription that resumed where its `since` left off.
    pub const RESUMED: &str = "resumed";
    pub const CREATED: &str = "session.created";
    pub const ENDED: &str = "session.ended";
    pub const PROGRAM_STATUS: &str = "session.program_status";
    pub const RUN_STATE: &str = "session.run_state";
    /// The live events, which `types` filters.
    pub const LIVE: [&str; 4] = [CREATED, ENDED, PROGRAM_STATUS, RUN_STATE];
}

/// What one live session's events have told, as of the hub's revision.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Known {
    /// The session as `session.list` lists it when it was created: its label, scope, run and cwd.
    pub listing: Value,
    /// Its coding agent as the last `session.program_status` gave it (the listing's shape).
    pub coding_agent: Value,
    /// Its run's state and exit code, as the last `session.run_state` gave them.
    pub run_state: Option<String>,
    pub exit_code: Option<i32>,
    /// The number of the last run transition heard from the run's log, so none is told twice;
    /// `None` until one is, and for a run whose supervisor writes no log.
    pub run_seq: Option<u64>,
}

/// One event: its revision and the JSON a subscriber is sent.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub revision: u64,
    pub json: Value,
}

/// What a subscriber starts from (`Hub::start`).
#[derive(Debug, Clone, PartialEq)]
pub enum Start {
    /// The state now: a snapshot.
    Fresh,
    /// What came after `revision` of `boot`, if the ring still holds it.
    Since { boot: String, revision: u64 },
}

/// Why a snapshot was sent, as `snapshot-complete`'s `reason` says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    /// A subscription that asked for no place to resume from.
    Subscribed,
    /// The subscriber fell further behind than the ring holds: events it was never sent were
    /// dropped, and the state now replaces what it knew.
    Lagged,
    /// It asked to resume from a place this daemon can't serve: another boot's (the daemon
    /// started afresh), or one older than the ring holds.
    Gap,
}

impl Reason {
    pub fn name(self) -> &'static str {
        match self {
            Reason::Subscribed => "subscribed",
            Reason::Lagged => "lagged",
            Reason::Gap => "gap",
        }
    }
}

/// What a subscriber is to send next (`Hub::next`).
#[derive(Debug, PartialEq)]
pub enum Next {
    /// The state as of `revision`: each session's, then `snapshot-complete`.
    Snapshot {
        boot: String,
        revision: u64,
        sessions: BTreeMap<SessionId, Known>,
        reason: Reason,
    },
    /// Resumed after `revision`, as asked.
    Resumed { boot: String, revision: u64 },
    /// The events after the subscriber's place, oldest first.
    Events(Vec<Arc<Event>>),
    /// The subscription has ended.
    Closed,
}

/// A subscriber's place: the revision it has been sent up to, or what it starts from.
#[derive(Debug)]
pub struct Cursor {
    start: Option<Start>,
    sent: u64,
}

impl Cursor {
    pub fn new(start: Start) -> Cursor {
        Cursor {
            start: Some(start),
            sent: 0,
        }
    }
}

struct State {
    boot: SessionId,
    /// The last revision taken; 0 before any event.
    revision: u64,
    ring: VecDeque<Arc<Event>>,
    sessions: BTreeMap<SessionId, Known>,
    /// The revision the ring was carried at, while a hand-off is under way: nothing past it is
    /// sent, so no subscriber ever hears a revision the next program will number again.
    sealed: Option<u64>,
    /// Whether this numbering came from the program a hand-off replaced (`Hub::adopt`).
    carried: bool,
}

/// [`State`] as a hand-off carries it: ids hyphenated, each event its JSON, which holds its
/// revision.
#[derive(Serialize, Deserialize)]
struct Carried {
    boot: String,
    revision: u64,
    ring: Vec<Value>,
    sessions: Vec<(String, Known)>,
}

impl Carried {
    fn of(state: &State) -> Carried {
        Carried {
            boot: state.boot.to_hyphenated(),
            revision: state.revision,
            ring: state.ring.iter().map(|event| event.json.clone()).collect(),
            sessions: state
                .sessions
                .iter()
                .map(|(id, known)| (id.to_hyphenated(), known.clone()))
                .collect(),
        }
    }

    fn state(self) -> Option<State> {
        let parse = |id: &str| wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(id));
        let ring: VecDeque<Arc<Event>> = self
            .ring
            .into_iter()
            .map(|json| {
                let revision = json["revision"].as_u64()?;
                Some(Arc::new(Event { revision, json }))
            })
            .collect::<Option<_>>()?;
        let sessions = self
            .sessions
            .into_iter()
            .map(|(id, known)| Some((parse(&id)?, known)))
            .collect::<Option<_>>()?;
        Some(State {
            boot: parse(&self.boot)?,
            revision: self.revision,
            ring,
            sessions,
            sealed: None,
            carried: true,
        })
    }
}

impl State {
    /// The revision the ring's first event has, or the next one's when it is empty: a subscriber
    /// that has been sent up to one before it has missed nothing the ring dropped.
    fn first(&self) -> u64 {
        self.ring
            .front()
            .map_or(self.revision + 1, |event| event.revision)
    }

    /// The last revision a subscriber may be sent.
    fn deliverable(&self) -> u64 {
        self.sealed.unwrap_or(self.revision)
    }
}

/// The publisher one session store shares between the points in a session's life that make
/// events (`session::Hooks`) and the terminal API's subscribers.
pub struct Hub {
    state: Mutex<State>,
    /// Woken on every event, on unsealing, and when a subscription closes.
    wake: Condvar,
}

impl Default for Hub {
    fn default() -> Hub {
        Hub {
            state: Mutex::new(State {
                boot: crate::terminal::program_status::new_boot(),
                revision: 0,
                ring: VecDeque::new(),
                sessions: BTreeMap::new(),
                sealed: None,
                carried: false,
            }),
            wake: Condvar::new(),
        }
    }
}

/// The event `json` with the hub's `boot` and its `revision` added.
fn stamped(boot: SessionId, revision: u64, mut json: Value) -> Value {
    json["boot"] = json!(boot.to_hyphenated());
    json["revision"] = json!(revision);
    json
}

/// Whether `new` is news after `old`, both a coding agent in the listing's shape: its state, its
/// program or whether it waits on the user changed, or its message did while it isn't working.
/// A working agent may report a message per token; that is not an event each time, and the
/// snapshot and `session.list` have the latest.
fn agent_changed(old: &Value, new: &Value) -> bool {
    if old.is_null() || new.is_null() {
        return old != new;
    }
    ["state", "app", "waiting_on_user"]
        .iter()
        .any(|key| old[key] != new[key])
        || (new["state"] != "working" && old["message"] != new["message"])
}

impl Hub {
    fn lock(&self) -> MutexGuard<'_, State> {
        lock_or_recover(&self.state)
    }

    pub fn boot(&self) -> SessionId {
        self.lock().boot
    }

    /// Takes the next revision for `json`, an event about `id` that `apply` makes true of what the
    /// events add up to, and keeps it in the ring.
    fn publish(&self, state: &mut State, json: Value) {
        state.revision += 1;
        let event = Arc::new(Event {
            revision: state.revision,
            json: stamped(state.boot, state.revision, json),
        });
        state.ring.push_back(event);
        while state.ring.len() > RING {
            state.ring.pop_front();
        }
        self.wake.notify_all();
    }

    /// A session was created: `listing` is it as `session.list` lists it.
    pub fn created(&self, id: SessionId, listing: Value) {
        let mut state = self.lock();
        let known = Known {
            coding_agent: listing["coding_agent"].clone(),
            listing,
            run_state: None,
            exit_code: None,
            run_seq: None,
        };
        let json = session_event(name::CREATED, id, &known);
        state.sessions.insert(id, known);
        self.publish(&mut state, json);
    }

    /// A session ended, with its shell's exit code when the daemon saw it.
    pub fn ended(&self, id: SessionId, exit_code: Option<i32>) {
        let mut state = self.lock();
        let Some(known) = state.sessions.remove(&id) else {
            return;
        };
        let json = json!({
            "event": name::ENDED,
            "session": id.to_hyphenated(),
            "scope": known.listing["scope"],
            "exit_code": exit_code,
        });
        self.publish(&mut state, json);
    }

    /// A session's program status changed: `agent` is its coding agent now (the listing's
    /// shape, null for none). An event only when it is news (`agent_changed`).
    pub fn program_status(&self, id: SessionId, agent: Value) {
        let mut state = self.lock();
        let Some(known) = state.sessions.get_mut(&id) else {
            return;
        };
        if !agent_changed(&known.coding_agent, &agent) {
            known.coding_agent = agent;
            return;
        }
        known.coding_agent = agent;
        let json = json!({
            "event": name::PROGRAM_STATUS,
            "session": id.to_hyphenated(),
            "scope": known.listing["scope"],
            "coding_agent": known.coding_agent,
        });
        self.publish(&mut state, json);
    }

    /// A run session's supervisor wrote `line`: its `seq`th transition, from its log, or with
    /// none, its status file's latest. A run whose transitions are logged is told from the log
    /// alone, each once, by number; one with no log, from its file's changes.
    pub fn run(&self, id: SessionId, line: &str, seq: Option<u64>) {
        let Some((run_state, exit_code)) = RunState::of_line(line) else {
            return;
        };
        let mut state = self.lock();
        let Some(known) = state.sessions.get_mut(&id) else {
            return;
        };
        match (seq, known.run_seq) {
            (Some(seq), Some(heard)) if seq <= heard => return,
            (Some(seq), _) => known.run_seq = Some(seq),
            // Its log tells it, and already has.
            (None, Some(_)) => return,
            (None, None)
                if known.run_state.as_deref() == Some(run_state.name())
                    && known.exit_code == exit_code =>
            {
                return;
            }
            (None, None) => {}
        }
        known.run_state = Some(run_state.name().to_string());
        known.exit_code = exit_code;
        let json = json!({
            "event": name::RUN_STATE,
            "session": id.to_hyphenated(),
            "scope": known.listing["scope"],
            "run_state": run_state.name(),
            "exit_code": exit_code,
        });
        self.publish(&mut state, json);
    }

    /// A run a hand-off adopted, and `log`, its transitions as its log holds them now. With the
    /// events carried, those the old program never told (logged while the hand-off was under way,
    /// after the old watcher's last look) are told now, by number. Without (the boot is new, so no
    /// client is owed any), the run takes the log's last as it stands, untold. Called once, before
    /// the runs watcher looks, which goes on from the log's end.
    pub fn adopted_run(&self, id: SessionId, log: &[(u64, String)]) {
        if self.lock().carried {
            for (seq, line) in log {
                self.run(id, line, Some(*seq));
            }
            return;
        }
        let Some((seq, line)) = log.last() else {
            return;
        };
        let mut state = self.lock();
        if let (Some(known), Some((run_state, exit_code))) =
            (state.sessions.get_mut(&id), RunState::of_line(line))
        {
            known.run_seq = Some(*seq);
            known.run_state = Some(run_state.name().to_string());
            known.exit_code = exit_code;
        }
    }

    /// Where a new subscriber starts, and what it is sent first; then its events, as they come.
    /// Blocks until there is something to send, or `closed` says the subscription has ended
    /// (checked whenever the hub wakes). Nothing is sent while a hand-off has the ring sealed.
    pub fn next(&self, cursor: &mut Cursor, closed: &dyn Fn() -> bool) -> Next {
        let mut state = self.lock();
        loop {
            if closed() {
                return Next::Closed;
            }
            if state.sealed.is_some() && cursor.start.is_some() {
                state = recover(self.wake.wait(state));
                continue;
            }
            if let Some(start) = cursor.start.take() {
                let boot = state.boot.to_hyphenated();
                let revision = state.deliverable();
                let reason = match start {
                    Start::Fresh => Reason::Subscribed,
                    Start::Since {
                        boot: theirs,
                        revision: since,
                    } if theirs == boot
                        && state.first() <= since.saturating_add(1)
                        && since <= revision =>
                    {
                        cursor.sent = since;
                        return Next::Resumed {
                            boot,
                            revision: since,
                        };
                    }
                    Start::Since { .. } => Reason::Gap,
                };
                cursor.sent = revision;
                return Next::Snapshot {
                    boot,
                    revision,
                    sessions: state.sessions.clone(),
                    reason,
                };
            }
            if cursor.sent + 1 < state.first() {
                // Its state afresh only once the ring is unsealed: one taken now would be past
                // what a hand-off carries.
                if state.sealed.is_some() {
                    state = recover(self.wake.wait(state));
                    continue;
                }
                cursor.sent = state.revision;
                return Next::Snapshot {
                    boot: state.boot.to_hyphenated(),
                    revision: state.revision,
                    sessions: state.sessions.clone(),
                    reason: Reason::Lagged,
                };
            }
            let upto = state.deliverable();
            if upto > cursor.sent {
                let first = state.first();
                let from = usize::try_from(cursor.sent + 1 - first).unwrap_or(usize::MAX);
                let events: Vec<Arc<Event>> = state
                    .ring
                    .iter()
                    .skip(from)
                    .take_while(|event| event.revision <= upto)
                    .cloned()
                    .collect();
                if let Some(last) = events.last() {
                    cursor.sent = last.revision;
                    return Next::Events(events);
                }
            }
            state = recover(self.wake.wait(state));
        }
    }

    /// Wakes every subscriber, for one whose subscription has just closed to see it.
    pub fn wake(&self) {
        self.wake.notify_all();
    }

    /// What a hand-off carries to the next program, as JSON: the boot, the revision, the ring and
    /// what the events add up to. Seals the ring, so nothing numbered after it is sent from this
    /// program: should the hand-off go ahead, the next program numbers on from here and tells
    /// what changed meanwhile again ([`Hub::reconcile`], and the runs watcher from its logs);
    /// should it not, [`Hub::unseal`] sends it.
    pub fn carry(&self) -> Vec<u8> {
        let mut state = self.lock();
        state.sealed = Some(state.revision);
        serde_json::to_vec(&Carried::of(&state)).expect("the events serialize")
    }

    /// The hand-off did not happen: what was held back is sent.
    pub fn unseal(&self) {
        self.lock().sealed = None;
        self.wake.notify_all();
    }

    /// Takes on what the program a hand-off replaced carried (`carry`), before anything is served.
    /// False when it can't be read, which leaves this hub's own boot: a client resuming from the
    /// old one is then sent the state afresh.
    pub fn adopt(&self, carried: &[u8]) -> bool {
        match serde_json::from_slice::<Carried>(carried)
            .ok()
            .and_then(Carried::state)
        {
            Some(adopted) => {
                *self.lock() = adopted;
                true
            }
            None => false,
        }
    }

    /// After a hand-off, with every session adopted: what the events must say about `live` (each
    /// session as `session.list` lists it now) that the old program's didn't. A session that
    /// ended while the hand-off was under way ended (its exit code unknown), one created then was
    /// created, and a coding agent that changed then changed. With nothing carried (a table from
    /// before the events, or one that couldn't be read), the live sessions are taken as they are,
    /// with no event: the boot is new, so no client resumes into them.
    pub fn reconcile(&self, live: Vec<(SessionId, Value)>, carried: bool) {
        if !carried {
            let mut state = self.lock();
            for (id, listing) in live {
                state.sessions.insert(
                    id,
                    Known {
                        coding_agent: listing["coding_agent"].clone(),
                        listing,
                        run_state: None,
                        exit_code: None,
                        run_seq: None,
                    },
                );
            }
            return;
        }
        let gone: Vec<SessionId> = {
            let state = self.lock();
            state
                .sessions
                .keys()
                .filter(|id| !live.iter().any(|(live, _)| live == *id))
                .copied()
                .collect()
        };
        for id in gone {
            self.ended(id, None);
        }
        for (id, listing) in live {
            let known = self.lock().sessions.contains_key(&id);
            if known {
                self.program_status(id, listing["coding_agent"].clone());
            } else {
                self.created(id, listing);
            }
        }
    }
}

/// A session event that carries the whole session: `session.created`, and each of a snapshot's
/// `session`s. The listing's fields, its id as `session`, and its run's state.
pub fn session_event(name: &str, id: SessionId, known: &Known) -> Value {
    let listing = &known.listing;
    json!({
        "event": name,
        "session": id.to_hyphenated(),
        "scope": listing["scope"],
        "label": listing["label"],
        "title": listing["title"],
        "run": listing["run"],
        "cwd": listing["cwd"],
        "coding_agent": known.coding_agent,
        "run_state": known.run_state,
        "exit_code": known.exit_code,
    })
}

#[cfg(test)]
mod tests;
