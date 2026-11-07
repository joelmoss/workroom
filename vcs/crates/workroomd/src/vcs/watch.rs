//! Filesystem change notification for `Service::File`: daemon → client events, unsolicited.
//!
//! A client subscribes to a directory with `watch` (a client-chosen `subscription` id, replied to
//! like any request) and from then on receives events on **stream 0 of the File service** — the
//! stream the envelope reserves for messages that belong to no request. ONE events stream serves
//! every subscription on the connection, discriminated by the id in the payload. A stream per
//! subscription would let an `unwatch` race an event already in flight: the event would land on a
//! stream the client had just forgotten, which its `receive()` treats as a protocol violation and
//! answers by failing the whole connection.
//!
//! ```text
//! {"event":"changed","subscription":7,"paths":["/abs/a","/abs/b"],"overflow":false}
//! {"event":"ended","subscription":7,"reason":"root_removed"}
//! ```
//!
//! Paths are ABSOLUTE host paths. `overflow` means "some changes are not listed" — the batch hit a
//! cap, or the OS said it lost track and the tree must be rescanned — and a consumer must treat it
//! as relevant to every filter it has.
//!
//! **Coalescing lives here, not in the client.** An uncoalesced watch flushes ~70 callbacks/sec
//! under an `npm install`-shaped burst, and a consumer that re-probes per callback forks git at
//! that rate. The [`Coalescer`] is leading + trailing: the first change after a quiet period is
//! delivered after a 50ms settle (the panel reacts promptly, and one save's several raw events are
//! one delivery), everything after is folded into one set, and that set is delivered once after a
//! quiet window (the panel reflects the final on-disk state). A sustained burst therefore costs about
//! two deliveries.
//!
//! **Subscriptions belong to the connection.** [`Subscriptions`] is created by `handle_connection`
//! and dropped with it, and dropping stops every watcher: an OS watcher must never outlive the peer
//! it reports to. A subscription takes no `ACTIVE` permit — it is not a request in flight, it is a
//! resource, so it has its own cap — and needs none to keep the daemon alive, because a live
//! connection already counts as busy in `serve`'s idle check.
//!
//! **A client that stops reading is evicted by closing its connection**, not just its subscription.
//! Silently dropping the subscription would leave the client showing a panel that never updates
//! again with nothing to tell it so; closing the connection makes the client see a lost transport,
//! reconnect into a new generation, and recreate every subscription against fresh state. Slow-client
//! detection is the transport's write timeout: a write that makes no progress fails, and that failure
//! is what triggers the close.

use crate::daemon::rpc::{self, SharedWriter};
use crate::daemon::transport::Closer;
use crate::util::lock_or_recover;
use crate::vcs::file::FileError;
use notify::{EventKind, RecursiveMode, Watcher};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use wr_protocol::envelope::{Envelope, MAX_ENVELOPE_PAYLOAD, Service};

/// Watches one connection may hold. Each is an OS watcher plus a thread, so this is what bounds
/// them, in place of the request permit a subscription deliberately does not take.
pub const MAX_SUBSCRIPTIONS: usize = 64;

/// Quiet time before a burst's trailing delivery, matching `WorkroomFileWatcher`'s 1s window.
const COALESCE_WINDOW: Duration = Duration::from_secs(1);

/// How long the first raw event of a burst waits for its siblings before the LEADING delivery.
///
/// One save is several raw events, not one: `notify`'s macOS backend runs FSEvents at latency 0 with
/// per-file events, so an in-place save measured 4 events within ~0.1ms and an atomic save (write a
/// temp file, rename) 6. Delivering the first immediately and folding the rest into the trailing edge
/// made every ordinary save two panel refreshes (a `git ls-files` and a status probe each) where the
/// old directory-granularity watcher made one. Settling briefly first puts the whole save in the
/// leading batch, so the trailing edge is non-empty only when something changed AFTER it. 50ms is
/// imperceptible and comfortably longer than the measured spread.
const LEADING_SETTLE: Duration = Duration::from_millis(50);

/// Raw notifications buffered between the OS watcher and the coalescer thread. Bounded, because that
/// thread can block on a slow client's socket for a long time; a full buffer drops events and sets an
/// overflow flag instead of growing without limit in a daemon every window shares.
const INGRESS_CAPACITY: usize = 1024;

/// The most paths one event carries. A burst that touches more is delivered as the first
/// `MAX_EVENT_PATHS` plus `overflow`, which the consumer answers with a full rescan anyway.
const MAX_EVENT_PATHS: usize = 2048;

/// The most path BYTES one event carries. Independent of the count because a path can be 4096 bytes
/// and JSON can escape a byte into six: 128 KiB raw stays under the 1 MiB envelope even then, which
/// is what lets an event always travel as one envelope and never interleave with another's chunks.
const MAX_EVENT_PATH_BYTES: usize = 128 * 1024;

/// How many distinct paths a burst accumulates before it stops remembering more (per class). The
/// accumulator is bounded regardless of how many files an `npm install` touches.
const MAX_PENDING_PATHS: usize = 4096;

/// The same bound in BYTES across both classes. The count alone would let near-`PATH_MAX` names pin
/// tens of MiB per subscription during a sustained burst.
const MAX_PENDING_BYTES: usize = 512 * 1024;

/// A path is VCS-internal when any component is `.git` or `.jj`. Delivered after everything else
/// when the cap forces a choice, because an internal change is usually the tool's own churn (git
/// writing under `.git/`) and the consumer filters it out anyway. `.jj` stays because a repo
/// colocated with Jujutsu before #266 can still have `jj` run in it; Workroom never writes there.
fn is_internal(path: &Path) -> bool {
    path.components()
        .any(|c| c.as_os_str() == ".git" || c.as_os_str() == ".jj")
}

/// One delivery: paths in priority order (working-tree paths before VCS-internal ones), capped.
#[derive(Debug, PartialEq)]
pub struct Batch {
    pub paths: Vec<String>,
    pub overflow: bool,
}

/// The accumulator behind a burst: a bounded union of paths, kept in two classes so the internal
/// class can be sacrificed first.
#[derive(Default)]
struct Pending {
    worktree: BTreeSet<PathBuf>,
    internal: BTreeSet<PathBuf>,
    /// Bytes across both sets, against `MAX_PENDING_BYTES`.
    bytes: usize,
    overflow: bool,
}

impl Pending {
    fn add(&mut self, path: PathBuf) {
        let set = if is_internal(&path) {
            &mut self.internal
        } else {
            &mut self.worktree
        };
        if set.contains(&path) {
            return;
        }
        let cost = path.as_os_str().len();
        if set.len() >= MAX_PENDING_PATHS || self.bytes + cost > MAX_PENDING_BYTES {
            self.overflow = true;
        } else {
            self.bytes += cost;
            set.insert(path);
        }
    }

    /// Empty the accumulator into a batch, or `None` when there is nothing to say.
    fn take(&mut self) -> Option<Batch> {
        let mut overflow = std::mem::take(&mut self.overflow);
        self.bytes = 0;
        let mut paths = Vec::new();
        let mut bytes = 0;
        for path in std::mem::take(&mut self.worktree)
            .into_iter()
            .chain(std::mem::take(&mut self.internal))
        {
            let text = path.to_string_lossy().into_owned();
            if paths.len() >= MAX_EVENT_PATHS || bytes + text.len() > MAX_EVENT_PATH_BYTES {
                overflow = true;
                break;
            }
            bytes += text.len();
            paths.push(text);
        }
        (!paths.is_empty() || overflow).then_some(Batch { paths, overflow })
    }
}

/// Where a burst is in its life.
#[derive(Clone, Copy)]
enum Phase {
    Idle,
    /// The first raw event arrived; siblings within the settle window join the leading batch.
    Settling {
        due: Instant,
    },
    /// The leading batch went out. `last` is the most recent raw activity; the trailing batch goes
    /// out once nothing has happened for a whole window.
    Open {
        last: Instant,
    },
}

/// Leading + trailing coalescing as a pure state machine over an explicit clock, so its timing is
/// tested without sleeping. Same shape as `WorkroomFileWatcher.ingest`/`scheduleTrailing` — a leading
/// edge, a union, a "quiet for the whole window" trailing edge — plus the settle that `notify`'s
/// per-file events need (see `LEADING_SETTLE`).
struct Coalescer {
    window: Duration,
    settle: Duration,
    phase: Phase,
    pending: Pending,
}

impl Coalescer {
    fn new(window: Duration, settle: Duration) -> Self {
        Self {
            window,
            settle,
            phase: Phase::Idle,
            pending: Pending::default(),
        }
    }

    /// Fold one raw notification in. Nothing is delivered from here: the caller asks `tick`.
    fn event(&mut self, now: Instant, paths: Vec<PathBuf>, rescan: bool) {
        for path in paths {
            self.pending.add(path);
        }
        self.pending.overflow |= rescan;
        match &mut self.phase {
            Phase::Idle => {
                self.phase = Phase::Settling {
                    due: now + self.settle,
                }
            }
            Phase::Settling { .. } => {}
            Phase::Open { last } => *last = now,
        }
    }

    /// When `tick` next has something to decide, if a burst is in progress.
    fn deadline(&self) -> Option<Instant> {
        match self.phase {
            Phase::Idle => None,
            Phase::Settling { due } => Some(due),
            Phase::Open { last } => Some(last + self.window),
        }
    }

    /// The LEADING batch once the settle has passed, or the TRAILING batch once the burst has been
    /// quiet for the whole window (which also ends it).
    fn tick(&mut self, now: Instant) -> Option<Batch> {
        match self.phase {
            Phase::Settling { due } if now >= due => {
                self.phase = Phase::Open { last: due };
                self.pending.take()
            }
            Phase::Open { last } if now >= last + self.window => {
                self.phase = Phase::Idle;
                self.pending.take()
            }
            _ => None,
        }
    }
}

/// Where events go: the connection's shared writer, plus the means to end the connection when a
/// write fails.
#[derive(Clone)]
struct Sink {
    writer: SharedWriter,
    closer: Closer,
}

impl Sink {
    /// One event, one envelope, `[1] + json`: the same final-chunk framing every File reply uses, so
    /// the client has a single decoder. Returns whether it was written; a failure closes the
    /// connection (see the module doc).
    fn send(&self, value: Value) -> bool {
        let mut payload = vec![1u8];
        payload.extend(serde_json::to_vec(&value).expect("JSON value serializes"));
        debug_assert!(payload.len() < MAX_ENVELOPE_PAYLOAD);
        let written = rpc::write(
            &self.writer,
            &Envelope::new(Service::File, 0, payload).encode(),
        );
        if !written {
            (self.closer)();
        }
        written
    }

    fn changed(&self, id: u64, batch: &Batch) -> bool {
        self.send(json!({
            "event": "changed", "subscription": id,
            "paths": batch.paths, "overflow": batch.overflow,
        }))
    }

    fn ended(&self, id: u64, reason: &str) {
        self.send(json!({"event": "ended", "subscription": id, "reason": reason}));
    }
}

/// One live watch. Dropping it stops the OS watcher, which drops the channel sender the watcher's
/// handler owns, which ends the coalescer thread — no explicit stop flag to race.
struct Subscription {
    /// `None` only under `stubbed()`: a bookkeeping-only subscription with no OS watcher behind it.
    _watcher: Option<notify::RecommendedWatcher>,
}

/// Every watch one connection holds, torn down with it.
pub struct Subscriptions {
    sink: Sink,
    active: Mutex<HashMap<u64, Subscription>>,
    /// Unit tests of the bookkeeping (ids, the cap) with no OS watcher per subscription: on this
    /// Mac one FSEvents watch costs 0.7-2.4s to create (measured, notify 8.2), so a test reaching
    /// `MAX_SUBSCRIPTIONS` over real watchers took 48s.
    #[cfg(test)]
    stubbed: bool,
}

impl Subscriptions {
    pub fn new(writer: SharedWriter, closer: Closer) -> Self {
        Self {
            sink: Sink { writer, closer },
            active: Mutex::new(HashMap::new()),
            #[cfg(test)]
            stubbed: false,
        }
    }

    #[cfg(test)]
    fn stubbed() -> Self {
        Self {
            sink: Sink {
                writer: Arc::new(Mutex::new(Box::new(std::io::sink()))),
                closer: Arc::new(|| {}),
            },
            active: Mutex::new(HashMap::new()),
            stubbed: true,
        }
    }

    pub fn subscribe(&self, id: u64, root: &Path) -> Result<(), FileError> {
        let mut active = lock_or_recover(&self.active);
        if active.contains_key(&id) {
            return Err(FileError::Unsupported(
                "subscription id already in use".into(),
            ));
        }
        if active.len() >= MAX_SUBSCRIPTIONS {
            return Err(FileError::Busy(format!(
                "subscription limit of {MAX_SUBSCRIPTIONS} reached"
            )));
        }
        if !root.is_dir() {
            return Err(FileError::NotFound(format!(
                "{} is not a directory",
                root.display()
            )));
        }
        #[cfg(test)]
        if self.stubbed {
            active.insert(id, Subscription { _watcher: None });
            return Ok(());
        }
        let (sender, receiver) = mpsc::sync_channel(INGRESS_CAPACITY);
        let dropped = Arc::new(AtomicBool::new(false));
        let handler_dropped = Arc::clone(&dropped);
        // gstack-shortcut(dec-8742d8a5-42ac-4348-827b-9c15d9330f5a): one OS watcher per
        // subscription, upgrade when two windows watching one workroom show up as duplicated
        // watches in a profile, or when inotify's per-user watch limit is reachable (Phase 3, Linux).
        // Sharing one watcher per root across subscriptions is the fix, recorded in TODOS.md.
        //
        // Symlinks are NOT followed: a committed link to `$HOME` (or `/`) would otherwise make a
        // recursive inotify watch walk the whole target and report paths outside the repository root.
        // A no-op for FSEvents today, and load-bearing the day this runs on Linux.
        let handler = move |result: notify::Result<notify::Event>| {
            if sender.try_send(result).is_err() {
                handler_dropped.store(true, Ordering::Release);
            }
        };
        let mut watcher = notify::RecommendedWatcher::new(
            handler,
            notify::Config::default().with_follow_symlinks(false),
        )
        .map_err(|error| FileError::Io(format!("cannot create a watcher: {error}")))?;
        watcher
            .watch(root, RecursiveMode::Recursive)
            .map_err(|error| FileError::Io(format!("cannot watch {}: {error}", root.display())))?;
        let sink = self.sink.clone();
        let root = root.to_owned();
        std::thread::spawn(move || run(id, &root, &receiver, &dropped, &sink));
        active.insert(
            id,
            Subscription {
                _watcher: Some(watcher),
            },
        );
        Ok(())
    }

    /// Stop one subscription. Idempotent: an id that is not (or no longer) watched is not an error,
    /// so an unwatch racing the end of a subscription cannot fail.
    pub fn unsubscribe(&self, id: u64) {
        lock_or_recover(&self.active).remove(&id);
    }
}

/// The coalescer thread for one subscription. Ends when the watcher is dropped (the channel
/// disconnects), on a watcher error, when the watched root disappears, or when a write fails.
fn run(
    id: u64,
    root: &Path,
    receiver: &mpsc::Receiver<notify::Result<notify::Event>>,
    dropped: &AtomicBool,
    sink: &Sink,
) {
    let mut coalescer = Coalescer::new(COALESCE_WINDOW, LEADING_SETTLE);
    loop {
        let received = match coalescer.deadline() {
            Some(deadline) => {
                match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                    Ok(event) => Some(event),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            None => match receiver.recv() {
                Ok(event) => Some(event),
                Err(_) => return,
            },
        };
        let now = Instant::now();
        match received {
            // Reads are not changes. Reporting them would make every `git status` in a watched tree
            // wake its own consumer. Falls through to `tick` rather than `continue`, so a flood of
            // them cannot starve a batch that is already due.
            Some(Ok(event)) if matches!(event.kind, EventKind::Access(_)) => {}
            Some(Ok(event)) => {
                let rescan = event.need_rescan();
                coalescer.event(now, event.paths, rescan);
            }
            Some(Err(error)) => {
                sink.ended(id, &format!("watcher error: {error}"));
                return;
            }
            None => {}
        }
        // The ingress buffer was full and events were dropped, so anything may have changed.
        if dropped.swap(false, Ordering::AcqRel) {
            coalescer.event(now, Vec::new(), true);
        }
        if let Some(batch) = coalescer.tick(now) {
            if !sink.changed(id, &batch) {
                return;
            }
            // Cheap, and the only signal for a deleted root that does not depend on which event
            // kind the OS chose to report it with.
            if !root.exists() {
                sink.ended(id, "root_removed");
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests;
