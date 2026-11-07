use super::*;
use std::io::Write;

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
    // `.jj/` too: a repo colocated with Jujutsu before #266 can still have `jj` run in it.
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

/// The bookkeeping alone, with no OS watcher per id (see `Subscriptions::stubbed`): the wire
/// test in `tests/file_service.rs` proves the same shapes over a real connection with a few
/// subscriptions, and this one reaches the cap.
#[test]
fn subscription_ids_are_unique_and_the_count_is_capped() {
    let root = std::env::temp_dir();
    let subscriptions = Subscriptions::stubbed();
    subscriptions.subscribe(1, &root).unwrap();
    assert!(matches!(
        subscriptions.subscribe(1, &root),
        Err(FileError::Unsupported(detail)) if detail.contains("already in use")
    ));
    for id in 2..=MAX_SUBSCRIPTIONS as u64 {
        subscriptions.subscribe(id, &root).unwrap();
    }
    let over = MAX_SUBSCRIPTIONS as u64 + 1;
    assert!(matches!(
        subscriptions.subscribe(over, &root),
        Err(FileError::Busy(_))
    ));
    // Freeing one makes room again.
    subscriptions.unsubscribe(2);
    subscriptions.subscribe(over, &root).unwrap();
    assert!(matches!(
        subscriptions.subscribe(over, &root),
        Err(FileError::Unsupported(_))
    ));
}
