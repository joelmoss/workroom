//! Filesystem change notification for `Service::File`: agent → client events, unsolicited.
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
//! under an `npm install`-shaped burst, and a consumer that re-probes per callback forks git/jj at
//! that rate. The [`Coalescer`] is leading + trailing: the first change after a quiet period is
//! delivered after a 50ms settle (the panel reacts promptly, and one save's several raw events are
//! one delivery), everything after is folded into one set, and that set is delivered once after a
//! quiet window (the panel reflects the final on-disk state). A sustained burst therefore costs about
//! two deliveries.
//!
//! **Subscriptions belong to the connection.** [`Subscriptions`] is created by `handle_connection`
//! and dropped with it, and dropping stops every watcher: an OS watcher must never outlive the peer
//! it reports to. A subscription takes no `ACTIVE` permit — it is not a request in flight, it is a
//! resource, so it has its own cap — and needs none to keep the agent alive, because a live
//! connection already counts as busy in `serve`'s idle check.
//!
//! **A client that stops reading is evicted by closing its connection**, not just its subscription.
//! Silently dropping the subscription would leave the client showing a panel that never updates
//! again with nothing to tell it so; closing the connection makes the client see a lost transport,
//! reconnect into a new generation, and recreate every subscription against fresh state. Slow-client
//! detection is the transport's write timeout: a write that makes no progress fails, and that failure
//! is what triggers the close.

use crate::file::FileError;
use crate::protocol::envelope::{Envelope, Service, MAX_ENVELOPE_PAYLOAD};
use crate::session::SharedWriter;
use crate::transport::Closer;
use notify::{EventKind, RecursiveMode, Watcher};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
/// when the cap forces a choice, because an internal change is usually the tool's own churn (a jj
/// snapshot writing under `.jj/`) and the consumer filters it out anyway.
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
        let written = match self.writer.lock() {
            Ok(mut writer) => writer
                .write_all(&Envelope::new(Service::File, 0, payload).encode())
                .and_then(|()| writer.flush())
                .is_ok(),
            Err(_) => false,
        };
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
    _watcher: notify::RecommendedWatcher,
}

/// Every watch one connection holds, torn down with it.
pub struct Subscriptions {
    sink: Sink,
    active: Mutex<HashMap<u64, Subscription>>,
}

impl Subscriptions {
    pub fn new(writer: SharedWriter, closer: Closer) -> Self {
        Self {
            sink: Sink { writer, closer },
            active: Mutex::new(HashMap::new()),
        }
    }

    pub fn subscribe(&self, id: u64, root: &Path) -> Result<(), FileError> {
        let mut active = self.active.lock().unwrap_or_else(|e| e.into_inner());
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
        active.insert(id, Subscription { _watcher: watcher });
        Ok(())
    }

    /// Stop one subscription. Idempotent: an id that is not (or no longer) watched is not an error,
    /// so an unwatch racing the end of a subscription cannot fail.
    pub fn unsubscribe(&self, id: u64) {
        self.active
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&id);
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
mod tests {
    use super::*;

    fn paths(names: &[&str]) -> Vec<PathBuf> {
        names.iter().map(PathBuf::from).collect()
    }

    fn names(batch: &Batch) -> Vec<&str> {
        batch.paths.iter().map(String::as_str).collect()
    }

    struct BrokenWriter;

    impl Write for BrokenWriter {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_failed_event_write_closes_the_connection_instead_of_dropping_silently() {
        let closed = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = std::sync::Arc::clone(&closed);
        let sink = Sink {
            writer: std::sync::Arc::new(Mutex::new(Box::new(BrokenWriter))),
            closer: std::sync::Arc::new(move || {
                counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }),
        };
        let batch = Batch {
            paths: vec!["/a".into()],
            overflow: false,
        };
        assert!(!sink.changed(1, &batch));
        assert_eq!(closed.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    fn coalescer() -> Coalescer {
        Coalescer::new(Duration::from_secs(1), LEADING_SETTLE)
    }

    /// Every delivery the burst makes when driven to completion: feed `events`, tick at each event's
    /// time and at each deadline, then run the clock out.
    fn deliveries(events: &[(Duration, &[&str])]) -> Vec<Batch> {
        let mut coalescer = coalescer();
        let t0 = Instant::now();
        let mut out = Vec::new();
        for (at, names) in events {
            let now = t0 + *at;
            while let Some(due) = coalescer.deadline().filter(|due| *due <= now) {
                out.extend(coalescer.tick(due));
            }
            coalescer.event(now, paths(names), false);
            out.extend(coalescer.tick(now));
        }
        while let Some(due) = coalescer.deadline() {
            out.extend(coalescer.tick(due));
        }
        out
    }

    #[test]
    fn the_leading_batch_waits_for_the_settle_and_carries_the_whole_burst_so_far() {
        let mut coalescer = coalescer();
        let t0 = Instant::now();
        coalescer.event(t0, paths(&["/r/a"]), false);
        assert!(coalescer.tick(t0).is_none(), "not before the settle");
        coalescer.event(t0 + Duration::from_millis(20), paths(&["/r/b"]), false);
        let leading = coalescer.tick(t0 + LEADING_SETTLE).unwrap();
        assert_eq!(names(&leading), ["/r/a", "/r/b"]);
        assert!(!leading.overflow);
    }

    /// The measured shape of one save (4 raw events in an in-place save, 6 in an atomic one, all for
    /// the same path within ~0.1ms) must reach the panel ONCE. Before the settle it reached it twice:
    /// the first event was the leading batch and its siblings became a trailing batch a second later.
    #[test]
    fn one_save_is_one_delivery() {
        let raw: Vec<(Duration, &[&str])> = (0..6)
            .map(|i| (Duration::from_micros(30 * i), &["/r/a.txt"][..]))
            .collect();
        let batches = deliveries(&raw);
        assert_eq!(batches.len(), 1, "{batches:?}");
        assert_eq!(names(&batches[0]), ["/r/a.txt"]);
    }

    #[test]
    fn a_second_write_after_the_settle_is_reported_by_the_trailing_edge() {
        let batches = deliveries(&[
            (Duration::ZERO, &["/r/a.txt"]),
            (Duration::from_millis(400), &["/r/a.txt"]),
        ]);
        assert_eq!(batches.len(), 2, "{batches:?}");
        assert_eq!(
            names(&batches[1]),
            ["/r/a.txt"],
            "the same path, genuinely written again"
        );
    }

    #[test]
    fn a_sustained_burst_is_a_leading_and_one_trailing_delivery() {
        // Seventy raw notifications a second for five seconds, the measured `npm install` rate.
        let names: Vec<String> = (0..350).map(|i| format!("/r/f{i}")).collect();
        let raw: Vec<(Duration, Vec<&str>)> = names
            .iter()
            .enumerate()
            .map(|(i, name)| (Duration::from_millis(14 * i as u64), vec![name.as_str()]))
            .collect();
        let events: Vec<(Duration, &[&str])> = raw
            .iter()
            .map(|(at, name)| (*at, name.as_slice()))
            .collect();
        let batches = deliveries(&events);
        assert_eq!(
            batches.len(),
            2,
            "a leading and a trailing delivery, not one per callback"
        );
        let reported: usize = batches.iter().map(|b| b.paths.len()).sum();
        assert_eq!(reported, 350, "and between them every path");
    }

    #[test]
    fn the_trailing_edge_waits_for_a_full_quiet_window() {
        let mut coalescer = coalescer();
        let t0 = Instant::now();
        coalescer.event(t0, paths(&["/r/a"]), false);
        assert!(coalescer.tick(t0 + LEADING_SETTLE).is_some());
        coalescer.event(t0 + Duration::from_millis(900), paths(&["/r/b"]), false);
        // A second after the first event, but only 100ms after the last: still active.
        assert!(coalescer.tick(t0 + Duration::from_secs(1)).is_none());
        assert_eq!(
            names(&coalescer.tick(t0 + Duration::from_millis(1900)).unwrap()),
            ["/r/b"]
        );
        assert!(coalescer.deadline().is_none(), "the burst is closed");
    }

    #[test]
    fn a_new_burst_after_quiet_gets_its_own_leading_edge() {
        let batches = deliveries(&[
            (Duration::ZERO, &["/r/a"]),
            (Duration::from_secs(3), &["/r/b"]),
        ]);
        assert_eq!(batches.len(), 2, "{batches:?}");
        assert_eq!(names(&batches[1]), ["/r/b"]);
    }

    #[test]
    fn a_rescan_request_is_an_overflow_even_with_no_paths() {
        let mut coalescer = coalescer();
        let t0 = Instant::now();
        coalescer.event(t0, vec![], true);
        let batch = coalescer.tick(t0 + LEADING_SETTLE).unwrap();
        assert!(batch.overflow && batch.paths.is_empty());
    }

    #[test]
    fn worktree_paths_come_before_vcs_internal_ones() {
        let mut pending = Pending::default();
        for path in ["/r/.git/index", "/r/a.txt", "/r/.jj/repo/op", "/r/b.txt"] {
            pending.add(PathBuf::from(path));
        }
        let batch = pending.take().unwrap();
        assert_eq!(
            names(&batch),
            ["/r/a.txt", "/r/b.txt", "/r/.git/index", "/r/.jj/repo/op"]
        );
    }

    #[test]
    fn a_batch_past_the_path_cap_keeps_worktree_paths_and_flags_overflow() {
        let mut pending = Pending::default();
        for index in 0..MAX_EVENT_PATHS {
            pending.add(PathBuf::from(format!("/r/.git/objects/{index:05}")));
        }
        pending.add(PathBuf::from("/r/src/important.rs"));
        let batch = pending.take().unwrap();
        assert_eq!(batch.paths.len(), MAX_EVENT_PATHS);
        assert_eq!(batch.paths[0], "/r/src/important.rs");
        assert!(batch.overflow, "an internal path was dropped");
    }

    #[test]
    fn a_batch_past_the_byte_cap_stops_and_flags_overflow() {
        let mut pending = Pending::default();
        let long = "x".repeat(4000);
        for index in 0..100 {
            pending.add(PathBuf::from(format!("/r/{index:03}{long}")));
        }
        let batch = pending.take().unwrap();
        let bytes: usize = batch.paths.iter().map(String::len).sum();
        assert!(bytes <= MAX_EVENT_PATH_BYTES);
        assert!(batch.overflow);
    }

    #[test]
    fn the_accumulator_stops_remembering_paths_past_its_cap() {
        let mut coalescer = coalescer();
        let t0 = Instant::now();
        coalescer.event(t0, paths(&["/r/lead"]), false);
        assert!(coalescer.tick(t0 + LEADING_SETTLE).is_some());
        // Two follow-up bursts whose UNION exceeds the per-class cap: each alone fits.
        for chunk in 0..2 {
            let many: Vec<PathBuf> = (0..3000)
                .map(|index| PathBuf::from(format!("/r/c{chunk}-f{index}")))
                .collect();
            coalescer.event(t0 + Duration::from_millis(100), many, false);
        }
        let trailing = coalescer.tick(t0 + Duration::from_secs(2)).unwrap();
        assert!(trailing.overflow);
        assert!(trailing.paths.len() <= MAX_EVENT_PATHS);
    }

    #[test]
    fn the_accumulator_is_bounded_in_bytes_as_well_as_paths() {
        let mut pending = Pending::default();
        let long = "y".repeat(3000);
        for index in 0..1000 {
            pending.add(PathBuf::from(format!("/r/{index:04}{long}")));
        }
        assert!(pending.bytes <= MAX_PENDING_BYTES);
        assert!(
            pending.overflow,
            "paths past the byte budget are reported as overflow"
        );
        let again = pending.worktree.len();
        pending.add(PathBuf::from(format!("/r/0000{long}")));
        assert_eq!(
            pending.worktree.len(),
            again,
            "a repeated path costs nothing"
        );
    }
}
