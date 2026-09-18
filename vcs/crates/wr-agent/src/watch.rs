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
//! delivered at once (the panel reacts promptly), everything after is folded into one set, and that
//! set is delivered once after a quiet window (the panel reflects the final on-disk state). A
//! sustained burst therefore costs about two deliveries.
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
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Watches one connection may hold. Each is an OS watcher plus a thread, so this is what bounds
/// them, in place of the request permit a subscription deliberately does not take.
pub const MAX_SUBSCRIPTIONS: usize = 64;

/// Quiet time before a burst's trailing delivery, matching `WorkroomFileWatcher`'s 1s window.
const COALESCE_WINDOW: Duration = Duration::from_secs(1);

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
    overflow: bool,
}

impl Pending {
    fn add(&mut self, path: PathBuf) {
        let set = if is_internal(&path) {
            &mut self.internal
        } else {
            &mut self.worktree
        };
        if set.len() >= MAX_PENDING_PATHS && !set.contains(&path) {
            self.overflow = true;
        } else {
            set.insert(path);
        }
    }

    /// Empty the accumulator into a batch, or `None` when there is nothing to say.
    fn take(&mut self) -> Option<Batch> {
        let mut overflow = std::mem::take(&mut self.overflow);
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

/// Leading + trailing coalescing as a pure state machine over an explicit clock, so its timing is
/// tested without sleeping. `WorkroomFileWatcher.ingest`/`scheduleTrailing` is the behaviour it
/// mirrors: same leading edge, same union, same "quiet for the whole window" trailing edge.
struct Coalescer {
    window: Duration,
    /// `Some` while a burst is open: the last raw activity and what has accumulated since the
    /// leading delivery.
    open: Option<(Instant, Pending)>,
}

impl Coalescer {
    fn new(window: Duration) -> Self {
        Self { window, open: None }
    }

    /// Fold one raw notification in. Returns the LEADING batch when this opens a burst.
    fn event(&mut self, now: Instant, paths: Vec<PathBuf>, rescan: bool) -> Option<Batch> {
        let mut incoming = Pending::default();
        for path in paths {
            incoming.add(path);
        }
        incoming.overflow |= rescan;
        match &mut self.open {
            None => {
                self.open = Some((now, Pending::default()));
                incoming.take()
            }
            Some((last, pending)) => {
                *last = now;
                pending.worktree.append(&mut incoming.worktree);
                pending.internal.append(&mut incoming.internal);
                pending.overflow |= incoming.overflow;
                // The merge above can exceed the accumulator's cap; re-apply it.
                for set in [&mut pending.worktree, &mut pending.internal] {
                    while set.len() > MAX_PENDING_PATHS {
                        set.pop_last();
                        pending.overflow = true;
                    }
                }
                None
            }
        }
    }

    /// When the trailing delivery is due, if a burst is open.
    fn deadline(&self) -> Option<Instant> {
        self.open.as_ref().map(|(last, _)| *last + self.window)
    }

    /// Close the burst if it has been quiet for the whole window, returning the TRAILING batch.
    fn tick(&mut self, now: Instant) -> Option<Batch> {
        let (last, _) = self.open.as_ref()?;
        if now < *last + self.window {
            return None;
        }
        let (_, mut pending) = self.open.take()?;
        pending.take()
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
        let (sender, receiver) = mpsc::channel();
        // gstack-shortcut(dec-8742d8a5-42ac-4348-827b-9c15d9330f5a): one OS watcher per
        // subscription, upgrade when two windows watching one workroom show up as duplicated
        // watches in a profile, or when inotify's per-user watch limit is reachable (Phase 3, Linux).
        // Sharing one watcher per root across subscriptions is the fix, recorded in TODOS.md.
        let mut watcher = notify::recommended_watcher(sender)
            .map_err(|error| FileError::Io(format!("cannot create a watcher: {error}")))?;
        watcher
            .watch(root, RecursiveMode::Recursive)
            .map_err(|error| FileError::Io(format!("cannot watch {}: {error}", root.display())))?;
        let sink = self.sink.clone();
        let root = root.to_owned();
        std::thread::spawn(move || run(id, &root, &receiver, &sink));
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
    sink: &Sink,
) {
    let mut coalescer = Coalescer::new(COALESCE_WINDOW);
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
        let batch = match received {
            Some(Ok(event)) => {
                // Reads are not changes. Reporting them would make every `git status` in a
                // watched tree wake its own consumer.
                if matches!(event.kind, EventKind::Access(_)) {
                    continue;
                }
                let rescan = event.need_rescan();
                coalescer.event(now, event.paths, rescan)
            }
            Some(Err(error)) => {
                sink.ended(id, &format!("watcher error: {error}"));
                return;
            }
            None => coalescer.tick(now),
        };
        if let Some(batch) = batch {
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

    #[test]
    fn the_first_change_after_quiet_is_delivered_at_once() {
        let mut coalescer = Coalescer::new(Duration::from_secs(1));
        let now = Instant::now();
        let batch = coalescer.event(now, paths(&["/r/a"]), false).unwrap();
        assert_eq!(names(&batch), ["/r/a"]);
        assert!(!batch.overflow);
    }

    #[test]
    fn a_sustained_burst_yields_a_leading_and_one_trailing_delivery() {
        let mut coalescer = Coalescer::new(Duration::from_secs(1));
        let start = Instant::now();
        let mut deliveries = 0;
        // Seventy raw callbacks a second for five seconds, the measured `npm install` rate.
        for tick in 0..350u64 {
            let now = start + Duration::from_millis(tick * 14);
            if coalescer
                .event(now, paths(&[&format!("/r/f{tick}")]), false)
                .is_some()
            {
                deliveries += 1;
            }
            if coalescer.tick(now).is_some() {
                deliveries += 1;
            }
        }
        assert_eq!(deliveries, 1, "only the leading edge while the burst lasts");
        let end = start + Duration::from_millis(349 * 14);
        assert!(coalescer.tick(end + Duration::from_millis(999)).is_none());
        let trailing = coalescer.tick(end + Duration::from_secs(1)).unwrap();
        assert_eq!(
            trailing.paths.len(),
            349,
            "everything after the leading edge"
        );
        assert!(coalescer.deadline().is_none(), "the burst is closed");
    }

    #[test]
    fn the_trailing_edge_waits_for_a_full_quiet_window() {
        let mut coalescer = Coalescer::new(Duration::from_secs(1));
        let t0 = Instant::now();
        coalescer.event(t0, paths(&["/r/a"]), false);
        coalescer.event(t0 + Duration::from_millis(900), paths(&["/r/b"]), false);
        // 1s after the FIRST event, but only 100ms after the last: still active.
        assert!(coalescer.tick(t0 + Duration::from_secs(1)).is_none());
        assert_eq!(
            names(&coalescer.tick(t0 + Duration::from_millis(1900)).unwrap()),
            ["/r/b"]
        );
    }

    #[test]
    fn a_new_burst_after_quiet_gets_its_own_leading_edge() {
        let mut coalescer = Coalescer::new(Duration::from_secs(1));
        let t0 = Instant::now();
        coalescer.event(t0, paths(&["/r/a"]), false);
        assert!(
            coalescer.tick(t0 + Duration::from_secs(2)).is_none(),
            "nothing pending"
        );
        assert!(coalescer
            .event(t0 + Duration::from_secs(3), paths(&["/r/b"]), false)
            .is_some());
    }

    #[test]
    fn a_rescan_request_is_an_overflow_even_with_no_paths() {
        let mut coalescer = Coalescer::new(Duration::from_secs(1));
        let batch = coalescer.event(Instant::now(), vec![], true).unwrap();
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
        let mut coalescer = Coalescer::new(Duration::from_secs(1));
        let t0 = Instant::now();
        coalescer.event(t0, paths(&["/r/lead"]), false);
        let many: Vec<PathBuf> = (0..MAX_PENDING_PATHS + 500)
            .map(|index| PathBuf::from(format!("/r/f{index}")))
            .collect();
        coalescer.event(t0, many, false);
        let trailing = coalescer.tick(t0 + Duration::from_secs(2)).unwrap();
        assert!(trailing.overflow);
        assert!(trailing.paths.len() <= MAX_EVENT_PATHS);
    }
}
